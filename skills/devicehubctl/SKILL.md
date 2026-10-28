---
name: devicehubctl
description: >-
  Fold and unfold an iPhone Duo simulator (closed, partially open, open), rotate
  any iOS simulator, read the simulated screen, and tap, long-press or drag on it
  through Xcode 27's DeviceHub with the `devicehubctl` command-line tool. Use when
  a task needs a Duo pose, Split View on a Duo, the Duo's inner display, a rotation
  or landscape coverage, or when idb or a simulator MCP server's tree, tap and
  swipe tools fail on an iPhone Duo. Also use in bug hunts and UI checks that
  target a Duo.
---

# devicehubctl

simctl has no command to rotate a simulator or change an iPhone Duo's pose.
DeviceHub, which replaced Simulator.app in Xcode 27, has no AppleScript dictionary,
and System Events sees no UI in it. `devicehubctl` reaches DeviceHub's window
through the accessibility API and presses the same buttons a person would.

If `devicehubctl` isn't on PATH, install it from
https://github.com/ChrisThoma/devicehubctl (`swift build -c release`) or ask the
user to.

## Commands

```sh
devicehubctl <udid> pose closed|partial|open   # iPhone Duo only
devicehubctl <udid> rotate [times]             # 90° right each time
devicehubctl <udid> controls                   # the bar under the device
devicehubctl <udid> press "<label>"            # any of those, e.g. Home
devicehubctl <udid> tree                       # what's on the device's screen
devicehubctl <udid> tap "<label or id>"        # tap something listed by tree
devicehubctl <udid> type "<text>"              # type with the on-screen keyboard
devicehubctl <udid> longpress "<label or id>" [seconds]   # touch and hold, 1.2 s
devicehubctl <udid> split "<icon>" [<bundle id>]          # Duo Split View
devicehubctl <udid> touch <x> <y> [seconds]               # real touch at a point
devicehubctl <udid> drag <x1> <y1> <x2> <y2> [seconds]    # real drag, 0.5 s
```

Pass an explicit UDID from `xcrun simctl list devices`. `booted` works only when
exactly one simulator is booted.

## iPhone Duo displays

Pass `--display` to `simctl io <udid> screenshot` so you know which screen you
captured.

- `--display=1`: the outer screen, live when closed
- `--display=3`: the inner screen, live when partially open or open

The display that isn't live captures black. `pose` returns only once the fold
has landed (3 to 5 s) and prints how long it took, so a screenshot right after
it shows the new pose. A pose change is never instant: to fold during something
short (an export, an animation), make that thing last 10 s or more, or the fold
lands after it has finished.

## Reading and tapping the screen

On a Duo, use `tree` and `tap` in place of idb-based tools (for example a
simulator MCP server's `ui_describe_all`, `ui_find_element` and `ui_tap`). When
you hand simulator work to a subagent, say so alongside the UDID.

- `tree` prints each element's role, label, value and accessibility identifier,
  in screen order. It has no coordinates. Use labels, or identifiers where the app
  sets them. A slider or adjustable stepper's value is what VoiceOver speaks
  (`3 times`).
- Navigation bar buttons (Edit, Done, Close, Cancel in a sheet or popover) are
  never in `tree`; DeviceHub leaves them out. Their absence is not an app
  accessibility bug. Touch them at their place in a screenshot.
- `tap` matches a label exactly (case-insensitive) or an identifier, and then
  presses that element. If nothing matches it lists what's on screen. If several
  match and only one is a control, it presses that one; otherwise it lists them
  as `Label#1`, `Label#2`, and you pick with `tap "Label#2"`.
- `type "<text>"` types into the focused field by pressing the on-screen
  keyboard's keys, about one a second. Focus the field first (`touch` it, or
  `tap` it and check the keyboard came up). Text goes in at the cursor, which a
  touch puts where it lands. iOS autocorrect still applies, so
  read the field's value with `tree` afterwards. Hardware-only keys (arrows,
  Escape, Command shortcuts) can't be sent; report those journeys as blocked.
- An accessibility press isn't a finger. For a gesture the app handles itself,
  use the touch commands below.

## Touches: long press, touch, drag

`longpress`, `split`, `touch` and `drag` send real touches to the simulator's
digitizer service, on the Duo's inner display too.

- `longpress` finds an element the way `tap` does and holds its centre.
- `touch` and `drag` take x and y as fractions (0 to 1) of the screenshot
  `xcrun simctl io <udid> screenshot --display=N` saves, from its top left, as
  saved and not turned. The Duo's inner display counts in its landscape
  screenshot, and a rotated device in its rotated one. Read the point off a
  screenshot, then touch it.
- On a Duo, touches go to the live display, found by which display's screenshot
  isn't black. `--display outer|inner` overrides that.
- Drags scroll lists and move the Split View divider. A drag across the Home
  Screen does not turn the page.
- Touches follow rotations made with `rotate`. One made by hand in DeviceHub
  isn't seen, so rotate only with `devicehubctl`. Upside down is unchecked.
- Single finger only. No pinch.

## Split View on a Duo

```sh
devicehubctl <udid> pose open
devicehubctl <udid> press Home
devicehubctl <udid> split Settings <bundle id of the other app>
```

The icon's app takes the left half and the bundle id is launched into the right
half. `split` turns Home Screen pages to find the icon, holds it until its menu
shows, and presses Home if no menu comes, so the Home Screen isn't left in
jiggle mode. If the menu has no "Open
in Split View", it lists what the menu offered. The divider (x 0.5 in the inner
screenshot) settles back at half after a drag released between about 0.24 and
0.76; released at 0.18 or less, or 0.8 or more, Split View closes. Run `split`
again to get it back.

## Shared machines

- Only drive a simulator you booted or were assigned. `devicehubctl` refuses one
  that isn't booted and won't start one.
- If no DeviceHub window shows that device, it reuses a window left on a device
  that isn't booted, or else opens a new window, instead of switching one a
  person or another agent is looking at. Leave other windows
  alone.
- It needs the Mac unlocked. While the screen is locked, DeviceHub hides its
  windows from accessibility and `devicehubctl` says so. Tell the user instead of
  retrying in a loop.
- Several simulators can be driven at once, from several agents. Windows are
  matched by UDID. Runs wait for each other only while one opens or switches a
  window.
- Never close a DeviceHub window or quit DeviceHub: either shuts down the
  simulators it shows, including other people's.
- Shut down what you booted when you're done (`xcrun simctl shutdown <udid>`).

## When it breaks

- "needs Accessibility access": the app running the command (terminal, editor,
  agent host) needs it in System Settings > Privacy & Security > Accessibility.
  Ask the user to grant it.
- "DeviceHub isn't running": `open -a DeviceHub`.
- "DeviceHub isn't answering accessibility requests": it needs a relaunch, which
  shuts down every simulator it shows. Ask the user before quitting it.
- "Tapped ...; DeviceHub didn't confirm it": usually the tap opened something and
  the element went away. Run `tree` to see where you are.
- A pose or rotate label not found: run `controls` and compare. An Xcode update
  may have renamed DeviceHub's buttons. Report the new labels upstream.
