// Press DeviceHub's device controls (fold poses, rotate, Home) for one simulator.
//
// Xcode 27's DeviceHub replaced Simulator.app. simctl has no rotate or fold
// command, DeviceHub has no AppleScript dictionary, and System Events sees no
// UI in it. The accessibility API called directly does see the window,
// including the action bar under the device. This finds the window showing a
// given UDID (opening a new one rather than taking over a window another
// session is looking at) and presses a button there by its label.
//
// Long presses, drags and Split View use real touches instead, sent to the
// simulator's digitizer service (see Touches below).
//
// https://github.com/ChrisThoma/devicehubctl

import ApplicationServices
import Foundation
import ImageIO
import XPC

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
  var v: CFTypeRef?
  AXUIElementCopyAttributeValue(e, name as CFString, &v)
  return v
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func element(_ v: CFTypeRef?) -> AXUIElement? {
  guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
  return (v as! AXUIElement)
}
func elements(_ v: CFTypeRef?) -> [AXUIElement] { ((v as? [AnyObject]) ?? []).compactMap { element($0) } }
func children(_ e: AXUIElement) -> [AXUIElement] { elements(attr(e, "AXChildren")) }

func find(_ e: AXUIElement, depth: Int = 0, maxDepth: Int = 40, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
  if match(e) { return e }
  guard depth < maxDepth else { return nil }
  for k in children(e) { if let r = find(k, depth: depth + 1, maxDepth: maxDepth, match) { return r } }
  return nil
}

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
  exit(1)
}

func waitFor<T>(_ seconds: Double, _ probe: () -> T?) -> T? {
  let end = Date().addingTimeInterval(seconds)
  repeat {
    if let v = probe() { return v }
    usleep(250_000)
  } while Date() < end
  return nil
}

func simctlDevices() -> [[String: Any]] {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  p.arguments = ["simctl", "list", "devices", "-j"]
  let out = Pipe()
  p.standardOutput = out
  try! p.run()
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  return Array((json["devices"] as! [String: Any]).values.compactMap { $0 as? [[String: Any]] }.joined())
}

// Simulator UDID, name and state from simctl, so the window can be matched by
// title. "booted" is accepted when exactly one simulator is booted; with more,
// guessing could drive a device someone else is using.
func simDevice(_ udid: String) -> (udid: String, name: String, state: String, nameIsShared: Bool) {
  let all = simctlDevices()
  let device = { (d: [String: Any]) -> (String, String, String, Bool) in
    let name = d["name"] as! String
    return (d["udid"] as! String, name, d["state"] as! String, all.filter { ($0["name"] as? String) == name }.count > 1)
  }
  if udid == "booted" {
    let booted = all.filter { ($0["state"] as? String) == "Booted" }
    guard booted.count == 1 else {
      fail(booted.isEmpty ? "No simulator is booted." : "\(booted.count) simulators are booted. Pass a UDID instead of \"booted\".")
    }
    return device(booted[0])
  }
  guard let d = all.first(where: { ($0["udid"] as? String) == udid }) else { fail("No simulator with UDID \(udid).") }
  return device(d)
}

func deviceHub() -> AXUIElement {
  // While the screen is locked DeviceHub reports its windows as the app
  // itself, with nothing inside them.
  let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
  if (session["CGSSessionScreenIsLocked"] as? Bool) == true {
    fail("The Mac's screen is locked, so DeviceHub's window can't be read. Unlock it and try again.")
  }
  guard AXIsProcessTrusted() else {
    fail("This terminal needs Accessibility access (System Settings > Privacy & Security > Accessibility).")
  }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
  p.arguments = ["-x", "DeviceHub"]
  let out = Pipe()
  p.standardOutput = out
  try! p.run()
  p.waitUntilExit()
  let pids = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
  guard let pid = pids.split(separator: "\n").first.flatMap({ pid_t($0) }) else {
    fail("DeviceHub isn't running. Open it with: open -a DeviceHub")
  }
  let app = AXUIElementCreateApplication(pid)
  // DeviceHub's accessibility interface sometimes stops answering, even when
  // the app is idle. Nothing short of a relaunch has brought it back.
  AXUIElementSetMessagingTimeout(app, 5)
  var role: CFTypeRef?
  if AXUIElementCopyAttributeValue(app, "AXRole" as CFString, &role) != .success {
    fail("""
    DeviceHub isn't answering accessibility requests. Quit and reopen it, then boot
    the simulators again (quitting DeviceHub shuts down the simulators it shows).
    """)
  }
  return app
}

func windows(_ app: AXUIElement) -> [AXUIElement] {
  elements(attr(app, "AXWindows")).filter { str($0, "AXRole") == "AXWindow" }
}

// The UDID of the device a window's sidebar has selected, or nil when the
// sidebar is hidden.
func selectedUDID(_ w: AXUIElement) -> String? {
  guard let sidebar = find(w, { str($0, "AXRole") == "AXOutline" }),
        let row = elements(attr(sidebar, "AXSelectedRows")).first,
        let cell = find(row, maxDepth: 6, { str($0, "AXIdentifier").hasPrefix("TableRow.Device.") }) else { return nil }
  return String(str(cell, "AXIdentifier").dropFirst("TableRow.Device.".count))
}

