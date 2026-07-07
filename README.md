# ☕️ CaffeinateCat

A tiny macOS menu-bar app that keeps your Mac awake — and, when you want it to, keeps it running **even with the lid closed and unplugged**.

Perfect for when you've got something that needs to keep going: a build, a local server, a long download, or a coding agent working away — but you want to shut the lid and slip your laptop into a bag.

---

## What it does

CaffeinateCat lives in your menu bar as a little coffee cup ☕️ and gives you two levels of "stay awake":

| Mode | Screen | Idle sleep | Lid closed |
| --- | --- | --- | --- |
| **Caffeinate** | stays on | prevented | Mac sleeps |
| **Keep Awake When Lid Closed** | stays on | prevented | **stays awake** (even on battery) |

"Keep Awake When Lid Closed" is a superset of Caffeinate: when the lid is open it behaves exactly like Caffeinate, and when you close the lid it keeps everything running.

On launch, **Caffeinate turns on automatically (Indefinite)**, so the app just works the moment you open it.

### Timers

Both modes can run indefinitely or on a timer. Hover over the options to either mode to pick a duration:

```
☕️ CaffeinateCat
├─ ✓ Caffeinate                  ▸   Off · Indefinite · 15m · 30m · 1h · 2h · Custom…
│    Keep Awake When Lid Closed  ▸   Off · Indefinite · 15m · 30m · 1h · 2h · Custom…
├──────────────────────────────
└─ Quit
```

When a timer expires, the Mac goes back to sleeping normally.

---

## How it works

- **Caffeinate** uses `ProcessInfo.beginActivity` with idle-system and idle-display sleep assertions. No special permissions needed.
- **Keep Awake When Lid Closed** sets the `SleepDisabled` flag in `IOPMrootDomain` via `pmset -a disablesleep 1`. This is the only reliable way to keep an Apple Silicon Mac awake with the lid shut on battery power.

Because `pmset` needs root, the app installs a small, tightly-scoped [`sudoers`](https://www.sudo.ws/docs/man/sudoers.man/) rule the **first time you enable lid-closed mode** (or on first launch, if you opt in). This asks for your administrator password **once** via a native macOS prompt (Touch ID works too), and grants passwordless access to *exactly* these two commands and nothing else:

```
pmset -a disablesleep 1
pmset -a disablesleep 0
```

After that, the feature works silently with no more prompts. The rule is validated with `visudo` before installation and lives at `/etc/sudoers.d/caffeinatecat`.

> **Safety:** the app always restores normal sleep behaviour (`disablesleep 0`) when you turn a mode off or quit — so it can never leave your Mac permanently unable to sleep.

---

## Building from source

CaffeinateCat is a single Swift file with no dependencies and no Xcode project:

```sh
swiftc -o CaffeinateCat CaffeinateCat.swift
```

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
