// Press DeviceHub's device controls (fold poses, rotate, Home) for one simulator.
//
// Xcode 27's DeviceHub replaced Simulator.app. simctl has no rotate or fold
// command, DeviceHub has no AppleScript dictionary, and System Events sees no
// UI in it. The accessibility API called directly does see the window,
// including the action bar under the device. This finds the window showing a
// given UDID (opening a new one rather than taking over a window another
// session is looking at) and presses a button there by its label.
//
// https://github.com/ChrisThoma/devicehubctl

import ApplicationServices
import Foundation

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

// Simulator UDID, name and state from simctl, so the window can be matched by
// title. "booted" is accepted when exactly one simulator is booted; with more,
// guessing could drive a device someone else is using.
func simDevice(_ udid: String) -> (udid: String, name: String, state: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  p.arguments = ["simctl", "list", "devices", "-j"]
  let out = Pipe()
  p.standardOutput = out
  try! p.run()
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  let all = (json["devices"] as! [String: Any]).values.compactMap { $0 as? [[String: Any]] }.joined()
  let device = { (d: [String: Any]) in (d["udid"] as! String, d["name"] as! String, d["state"] as! String) }
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
  return AXUIElementCreateApplication(pid)
}

func windows(_ app: AXUIElement) -> [AXUIElement] {
  elements(attr(app, "AXWindows")).filter { str($0, "AXRole") == "AXWindow" }
}

// Titles look like "iPhone Duo – iOS 27.1".
func windowShowing(_ app: AXUIElement, _ name: String) -> AXUIElement? {
  windows(app).first { str($0, "AXTitle").hasPrefix(name + " – ") }
}

func pressMenu(_ app: AXUIElement, _ menu: String, _ item: String) {
  guard let bar = element(attr(app, "AXMenuBar")),
        let top = children(bar).first(where: { str($0, "AXTitle") == menu }),
        let entry = find(top, maxDepth: 3, { str($0, "AXTitle") == item }) else {
    fail("DeviceHub has no \(menu) > \(item) menu item.")
  }
  AXUIElementPerformAction(entry, "AXPress" as CFString)
}

// The window for this device, opening a new one when no window shows it.
func window(for udid: String, _ app: AXUIElement) -> AXUIElement {
  let (udid, name, state) = simDevice(udid)
  guard state == "Booted" else { fail("\(name) is \(state). Boot it first: xcrun simctl boot \(udid)") }
  if let w = windowShowing(app, name) { return w }

  let before = Set(windows(app).map { CFHash($0) })
  pressMenu(app, "File", "New Window")
  guard let fresh = waitFor(10, { windows(app).first { !before.contains(CFHash($0)) } }) else {
    fail("DeviceHub didn't open a new window.")
  }
  // A new window starts on the device the last one showed.
  if str(fresh, "AXTitle").hasPrefix(name + " – ") { return fresh }
  let rowID = "TableRow.Device.\(udid)"
  guard let cell = waitFor(5, { find(fresh, { str($0, "AXIdentifier") == rowID }) }) else {
    fail("\(name) isn't in DeviceHub's sidebar.")
  }
  var e: AXUIElement? = cell
  while let x = e, str(x, "AXRole") != "AXRow" { e = element(attr(x, "AXParent")) }
  guard let row = e else { fail("Couldn't find the sidebar row for \(name).") }
  AXUIElementSetAttributeValue(row, "AXSelected" as CFString, kCFBooleanTrue)
  guard let w = waitFor(10, { windowShowing(app, name) }) else { fail("DeviceHub didn't switch to \(name).") }
  return w
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

// Every element with something to call it by, depth first, in screen order.
func screenElements(_ w: AXUIElement) -> [AXUIElement] {
  guard let root = screen(w) else { return [] }
  var found: [AXUIElement] = []
  func walk(_ e: AXUIElement) {
    if !label(e).isEmpty || !value(e).isEmpty { found.append(e) }
    for k in children(e) { walk(k) }
  }
  for k in children(root) { walk(k) }
  return found
}

func label(_ e: AXUIElement) -> String {
  let d = str(e, "AXDescription")
  return d.isEmpty ? str(e, "AXTitle") : d
}
func value(_ e: AXUIElement) -> String {
  guard let v = attr(e, "AXValue") else { return "" }
  return (v as? String) ?? "\(v)"
}

// DeviceHub fills in the device's screen tree a few seconds after a boot or a
// pose change.
let screenWait = 10.0

func tap(_ w: AXUIElement, _ target: String) {
  let matches = { (e: AXUIElement) in
    label(e).caseInsensitiveCompare(target) == .orderedSame || str(e, "AXIdentifier") == target
  }
  guard let e = waitFor(screenWait, { screenElements(w).first(where: matches) }) else {
    let have = screenElements(w).map(label).filter { !$0.isEmpty }.joined(separator: ", ")
    fail("Nothing on screen called \"\(target)\". On screen: \(have)")
  }
  let err = AXUIElementPerformAction(e, "AXPress" as CFString)
  guard err == .success else { fail("Tapping \"\(target)\" failed (AXError \(err.rawValue)).") }
}

let version = "0.1.0"

let usage = """
usage: devicehubctl <udid> controls            list the device's buttons
       devicehubctl <udid> press <label>       press one by its label
       devicehubctl <udid> pose closed|partial|open
       devicehubctl <udid> rotate [times]      rotate right, 90 degrees each
       devicehubctl <udid> tree                what's on the device's screen
       devicehubctl <udid> tap <label|id>      tap something on the screen

<udid> may be "booted" when exactly one simulator is booted.
"""

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--version" { print(version); exit(0) }
if args.first == "-h" || args.first == "--help" { print(usage); exit(0) }
guard args.count >= 2 else { fail(usage) }
let udid = args[0]
let app = deviceHub()
let w = window(for: udid, app)

switch args[1] {
case "controls":
  for b in controls(w) { print(str(b, "AXDescription")) }
case "press" where args.count == 3:
  press(w, args[2])
case "pose" where args.count == 3:
  let labels = ["closed": "Closed", "partial": "Partially Open", "open": "Open"]
  guard let label = labels[args[2]] else { fail(usage) }
  press(w, label)
case "rotate":
  let times = args.count > 2 ? Int(args[2]) ?? 1 : 1
  for _ in 0..<times {
    press(w, "Rotate Right")
    usleep(700_000)
  }
case "tree":
  guard let elements = waitFor(screenWait, { () -> [AXUIElement]? in
    let found = screenElements(w)
    return found.isEmpty ? nil : found
  }) else { fail("DeviceHub isn't showing anything on this device's screen yet.") }
  for e in elements {
    let role = str(e, "AXRole").replacingOccurrences(of: "AX", with: "")
    var line = "\(role) \"\(label(e))\""
    if !value(e).isEmpty { line += " value=\"\(value(e))\"" }
    if !str(e, "AXIdentifier").isEmpty { line += " id=\(str(e, "AXIdentifier"))" }
    print(line)
  }
case "tap" where args.count == 3:
  tap(w, args[2])
default:
  fail(usage)
}