// Matched by the sidebar's selected UDID, so two simulators with the same name
// never share a window. Titles ("iPhone Duo – iOS 27.1") are the fallback for
// a window with its sidebar hidden, and only when the name is unique.
func windowShowing(_ app: AXUIElement, _ device: (udid: String, name: String, state: String, nameIsShared: Bool)) -> AXUIElement? {
  let all = windows(app)
  if let w = all.first(where: { selectedUDID($0) == device.udid }) { return w }
  guard !device.nameIsShared else { return nil }
  return all.first { selectedUDID($0) == nil && str($0, "AXTitle").hasPrefix(device.name + " – ") }
}

func pressMenu(_ app: AXUIElement, _ menu: String, _ item: String) {
  guard let bar = element(attr(app, "AXMenuBar")),
        let top = children(bar).first(where: { str($0, "AXTitle") == menu }),
        let entry = find(top, maxDepth: 3, { str($0, "AXTitle") == item }) else {
    fail("DeviceHub has no \(menu) > \(item) menu item.")
  }
  AXUIElementPerformAction(entry, "AXPress" as CFString)
}

// Select a device in a window's sidebar and wait for the window to show it.
func select(_ w: AXUIElement, _ udid: String) -> Bool {
  let rowID = "TableRow.Device.\(udid)"
  guard let cell = waitFor(5, { find(w, { str($0, "AXIdentifier") == rowID }) }) else { return false }
  var e: AXUIElement? = cell
  while let x = e, str(x, "AXRole") != "AXRow" { e = element(attr(x, "AXParent")) }
  guard let row = e else { return false }
  AXUIElementSetAttributeValue(row, "AXSelected" as CFString, kCFBooleanTrue)
  return waitFor(10, { selectedUDID(w) == udid ? true : nil }) != nil
}

// One window change at a time, across every session on this Mac. Two runs
// opening windows at once could each pick up the other's new window, and a
// run reusing an idle window could take one that reattach() has switched to a
// shut-down stand-in for a moment. Touches and reads don't take the lock, so
// one agent's long press doesn't hold up another agent's fold.
func withWindowLock<T>(_ body: () -> T) -> T {
  let fd = open((NSTemporaryDirectory() as NSString).appendingPathComponent("devicehubctl.lock"), O_CREAT | O_RDWR, 0o644)
  if fd >= 0 { flock(fd, LOCK_EX) }
  defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
  return body()
}

// The window for this device, opening a new one when no window shows it.
func window(for udid: String, _ app: AXUIElement) -> AXUIElement {
  let device = simDevice(udid)
  if device.state == "Booted", let w = windowShowing(app, device) { return w }
  return withWindowLock { openWindow(for: device, app) }
}

func openWindow(for device: (udid: String, name: String, state: String, nameIsShared: Bool), _ app: AXUIElement) -> AXUIElement {
  let (udid, name, state, _) = device
  guard state == "Booted" else { fail("\(name) is \(state). Boot it first: xcrun simctl boot \(udid)") }
  if let w = windowShowing(app, device) { return w }

  // A window left on a device that isn't booted (its simulator was shut down,
  // or a reattach didn't switch back) is nobody's view, so it's reused before
  // opening another. Without this, windows pile up over a day of sessions.
  let booted = Set(simctlDevices().filter { ($0["state"] as? String) == "Booted" }.compactMap { $0["udid"] as? String })
  if let idle = windows(app).first(where: { selectedUDID($0).map { !booted.contains($0) } ?? false }),
     select(idle, udid),
     waitFor(10, { str(idle, "AXTitle").hasPrefix(name + " – ") ? true : nil }) != nil {
    return idle
  }

  let before = Set(windows(app).map { CFHash($0) })
  pressMenu(app, "File", "New Window")
  guard let fresh = waitFor(10, { windows(app).first { !before.contains(CFHash($0)) } }) else {
    fail("DeviceHub didn't open a new window.")
  }
  // A new window starts on the device the last one showed.
  if selectedUDID(fresh) == udid { return fresh }
  guard select(fresh, udid),
        waitFor(10, { str(fresh, "AXTitle").hasPrefix(name + " – ") ? true : nil }) != nil else {
    fail("DeviceHub didn't switch to \(name).")
  }
  return fresh
}

// The action bar under the device: the group holding the Screenshot button,
// which every device has. The simulated iPhone's own accessibility tree (home
// screen icons, app buttons) is in the same window, so the search stays
// inside that group.
func controls(_ w: AXUIElement) -> [AXUIElement] {
  guard let shot = find(w, { str($0, "AXRole") == "AXButton" && str($0, "AXIdentifier") == "camera.viewfinder" }),
        let bar = element(attr(shot, "AXParent")) else { return [] }
  var found: [AXUIElement] = []
  func walk(_ e: AXUIElement, _ depth: Int) {
    if str(e, "AXSubrole") == "iOSContentGroup" { return }
    if str(e, "AXRole") == "AXButton", !str(e, "AXDescription").isEmpty { found.append(e) }
    guard depth < 3 else { return }
    for k in children(e) { walk(k, depth + 1) }
  }
  walk(bar, 0)
  return found
}

