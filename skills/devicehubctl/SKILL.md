---
name: devicehubctl
description: >-
  Fold and unfold an iPhone Duo simulator (closed, partially open, open), rotate
  any iOS simulator, and read or tap the simulated screen through Xcode 27's
  DeviceHub with the `devicehubctl` command-line tool. Use when a task needs a Duo
  pose, the Duo's inner display, a rotation or landscape coverage, or when idb or a
  simulator MCP server's tree and tap tools fail on an iPhone Duo. Also use in bug
  hunts and UI checks that target a Duo.
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
```

Pass an explicit UDID from `xcrun simctl list devices`. `booted` works only when
exactly one simulator is booted.

## iPhone Duo displays

Pass `--display` to `simctl io <udid> screenshot` so you know which screen you
captured.

- `--display=1`: the outer screen, live when closed
- `--display=3`: the inner screen, live when partially open or open

The display that isn't live captures black. After a pose change, wait about 3
seconds before screenshotting.

## Reading and tapping the screen

On a Duo, use `tree` and `tap` in place of idb-based tools (for example a
simulator MCP server's `ui_describe_all`, `ui_find_element` and `ui_tap`). When
you hand simulator work to a subagent, say so alongside the UDID.

- `tree` prints each element's role, label, value and accessibility identifier,
  in screen order. It has no coordinates. Use labels, or identifiers where the app
  sets them.
- `tap` matches a label exactly (case-insensitive) or an identifier, and then
  presses that element. If nothing matches it lists what's on screen.
- It can't type. Setting a field's value through accessibility shows the text
  without the app receiving it. Pick a suggestion button, use a launch argument or
  fixture, or report text entry as blocked.
- An accessibility press isn't a finger. A gesture the app handles itself (drag,
  long press, swipe) needs another route.

## Shared machines

- Only drive a simulator you booted or were assigned. `devicehubctl` refuses one
  that isn't booted and won't start one.
- If no DeviceHub window shows that device, it opens a new window instead of
  switching one a person or another agent is looking at. Leave other windows
  alone.
- It needs the Mac unlocked. While the screen is locked, DeviceHub hides its
  windows from accessibility and `devicehubctl` says so. Tell the user instead of
  retrying in a loop.
- Shut down what you booted when you're done (`xcrun simctl shutdown <udid>`).

## When it breaks

- "needs Accessibility access": the app running the command (terminal, editor,
  agent host) needs it in System Settings > Privacy & Security > Accessibility.
  Ask the user to grant it.
- "DeviceHub isn't running": `open -a DeviceHub`.
- A pose or rotate label not found: run `controls` and compare. An Xcode update
  may have renamed DeviceHub's buttons. Report the new labels upstream.
