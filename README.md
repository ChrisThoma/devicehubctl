# devicehubctl

![devicehubctl: fold, rotate and tap iOS simulators from the terminal](https://individuation.dev/projects/devicehubctl/share-card.png)

Fold, unfold and rotate iOS simulators from the command line, and read, tap,
long-press or drag what's on their screen, through Xcode 27's DeviceHub.

```sh
devicehubctl <udid> pose open        # iPhone Duo: closed, partial or open
devicehubctl <udid> rotate           # 90° right
devicehubctl <udid> tree             # what's on the device's screen
devicehubctl <udid> tap "Continue"   # tap it
devicehubctl <udid> split Settings   # Split View on the Duo
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
| `devicehubctl <udid> tree` | List what's on the screen: role, label, value (what VoiceOver speaks, e.g. `3 times` for a stepper), identifier |
| `devicehubctl <udid> tap "<label or id>"` | Tap something `tree` listed. `"<label>#2"` picks the second of several |
| `devicehubctl <udid> type "<text>"` | Type into the focused field with the on-screen keyboard |
| `devicehubctl <udid> longpress "<label or id>" [seconds]` | Touch and hold it, 1.2 seconds unless you say otherwise |
| `devicehubctl <udid> split "<icon>" [<bundle id>]` | Open a Home Screen app in Split View, and launch another app beside it |
| `devicehubctl <udid> touch <x> <y> [seconds]` | Touch a point, 0.1 seconds unless you say otherwise |
| `devicehubctl <udid> drag <x1> <y1> <x2> <y2> [seconds]` | Drag from one point to another, 0.5 seconds unless you say otherwise |

`<udid>` comes from `xcrun simctl list devices`. You can pass `booted` when exactly
one simulator is booted. With more than one, it refuses rather than guess.

If no DeviceHub window shows the simulator, `devicehubctl` first reuses a window
left on a simulator that isn't booted, and otherwise opens a new window, rather
than switching one you or another tool are looking at.

### Several simulators at once

Each simulator gets its own DeviceHub window, matched by the UDID selected in the
window's sidebar, so two simulators with the same name never get mixed up. Runs
from different terminals or agents take turns through a lock file while one of
them opens or switches a window, so they never do that at the same moment. Taps,
touches, folds and reads don't wait for each other, so one agent's long press
doesn't hold up another agent's fold. Tested with two iPhone Duo simulators unfolded at
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

The display that isn't live captures black. `pose` returns once the fold has
landed, which takes 3 to 5 seconds: the display it lights is live and its screen
tree has filled in. It prints how long that took. A screenshot taken right after
it shows the new pose.

### Touches

`tap` presses an element through accessibility, which isn't a finger. `longpress`,
`split`, `touch` and `drag` send real touches to the simulator's digitizer service,
the way idb does, except they also reach the Duo's inner display.

`touch` and `drag` take points as fractions, 0 to 1, of the screenshot
`xcrun simctl io <udid> screenshot --display=N` saves, measured from its top left
corner. That's the screenshot as saved, without turning it, so the Duo's inner
display counts in its landscape screenshot even though the display is portrait
underneath, and a device turned with `rotate` counts in its turned screenshot.
`touch 0.5 0.5` is always the middle. These two don't need DeviceHub's window or
Accessibility access, only a booted simulator.

`rotate` records each turn per simulator, and touches follow it. If the app
didn't turn with the device (its screenshot keeps its shape), touches follow the
app instead. A rotation made by hand in DeviceHub isn't recorded; rotate back
upright by hand, or keep rotating with `devicehubctl`.

`longpress` and `split` find an element's place from the screen tree. DeviceHub
reports that tree's frame at the inner display's portrait size whichever display
is live, so `devicehubctl` measures the live display from its screenshot at the
same scale. Before 0.4.0 it didn't, and long presses on the outer display landed
up and to the left of their target.

On a Duo, touches go to whichever display is live, found by screenshotting both
and taking the one that isn't black. `--display outer` or `--display inner`
picks one instead.

Drags are a straight line at about 60 moves a second. They scroll lists and move
the Split View divider. They don't turn Home Screen pages; `split` turns pages
through accessibility instead.

### Split View on the iPhone Duo

```sh
devicehubctl <udid> pose open
devicehubctl <udid> press Home
devicehubctl <udid> split Settings dev.individuation.chiptune
```

`split` long-presses the icon, looking through the Home Screen's pages for it,
and chooses Open in Split View. It keeps the finger down until the icon's menu
shows and lifts it then, since holding on past the menu starts jiggle mode. If
no menu comes, it presses Home so the Home Screen isn't left jiggling. That app takes the left half. The right half
shows a Home Screen that DeviceHub leaves out of the screen tree, so `split`
launches the bundle id you pass with `simctl launch`, which opens it there. If
the icon's menu has no Open in Split View, it says what the menu offered.

The divider sits at x 0.5 of the inner display's screenshot. Dragging it moves
the panes while the finger is down, but on release they settle back at half,
from anywhere between about 0.24 and 0.76. Released at 0.18 or less, or 0.8 or
more, Split View closes and the app on the larger side fills the screen. An app
can still notice the resize: twice, Settings came back from a drag showing
General instead of its main list.

## Limits

- **Typing goes through the on-screen keyboard.** `type` presses its keys one at
  a time, about one a second, switching to Shift and the number or symbol
  layouts as it needs to. iOS autocorrect still applies, so check the field with
  `tree` afterwards. Keys that aren't on the on-screen keyboard (arrows, Escape,
  Command shortcuts) can't be sent, and setting a field's value through
  accessibility shows the text without the app receiving it.
- **Navigation bar buttons aren't in `tree`.** Edit, Done, Close and Cancel in
  a sheet's or popover's bar never reach DeviceHub's accessibility tree. Touch
  them at their place in a screenshot.
- **One finger.** `touch`, `drag` and `longpress` send a single touch. There's
  no pinch or two-finger gesture.
- **Rotation is checked on some turns.** Touches were checked on the outer
  display at 0, 1 and 3 turns and on the inner display at 0 and 1. Upside down
  hasn't been checked.
- **No Home Screen swipes.** A drag across the Home Screen doesn't turn the
  page. `split` uses the page dots' accessibility actions instead.
- **No coordinates in `tree`.** It lists elements by label and identifier only.
  Take coordinates for `touch` from a screenshot.
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