func press(_ w: AXUIElement, _ label: String) {
  guard let b = waitFor(5, { controls(w).first { str($0, "AXDescription").caseInsensitiveCompare(label) == .orderedSame } }) else {
    let have = controls(w).map { str($0, "AXDescription") }.joined(separator: ", ")
    fail("No \"\(label)\" control. This device has: \(have)")
  }
  let err = AXUIElementPerformAction(b, "AXPress" as CFString)
  guard err == .success else { fail("Pressing \"\(label)\" failed (AXError \(err.rawValue)).") }
}

// The simulated device's own accessibility tree: home screen icons, and the
// running app's buttons, text and fields. idb can't read an iPhone Duo; this can.
func screen(_ w: AXUIElement) -> AXUIElement? {
  find(w, { str($0, "AXSubrole") == "iOSContentGroup" })
}

// Every element with something to call it by under one element, depth first.
func named(under e: AXUIElement) -> [AXUIElement] {
  var found: [AXUIElement] = []
  func walk(_ e: AXUIElement) {
    if !label(e).isEmpty || !value(e).isEmpty || !str(e, "AXIdentifier").isEmpty { found.append(e) }
    for k in children(e) { walk(k) }
  }
  walk(e)
  return found
}

// Every element with something to call it by, depth first, in screen order.
// An identifier alone counts: an unlabelled group with id=Arrangement says
// which sheet is up. Navigation bar buttons (Edit, Done, Close, Cancel) never
// reach DeviceHub's tree at all; touch them by their place in a screenshot.
func screenElements(_ w: AXUIElement) -> [AXUIElement] {
  guard let root = screen(w) else { return [] }
  return children(root).flatMap { named(under: $0) }
}

func label(_ e: AXUIElement) -> String {
  let d = str(e, "AXDescription")
  return d.isEmpty ? str(e, "AXTitle") : d
}
// An adjustable element (a slider, or a SwiftUI stepper given the adjustable
// trait) reports its AXValue as a number, often nan, and what VoiceOver
// speaks as AXValueDescription ("3 times"). Print the spoken one.
func value(_ e: AXUIElement) -> String {
  let spoken = str(e, "AXValueDescription")
  if !spoken.isEmpty { return spoken }
  guard let v = attr(e, "AXValue") else { return "" }
  return (v as? String) ?? "\(v)"
}

// DeviceHub fills in the device's screen tree a few seconds after a boot or a
// pose change. With several devices open it sometimes leaves a window's tree
// empty for good; showing another device in that window and switching back
// brings it back. The stand-in is a shut-down simulator, so no running device
// is shown twice.
func reattach(_ w: AXUIElement, _ udid: String) {
  withWindowLock { switchAway(w, udid) }
}

func switchAway(_ w: AXUIElement, _ udid: String) {
  let standIn = simctlDevices().first { ($0["state"] as? String) == "Shutdown" && ($0["udid"] as? String) != udid }
  guard let other = standIn?["udid"] as? String, select(w, other) else { return }
  sleep(2)
  _ = select(w, udid)
}

func screenElements(_ w: AXUIElement, _ udid: String) -> [AXUIElement] {
  let nonEmpty = { () -> [AXUIElement]? in
    let found = screenElements(w)
    return found.isEmpty ? nil : found
  }
  if let found = waitFor(5, nonEmpty) { return found }
  reattach(w, udid)
  return waitFor(10, nonEmpty) ?? []
}

// An element by its label (case-insensitive) or identifier.
func named(_ target: String) -> (AXUIElement) -> Bool {
  { label($0).caseInsensitiveCompare(target) == .orderedSame || str($0, "AXIdentifier") == target }
}

func onScreen(_ w: AXUIElement, _ udid: String, _ target: String) -> [AXUIElement] {
  let matches = screenElements(w, udid).filter(named(target))
  return matches.isEmpty ? waitFor(5, { () -> [AXUIElement]? in
    let m = screenElements(w).filter(named(target))
    return m.isEmpty ? nil : m
  }) ?? [] : matches
}

