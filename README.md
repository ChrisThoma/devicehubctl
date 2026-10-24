# devicehubctl

Fold, unfold and rotate iOS simulators from the command line, and read or tap
what's on their screen, through Xcode 27's DeviceHub.

```sh
devicehubctl <udid> pose open        # iPhone Duo: closed, partial or open
devicehubctl <udid> rotate           # 90° right
devicehubctl <udid> tree             # what's on the device's screen
devicehubctl <udid> tap "Continue"   # tap it
```

More about it:
[individuation.dev/projects/devicehubctl](https://individuation.dev/projects/devicehubctl/).

## Why

In Xcode 27, DeviceHub replaced Simulator.app, and the only way to change an
iPhone Duo simulator's pose is the buttons under the device in its window. `simctl`
has no command for poses or rotation, DeviceHub has no AppleScript dictionary, and
System Events can't see its UI. That leaves scripts, CI and coding agents with no
way to test the inner display without a person clicking.

The macOS accessibility API, called directly, does see DeviceHub's window.
`devicehubctl` finds the window showing a simulator and presses the same buttons a
person would.

The same window holds the simulated device's own accessibility tree, so
`devicehubctl` can also list and tap what's on screen. That matters on the iPhone
Duo, where idb, and the simulator MCP servers built on it, can't read the screen.

## Requirements

- macOS with Xcode 27.1 or later (DeviceHub). Tested with Xcode 27.1 and the
  iOS 27.1 iPhone Duo simulator.
- DeviceHub running (`open -a DeviceHub`) and the simulator booted.
- Accessibility access for the app you run it from (Terminal, iTerm, your
  editor) in System Settings > Privacy & Security > Accessibility.
- An unlocked screen. While the Mac is locked, DeviceHub hides its windows from
  the accessibility API, and `devicehubctl` says so.

## Install

```sh
git clone https://github.com/ChrisThoma/devicehubctl.git
cd devicehubctl
swift build -c release
cp .build/release/devicehubctl /usr/local/bin/
```

## Commands

| Command | What it does |
| --- | --- |
| `devicehubctl <udid> pose closed\|partial\|open` | Fold or unfold an iPhone Duo |
| `devicehubctl <udid> rotate [times]` | Rotate right, 90° each time |
| `devicehubctl <udid> controls` | List the buttons under the device |
| `devicehubctl <udid> press "<label>"` | Press one of them, e.g. `Home` |
| `devicehubctl <udid> tree` | List what's on the screen: role, label, value, identifier |
| `devicehubctl <udid> tap "<label or id>"` | Tap something `tree` listed |

`<udid>` comes from `xcrun simctl list devices`. You can pass `booted` when exactly
one simulator is booted. With more than one, it refuses rather than guess.

If no DeviceHub window shows the simulator, `devicehubctl` opens a new window for
it rather than switching one you or another tool are looking at.

### Several simulators at once

Each simulator gets its own DeviceHub window, matched by the UDID selected in the
window's sidebar, so two simulators with the same name never get mixed up. Runs
from different terminals or agents take turns through a lock file, so they never
open windows at the same moment. Tested with two iPhone Duo simulators unfolded at
the same time, and again with both renamed to the same name.

With several devices open, DeviceHub sometimes leaves a window's screen tree
empty. When `tree` or `tap` find it empty, `devicehubctl` briefly shows a
shut-down simulator in that window and switches back, which brings it back. The
running simulator isn't touched.

Two DeviceHub behaviors to know about:

- **Closing a DeviceHub window shuts down the simulator it shows,** and quitting
  DeviceHub shuts down all of them.
- **DeviceHub's accessibility interface can stop answering** even while the app
  is idle. `devicehubctl` says so when it happens. Quitting and reopening
  DeviceHub fixes it, then boot the simulators again.

### iPhone Duo screenshots

The Duo has two displays. Name the one you want:

```sh
xcrun simctl io <udid> screenshot --display=1 outer.png   # live when closed
xcrun simctl io <udid> screenshot --display=3 inner.png   # live when partially open or open
```

The display that isn't live captures black. Give a pose change about three seconds
before you screenshot.

## Limits

- **No typing.** Setting a text field's value through accessibility shows the
  text in the field, but the app never receives it. Use a launch argument, a
  fixture, or the app's own suggestion buttons.
- **No gestures.** `tap` performs the element's accessibility press. Drags, long
  presses and swipes the app handles itself need another route.
- **No coordinates.** `tree` lists elements by label and identifier only. Its
  frames come from DeviceHub's zoomed window, not the device's points.
- **Button labels can change.** It presses DeviceHub's buttons by their labels
  (Closed, Partially Open, Open, Rotate Right). If an Xcode update renames them,
  `controls` shows the new names.

## Agent skill

`skills/devicehubctl/SKILL.md` teaches a coding agent (Claude Code, Codex and
others) when and how to use the tool:

```sh
npx skills add ChrisThoma/devicehubctl
```

## License

MIT
