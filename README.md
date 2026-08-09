<p align="center">
  <img src="docs/assets/icon.png" alt="CaffeinateCat" width="128" height="128">
</p>


<h1 align="center">CaffeinateCat</h1>

A tiny macOS menu-bar app that keeps your Mac awake — and, when you want it to, keeps it running **even with the lid closed and unplugged**.

Perfect for when you've got something that needs to keep going: a build, a local server, a long download, or a coding agent working away — but you want to shut the lid and slip your laptop into a bag.

---

## What it does

CaffeinateCat lives in your menu bar as a little coffee cup ☕️ and gives you two levels of "stay awake":

| Mode | Screen | Idle sleep | Lid closed |
| --- | --- | --- | --- |
| **Keep Screen Awake** | stays on | prevented | Mac sleeps |
| **Keep Awake on Lid Close** | stays on | prevented | **stays awake** (even on battery) |

"Keep Awake on Lid Close" is a superset of the other: when the lid is open it behaves exactly the same, and when you close the lid it keeps everything running.

On launch, **Keep Screen Awake turns on automatically (Indefinite)**, so the app just works the moment you open it.

### The panel

Clicking the menu bar icon drops down a panel with a switch for each mode:

```
┌──────────────────────────────────────────┐
│  Keep Screen Awake                 ●───  │
│  Prevents display sleep…                 │
│  ┌──────────┬─────┬─────┬────┬────────┐  │
│  │Indefinite│ 15m │ 30m │ 1h │ Custom │  │
│  └──────────┴─────┴─────┴────┴────────┘  │
│  Awake — 27:14 left                      │
├──────────────────────────────────────────┤
│  Keep Awake on Lid Close           ───●  │
│  Continues running with the lid closed   │
├──────────────────────────────────────────┤
│  Quit                                ⌘Q  │
└──────────────────────────────────────────┘
```

The two switches are mutually exclusive — turning one on turns the other off. Each remembers its own duration. Picking **Custom** reveals hours and minutes fields with stepper arrows, so any duration is reachable; typing or clicking an arrow restarts the timer straight away.

While a timer runs, the remaining time shows next to the menu bar icon as well as in the panel. When it expires, the Mac goes back to sleeping normally.

---

## How it works

- **Keep Screen Awake** uses `ProcessInfo.beginActivity` with idle-system and idle-display sleep assertions. No special permissions needed.
- **Keep Awake on Lid Close** sets the `SleepDisabled` flag in `IOPMrootDomain` via `pmset -a disablesleep 1`. This is the only reliable way to keep an Apple Silicon Mac awake with the lid shut on battery power.

Because `pmset` needs root, the app installs a small, tightly-scoped [`sudoers`](https://www.sudo.ws/docs/man/sudoers.man/) rule the **first time you enable lid-closed mode** (or on first launch, if you opt in). This asks for your administrator password **once** via a native macOS prompt (Touch ID works too), and grants passwordless access to *exactly* these two commands and nothing else:

```
pmset -a disablesleep 1
pmset -a disablesleep 0
```

After that, the feature works silently with no more prompts. The rule is validated with `visudo` before installation and lives at `/etc/sudoers.d/caffeinatecat`.

> **Safety:** the app always restores normal sleep behaviour (`disablesleep 0`) when you turn a mode off or quit — so it can never leave your Mac permanently unable to sleep.

---

## Building from source

CaffeinateCat is a handful of Swift files with no dependencies and no Xcode project:

```sh
swiftc -o CaffeinateCat *.swift
```

| File | What's in it |
| --- | --- |
| `main.swift` | Entry point |
| `CaffeinateCat.swift` | App delegate: modes, timers, menu bar item, `pmset` + `sudoers` |
| `PanelController.swift` | The popover — anchoring, sizing, dismissal |
| `PanelView.swift` | Panel layout |
| `Controls.swift` | Custom-drawn switch, segmented control, duration fields |
| `Theme.swift` | Colours, fonts, and metrics |

---

## Requirements

- macOS 11 (Big Sur) or later
- Administrator access (once) to enable the lid-closed feature

---

## Sharing it

The app is designed to be shareable — no developer account or code signing required. When a friend or family member runs it for the first time, it sets up its own permission with a single native admin prompt. Since it's unsigned, they may need to right-click → **Open** the first time to get past Gatekeeper.

---

## Uninstalling

Delete the app, then remove the sudoers rule it installed:

```sh
sudo rm /etc/sudoers.d/caffeinatecat
```