// The one element called target. With several, a single control among text
// wins (a track header Button "Pulse 1" over the keyboard's caption "Pulse 1");
// otherwise this lists them rather than guess, and "Label#2" picks the second.
// Taking the first match used to long-press the wrong Songs row.
func onScreenOrFail(_ w: AXUIElement, _ udid: String, _ target: String) -> AXUIElement {
  var matches = onScreen(w, udid, target)
  var pick: Int?
  if matches.isEmpty, let hash = target.lastIndex(of: "#"), let n = Int(target[target.index(after: hash)...]), n > 0 {
    pick = n
    matches = onScreen(w, udid, String(target[..<hash]))
  }
  guard !matches.isEmpty else {
    let have = screenElements(w).map(label).filter { !$0.isEmpty }.joined(separator: ", ")
    fail("Nothing on screen called \"\(target)\". On screen: \(have)")
  }
  if let pick {
    guard pick <= matches.count else { fail("Only \(matches.count) elements are called \"\(target.prefix(upTo: target.lastIndex(of: "#")!))\".") }
    return matches[pick - 1]
  }
  if matches.count == 1 { return matches[0] }
  let text: Set<String> = ["AXStaticText", "AXHeading", "AXGroup"]
  let controls = matches.filter { !text.contains(str($0, "AXRole")) }
  if controls.count == 1 { return controls[0] }
  let list = matches.enumerated().map { "\(target)#\($0.offset + 1) (\(str($0.element, "AXRole").replacingOccurrences(of: "AX", with: "")))" }
  fail("\(matches.count) elements are called \"\(target)\": \(list.joined(separator: ", ")). Pick one with #n.")
}

func tap(_ w: AXUIElement, _ udid: String, _ target: String) {
  let e = onScreenOrFail(w, udid, target)
  let err = AXUIElementPerformAction(e, "AXPress" as CFString)
  // A tap that opens an app or a screen often removes the element before
  // DeviceHub can confirm the press, which reports "cannot complete".
  if err == .cannotComplete {
    FileHandle.standardError.write("Tapped \"\(target)\"; DeviceHub didn't confirm it. Check with tree.\n".data(using: .utf8)!)
    return
  }
  guard err == .success else { fail("Tapping \"\(target)\" failed (AXError \(err.rawValue)).") }
}

// MARK: Touches

// An accessibility press can't long-press or drag. Real touches go to dtuhidd,
// the digitizer service inside the simulator, over the same XPC route idb
// uses: CoreSimulator looks up the service's Mach port and two private
// libxpc functions turn it into a host-to-simulator connection. Unlike idb,
// this reaches the iPhone Duo's inner display. SimulatorKit's older
// IndigoHID mouse-event path is avoided on purpose: one of its messages
// crashed backboardd.

let digitizerService = "com.apple.coredevice.feature.remote.hid.digitizer"

// A point as fractions (0...1) of a display in its native orientation.
typealias Point = (x: Double, y: Double)

// The CoreSimulator methods used, called on objects from the private framework.
@objc protocol CoreSimulatorCalls {
  @objc(sharedServiceContextForDeveloperDir:error:) func sharedServiceContext(_ dir: String, _ error: NSErrorPointer) -> AnyObject?
  @objc(defaultDeviceSetWithError:) func defaultDeviceSet(_ error: NSErrorPointer) -> AnyObject?
  var devicesByUDID: NSDictionary { get }
  @objc(lookup:error:) func lookup(_ service: String, _ error: NSErrorPointer) -> mach_port_t
}

func output(_ tool: String, _ arguments: [String]) -> (status: Int32, text: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: tool)
  p.arguments = arguments
  let out = Pipe()
  p.standardOutput = out
  p.standardError = out
  try! p.run()
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func digitizerConnection(_ udid: String) -> xpc_connection_t {
  typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
  typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void
  guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil,
        let contextClass = NSClassFromString("SimServiceContext"),
        let endpointSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_endpoint_create_mach_port_4sim"),
        let sim2hostSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_connection_enable_sim2host_4sim") else {
    fail("Couldn't load CoreSimulator's touch support.")
  }
  let selected = output("/usr/bin/xcode-select", ["-p"])
  let developerDir = selected.status == 0 ? selected.text.trimmingCharacters(in: .whitespacesAndNewlines) : "/Applications/Xcode.app/Contents/Developer"
  var error: NSError?
  let calls = { (o: AnyObject) in unsafeBitCast(o, to: CoreSimulatorCalls.self) }
  guard let context = calls(contextClass).sharedServiceContext(developerDir, &error),
        let set = calls(context).defaultDeviceSet(&error),
        let uuid = NSUUID(uuidString: udid),
        let device = calls(set).devicesByUDID[uuid] as AnyObject? else {
    fail("CoreSimulator doesn't know \(udid).\(error.map { " \($0.localizedDescription)" } ?? "")")
  }
  let port = calls(device).lookup(digitizerService, &error)
  guard port != MACH_PORT_NULL else {
    fail("The simulator's touch service isn't running.\(error.map { " \($0.localizedDescription)" } ?? "")")
  }
  let endpointFromPort = unsafeBitCast(endpointSymbol, to: EndpointFromPort.self)
  guard let endpoint = endpointFromPort(port, 0, 0)?.takeRetainedValue() as? xpc_endpoint_t else {
    fail("Couldn't connect to the simulator's touch service.")
  }
  let connection = xpc_connection_create_from_endpoint(endpoint)
  // Without this the service sees the connection but never a message.
  unsafeBitCast(sim2hostSymbol, to: EnableSim2Host.self)(connection)
  xpc_connection_set_event_handler(connection) { _ in }
  xpc_connection_resume(connection)
  return connection
}

func message(_ type: String, _ payload: xpc_object_t, barrier: Bool) -> xpc_object_t {
  let m = xpc_dictionary_create(nil, nil, 0)
  xpc_dictionary_set_string(m, "messageType", type)
  xpc_dictionary_set_bool(m, "isBarrier", barrier)
  xpc_dictionary_set_string(m, "featureIdentifier", digitizerService)
  xpc_dictionary_set_value(m, "payload", payload)
  return m
}

// A no-op key event sent as a barrier. dtuhidd answers it only once
// everything before it is handled.
func barrier(_ c: xpc_connection_t) -> Bool {
  let p = xpc_dictionary_create(nil, nil, 0)
  xpc_dictionary_set_uint64(p, "usageCode", 0)
  xpc_dictionary_set_uint64(p, "state", 2)
  let reply = xpc_connection_send_message_with_reply_sync(c, message("IndigoKeyboardButtonEvent", p, barrier: true))
  return xpc_get_type(reply) != XPC_TYPE_ERROR
}

enum Phase: UInt64 { case start = 0, move = 1, end = 2 }

// Opens the connection, runs the gesture, and waits for dtuhidd to finish it.
// dtuhidd opens its own services on the first message and drops events that
// arrive meanwhile, so it gets a barrier and a moment before the first touch.
func touches(_ udid: String, display: UInt64, _ gesture: ((Phase, Point) -> Void) -> Void) {
  let c = digitizerConnection(udid)
  guard barrier(c) else { fail("The simulator's touch service didn't answer.") }
  usleep(300_000)
  gesture { phase, point in
    let p = xpc_dictionary_create(nil, nil, 0)
    let pt = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_double(pt, "x", min(max(point.x, 0), 1))
    xpc_dictionary_set_double(pt, "y", min(max(point.y, 0), 1))
    xpc_dictionary_set_value(p, "pointOne", pt)
    xpc_dictionary_set_uint64(p, "eventType", phase.rawValue)
    xpc_dictionary_set_uint64(p, "edge", 0)
    xpc_dictionary_set_uint64(p, "target", display)
    xpc_connection_send_message(c, message("IndigoDigitizerEvent", p, barrier: false))
    let sent = DispatchSemaphore(value: 0)
    xpc_connection_send_barrier(c) { sent.signal() }
    sent.wait()
  }
  if !barrier(c) { FileHandle.standardError.write("The touch service didn't confirm the last touch.\n".data(using: .utf8)!) }
  xpc_connection_cancel(c)
}

func hold(_ udid: String, display: UInt64, _ at: Point, seconds: Double) {
  touches(udid, display: display) { send in
    send(.start, at)
    usleep(useconds_t(seconds * 1_000_000))
    send(.end, at)
  }
}

// About 60 moves a second, which scrolls lists the way a finger does.
func drag(_ udid: String, display: UInt64, from a: Point, to b: Point, seconds: Double) {
  touches(udid, display: display) { send in
    let steps = max(2, Int(seconds / 0.016))
    send(.start, a)
    for i in 1...steps {
      usleep(useconds_t(seconds / Double(steps) * 1_000_000))
      let t = Double(i) / Double(steps)
      send(.move, (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
    }
    send(.end, b)
  }
}

// MARK: Which display

// dtuhidd's digitizer targets. A Duo's outer display is the main touchscreen;
// its inner display is target 3. Other devices have only the main one.
enum Display { case outer, inner }
func digitizerTarget(_ d: Display) -> UInt64 { d == .inner ? 3 : 0 }

func isDuo(_ udid: String) -> Bool {
  let d = simctlDevices().first { ($0["udid"] as? String) == udid }
  return (d?["deviceTypeIdentifier"] as? String) == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
}

// A simctl screenshot of one display: its size in pixels, and a small grey
// thumbnail, enough to tell black from live. Kept for the rest of the run
// unless a fresh one is asked for, since each takes 0.4 to 1.5 s.
var screenshots: [Int: (size: CGSize, grey: [UInt8])] = [:]
func screenshot(_ udid: String, _ number: Int, fresh: Bool = false) -> (size: CGSize, grey: [UInt8])? {
  if !fresh, let kept = screenshots[number] { return kept }
  let file = (NSTemporaryDirectory() as NSString).appendingPathComponent("devicehubctl-\(getpid())-\(number).png")
  defer { try? FileManager.default.removeItem(atPath: file) }
  guard output("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", "--display=\(number)", file]).status == 0,
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
  let (width, height) = (96, 96)
  var pixels = [UInt8](repeating: 0, count: width * height)
  let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }
  guard drawn else { return nil }
  let shot = (size: CGSize(width: image.width, height: image.height), grey: pixels)
  screenshots[number] = shot
  return shot
}

func screenshotNumber(_ d: Display) -> Int { d == .inner ? 3 : 1 }

// True when a simctl screenshot of that display is all black, which is how
// the display that isn't live captures.
func displayIsBlack(_ udid: String, _ number: Int, fresh: Bool = false) -> Bool? {
  screenshot(udid, number, fresh: fresh).map { !$0.grey.contains { $0 > 8 } }
}

// DeviceHub takes the pose press at once but the simulator gets there later,
// 3 to 5 s on a loaded Mac, and an agent that screenshots too soon gets the
// old screen. So a pose returns only once the outer display has gone black
// (opening) or lit up (closing), and the screen tree has filled in again.
// Only the outer display is polled: its screenshots take a third as long.
func settle(_ w: AXUIElement, _ udid: String, live want: Display, since start: Date, _ label: String) {
  let landed = waitFor(15) { displayIsBlack(udid, 1, fresh: true).map { $0 == (want == .inner) ? true : nil } ?? nil }
  guard landed != nil else { fail("Pressed \(label), but after 15 s the \(want) display still isn't the live one.") }
  _ = screenElements(w, udid)
  print("\(label): \(want) display live after \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
}

// DeviceHub's pose buttons don't say which pose is current, so a Duo's live
// display is found from screenshots: the one that isn't live is black.
func liveDisplay(_ udid: String, override: Display?) -> Display {
  if let override { return override }
  guard isDuo(udid) else { return .outer }
  let outerBlack = displayIsBlack(udid, 1), innerBlack = displayIsBlack(udid, 3)
  switch (outerBlack, innerBlack) {
  case (true, false): return .inner
  case (false, true): return .outer
  default: fail("Can't tell which of the Duo's displays is live. Pass --display outer or --display inner.")
  }
}

// MARK: Screenshot points to touch points

// Rotations made with `rotate`, kept per simulator so touches can follow them.
// A rotation made by hand in DeviceHub isn't seen; the screenshot's shape
// catches most of those (see quarterTurns).
func turnsFile(_ udid: String) -> String {
  (NSTemporaryDirectory() as NSString).appendingPathComponent("devicehubctl-turns-\(udid)")
}
func recordedTurns(_ udid: String) -> Int {
  (try? String(contentsOfFile: turnsFile(udid), encoding: .utf8)).flatMap { Int($0) } ?? 0
}
func recordTurns(_ udid: String, _ turns: Int) {
  try? String((turns % 4 + 4) % 4).write(toFile: turnsFile(udid), atomically: true, encoding: .utf8)
}

// Quarter turns between what a screenshot shows and the digitizer's native
// frame. The inner display starts one turn off (its screenshots are
// landscape, its digitizer portrait), and each `rotate` adds one, as long as
// the app follows the device. When the screenshot's shape says the app didn't
// (Chiptune stays portrait on the outer display), the app's own orientation
// is the one that counts.
func quarterTurns(_ udid: String, _ d: Display) -> Int {
  let base = d == .inner ? 1 : 0
  let turns = (base + recordedTurns(udid)) % 4
  guard let size = screenshot(udid, screenshotNumber(d))?.size else { return turns }
  let landscape = size.width > size.height
  return (turns % 2 == 1) == landscape ? turns : (landscape ? 1 : 0)
}

// A point as fractions of the display's screenshot, as saved, to the
// digitizer's frame. Checked on the outer display at 0, 1 and 3 turns and on
// the inner display at 0 and 1.
func touchPoint(_ p: Point, _ udid: String, on d: Display) -> Point {
  var p = p
  for _ in 0..<quarterTurns(udid, d) { p = (p.y, 1 - p.x) }
  return p
}

func frame(_ e: AXUIElement) -> CGRect? {
  guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return nil }
  var origin = CGPoint.zero, size = CGSize.zero
  guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
  return CGRect(origin: origin, size: size)
}

// Where to touch an element, in the digitizer's frame. The screen tree's frame
// doesn't say where the live display is: on a Duo it is always the inner
// display's native portrait size (626 x 890 points) whichever is live. Apps
// lay their elements out the way the screenshot shows them, landscape on the
// inner display and at the same scale (so a smaller box) on the outer one.
// SpringBoard lays the Home Screen out in the display's native frame instead,
// and turns it as a whole. So the scale comes from the inner display (or the
// only one), the live display's box is its screenshot at that scale, and on
// a turned display the Home Screen (found by its page dots or its search
// button; an app's scrolled-off content rules out judging by extent) is read
// as native.
func touchPoint(of e: AXUIElement, _ w: AXUIElement, _ udid: String, on d: Display) -> Point {
  guard let root = screen(w), let r = frame(root), r.width > 0, r.height > 0, let f = frame(e),
        let live = screenshot(udid, screenshotNumber(d))?.size,
        let full = (isDuo(udid) ? screenshot(udid, 3) : screenshot(udid, 1))?.size else {
    fail("DeviceHub didn't give a frame for \"\(label(e))\".")
  }
  let scale = max(r.width, r.height) / max(full.width, full.height)
  let box = CGSize(width: live.width * scale, height: live.height * scale)
  let (x, y) = (Double(f.midX - r.minX), Double(f.midY - r.minY))
  if quarterTurns(udid, d) % 2 == 1 {
    if pageDots(w) != nil || screenElements(w).contains(where: { str($0, "AXIdentifier") == "spotlight-search-button" }) {
      return (x / Double(box.height), y / Double(box.width))
    }
  }
  return touchPoint((x / Double(box.width), y / Double(box.height)), udid, on: d)
}

func longPress(_ w: AXUIElement, _ udid: String, _ target: String, seconds: Double, display: Display?) {
  let e = onScreenOrFail(w, udid, target)
  let d = liveDisplay(udid, override: display)
  hold(udid, display: digitizerTarget(d), touchPoint(of: e, w, udid, on: d), seconds: seconds)
}

// Type with the on-screen keyboard, one key press at a time. Each key is a
// button in the screen tree, labelled with what it types ("a", "A" while
// Shift is on, "1" on the numbers layout). A character that isn't showing
// sends Shift or a layout key first. The keyboard comes last in the tree, so
// the last match is the key, not an app button with the same label.
func type(_ w: AXUIElement, _ udid: String, _ text: String) {
  let names: [Character: String] = [" ": "space", "&": "ampersand"]
  func key(_ label: String, in all: [AXUIElement]) -> AXUIElement? {
    all.last { str($0, "AXDescription") == label || (label != " " && str($0, "AXIdentifier") == label) }
  }
  // Reading the whole screen takes about 3 s on a busy app. The keys sit
  // loose at the end of the screen tree's top level, so only the last stretch
  // of it, from 60 elements before the space bar, is read for each key.
  _ = screenElements(w, udid)
  guard let root = screen(w),
        let space = children(root).lastIndex(where: { key("space", in: named(under: $0)) != nil }) else {
    fail("No keyboard on screen. Tap or touch a text field first.")
  }
  let from = max(0, space - 60)
  func keys() -> [AXUIElement] {
    children(root).dropFirst(from).flatMap { named(under: $0) }.filter { str($0, "AXRole") == "AXButton" }
  }
  for c in text {
    let want = names[c] ?? String(c)
    var pressed = false
    for _ in 0..<4 {
      let all = keys()
      if let k = key(want, in: all) {
        AXUIElementPerformAction(k, "AXPress" as CFString)
        pressed = true
        break
      }
      // Letters live on the letters layout, under or over Shift; the rest
      // on the numbers or symbols layout.
      let switchTo = c.isLetter
        ? (key("letters", in: all) == nil ? "shift" : "letters")
        : (key("numbers", in: all) != nil ? "numbers" : (key("symbols", in: all) != nil ? "symbols" : "numbers"))
      guard let s = key(switchTo, in: all) else { break }
      AXUIElementPerformAction(s, "AXPress" as CFString)
      usleep(250_000)
    }
    guard pressed else { fail("The keyboard has no key for \"\(c)\". Typed up to it.") }
    usleep(120_000)
  }
}

let splitItem = "com.apple.springboardhome.application-shortcut-item.open-in-split"

// The Home Screen's page dots, which the tree lists as a slider valued
// "Page 2 of 3". Its increment and decrement actions turn the page; a swipe
// sent as touches doesn't.
func pageDots(_ w: AXUIElement) -> (dots: AXUIElement, page: Int, of: Int)? {
  guard let dots = screenElements(w).first(where: { value($0).hasPrefix("Page ") }) else { return nil }
  let n = value(dots).split(separator: " ").compactMap { Int($0) }
  return n.count == 2 ? (dots, n[0], n[1]) : nil
}

func turnPage(_ w: AXUIElement, forward: Bool) {
  guard let before = pageDots(w) else { return }
  AXUIElementPerformAction(before.dots, (forward ? "AXIncrement" : "AXDecrement") as CFString)
  _ = waitFor(3, { pageDots(w).flatMap { $0.page != before.page ? true : nil } })
}

// The icon on the current Home Screen page, or else on the first page that
// has it, turning back to page one first.
func homeIcon(_ w: AXUIElement, _ udid: String, _ icon: String) -> AXUIElement? {
  if let e = screenElements(w, udid).first(where: named(icon)) { return e }
  guard let start = pageDots(w) else { return nil }
  for _ in 1..<max(start.page, 1) { turnPage(w, forward: false) }
  for page in 1...start.of {
    if page > 1 { turnPage(w, forward: true) }
    if let e = waitFor(1, { screenElements(w).first(where: named(icon)) }) { return e }
  }
  return nil
}

// Long-press a Home Screen icon and choose Open in Split View. The other half
// shows a Home Screen that DeviceHub leaves out of the screen tree, but an app
// launched then opens there.
func split(_ w: AXUIElement, _ udid: String, _ icon: String, bundleID: String?, display: Display?) {
  guard let e = homeIcon(w, udid, icon) else {
    let pages = pageDots(w).map { " on any of the \($0.of) Home Screen pages" } ?? " on screen"
    fail("""
    No "\(icon)" icon\(pages).
    Press Home first if an app is open. An app that's only in the App Library can't
    be split this way: split with an icon that is on the Home Screen and pass the
    other app's bundle id.
    """)
  }
  // The menu opens only for a hold lifted between about 0.7 and 1.5 s: shorter
  // does nothing, and from about 2 s the Home Screen goes into jiggle mode
  // instead. So the hold is timed, not ended by watching the tree, whose reads
  // take 1 to 18 s. One retry after Home covers a touch SpringBoard missed.
  let shortcut = { (e: AXUIElement) in str(e, "AXIdentifier").hasPrefix("com.apple.springboardhome.application-shortcut-item") }
  let d = liveDisplay(udid, override: display)
  let at = touchPoint(of: e, w, udid, on: d)
  var found: AXUIElement?
  for attempt in 1...2 {
    hold(udid, display: digitizerTarget(d), at, seconds: 1.0)
    found = waitFor(4, { screenElements(w).first { str($0, "AXIdentifier") == splitItem } })
    if found != nil || attempt == 2 || screenElements(w).contains(where: shortcut) { break }
    press(w, "Home")
    sleep(1)
  }
  guard let item = found else {
    let offered = screenElements(w).filter(shortcut)
    let have = offered.map(label).joined(separator: ", ")
    // Home closes the menu, or ends jiggle mode if the hold started it.
    press(w, "Home")
    fail(offered.isEmpty
      ? "Long-pressing \"\(icon)\" didn't open its menu. Pressed Home to leave the Home Screen as it was."
      : "\"\(icon)\" has no Open in Split View. Its menu offered: \(have)")
  }
  let err = AXUIElementPerformAction(item, "AXPress" as CFString)
  guard err == .success || err == .cannotComplete else { fail("Choosing Open in Split View failed (AXError \(err.rawValue)).") }
  guard let bundleID else { return }
  sleep(2)
  let launched = output("/usr/bin/xcrun", ["simctl", "launch", udid, bundleID])
  guard launched.status == 0 else { fail("Split View opened, but launching \(bundleID) failed: \(launched.text)") }
}

let version = "0.4.1"

let usage = """
usage: devicehubctl <udid> controls            list the device's buttons
       devicehubctl <udid> press <label>       press one by its label
       devicehubctl <udid> pose closed|partial|open
       devicehubctl <udid> rotate [times]      rotate right, 90 degrees each
       devicehubctl <udid> tree                what's on the device's screen
       devicehubctl <udid> tap <label|id>      tap something on the screen
                                               (<label>#2 picks the second of several)
       devicehubctl <udid> type <text>         type with the on-screen keyboard
       devicehubctl <udid> longpress <label|id> [seconds]
                                               touch and hold it (1.2 s)
       devicehubctl <udid> split <icon> [<bundle id>]
                                               open a Home Screen app in Split View,
                                               and launch another app beside it
       devicehubctl <udid> touch <x> <y> [seconds]
       devicehubctl <udid> drag <x1> <y1> <x2> <y2> [seconds]
                                               touch or drag at fractions (0-1) of
                                               the display's simctl screenshot

<udid> may be "booted" when exactly one simulator is booted.
On an iPhone Duo, touches go to the live display. --display outer|inner
picks one instead.
"""

let started = Date()
var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--version" { print(version); exit(0) }
if args.first == "-h" || args.first == "--help" { print(usage); exit(0) }
var displayOverride: Display?
if let i = args.firstIndex(of: "--display") {
  guard i + 1 < args.count, let d = ["outer": Display.outer, "inner": .inner][args[i + 1]] else { fail(usage) }
  displayOverride = d
  args.removeSubrange(i...(i + 1))
}
guard args.count >= 2 else { fail(usage) }
let udid = args[0]

// touch and drag don't need DeviceHub's window, only a booted simulator.
func numbers(_ from: ArraySlice<String>) -> [Double] {
  let n = from.compactMap(Double.init)
  guard n.count == from.count else { fail(usage) }
  return n
}
if args[1] == "touch" || args[1] == "drag" {
  let device = simDevice(udid)
  guard device.state == "Booted" else { fail("\(device.name) is \(device.state). Boot it first: xcrun simctl boot \(device.udid)") }
  let n = numbers(args[2...])
  let points = args[1] == "touch" ? 2 : 4
  guard n.count == points || n.count == points + 1 else { fail(usage) }
  guard n.prefix(points).allSatisfy({ (0...1).contains($0) }) else {
    fail("x and y are fractions of the screenshot, from 0 to 1.")
  }
  let d = liveDisplay(device.udid, override: displayOverride)
  if points == 2 {
    hold(device.udid, display: digitizerTarget(d), touchPoint((n[0], n[1]), device.udid, on: d), seconds: n.count > 2 ? n[2] : 0.1)
  } else {
    drag(device.udid, display: digitizerTarget(d), from: touchPoint((n[0], n[1]), device.udid, on: d),
         to: touchPoint((n[2], n[3]), device.udid, on: d), seconds: n.count > 4 ? n[4] : 0.5)
  }
  exit(0)
}

let app = deviceHub()
let w = window(for: udid, app)
let target = selectedUDID(w) ?? simDevice(udid).udid

switch args[1] {
case "controls":
  for b in controls(w) { print(str(b, "AXDescription")) }
case "press" where args.count == 3:
  press(w, args[2])
case "pose" where args.count == 3:
  let labels = ["closed": "Closed", "partial": "Partially Open", "open": "Open"]
  guard let label = labels[args[2]] else { fail(usage) }
  press(w, label)
  settle(w, target, live: args[2] == "closed" ? .outer : .inner, since: started, label)
case "rotate":
  let times = args.count > 2 ? Int(args[2]) ?? 1 : 1
  for _ in 0..<times {
    press(w, "Rotate Right")
    usleep(700_000)
  }
  recordTurns(target, recordedTurns(target) + times)
case "tree":
  let elements = screenElements(w, target)
  guard !elements.isEmpty else { fail("DeviceHub isn't showing anything on this device's screen yet.") }
  for e in elements {
    let role = str(e, "AXRole").replacingOccurrences(of: "AX", with: "")
    var line = "\(role) \"\(label(e))\""
    if !value(e).isEmpty { line += " value=\"\(value(e))\"" }
    if !str(e, "AXIdentifier").isEmpty { line += " id=\(str(e, "AXIdentifier"))" }
    print(line)
  }
case "type" where args.count == 3:
  type(w, target, args[2])
case "tap" where args.count == 3:
  tap(w, target, args[2])
case "longpress" where args.count == 3 || args.count == 4:
  let seconds = args.count == 4 ? Double(args[3]) ?? -1 : 1.2
  guard seconds > 0 else { fail(usage) }
  longPress(w, target, args[2], seconds: seconds, display: displayOverride)
case "split" where args.count == 3 || args.count == 4:
  split(w, target, args[2], bundleID: args.count == 4 ? args[3] : nil, display: displayOverride)
default:
  fail(usage)
}
