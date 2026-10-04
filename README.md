<p align="center">
  <img src="docs/assets/icon.png" alt="CaffeinateCat" width="128" height="128">
</p>


<h1 align="center">CaffeinateCat</h1>

A tiny macOS menu-bar app that keeps your Mac awake — and, when you want it to, keeps it running **even with the lid closed and unplugged**.

Perfect for when you've got something that needs to keep going: a build, a local server, a long download, or a coding agent working away — but you want to shut the lid and slip your laptop into a bag.

---

## What it does

CaffeinateCat lives in your menu bar as a coffee cup ☕️ that doubles as a battery gauge: the drink inside sits at your battery's level (full, 80, 60, 40, 20, empty) — orange while it's keeping the Mac awake, grey when off — and the cup steams in lid-close mode. It gives you two levels of "stay awake":

| Mode | Screen | Idle sleep | Lid closed |
| --- | --- | --- | --- |
| **Keep Screen Awake** | stays on | prevented | Mac sleeps |
| **Keep Awake on Lid Close** | stays on | prevented | **stays awake** (even on battery) |

"Keep Awake on Lid Close" is a superset of the other: when the lid is open it behaves exactly the same, and when you close the lid it keeps everything running.

On launch, **Keep Screen Awake turns on automatically (Indefinite)**, so the app just works the moment you open it.

### The panel

Clicking the menu bar icon drops down a panel; **right-clicking** it turns keep-awake on or off in one go (using whichever mode you used last).

```
┌──────────────────────────────────────────┐
│  ☕ CaffeinateCat                ● Awake  │
├──────────────────────────────────────────┤
│  Keep Screen Awake                 ●───  │
│  Prevents display sleep…                 │
│  ┌──────────┬─────┬─────┬────┬────────┐  │
│  │Indefinite│ 15m │ 30m │ 1h │ Custom │  │
│  └──────────┴─────┴─────┴────┴────────┘  │
│  Awake — 27:14 left          until 14:32 │
│  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬───────────────── │
├──────────────────────────────────────────┤
│  Keep Awake on Lid Close           ───●  │
│  Continues running with the lid closed   │
├──────────────────────────────────────────┤
│  Options                              ⌄  │
│   ☐ Allow display to sleep               │
│   ☑ Turn off at 20% and 10% battery      │
│   ☑ Keep awake when app opens            │
│   ☐ Open at login                        │
│   Remove Lid-Close Permission…           │
├──────────────────────────────────────────┤
│  About CaffeinateCat                     │
│  Quit                                ⌘Q  │
└──────────────────────────────────────────┘
```

The two switches are mutually exclusive — turning one on turns the other off. Each remembers its own duration, across relaunches too. Picking **Custom** reveals hours and minutes fields with stepper arrows, so any duration is reachable; typing or clicking an arrow restarts the timer straight away.

While a timer runs, the remaining time shows next to the menu bar icon as well as in the panel, with the clock time it ends at. Timers are measured on a clock that keeps running while the Mac sleeps, so a run that spans a sleep ends when it should. When it expires, the Mac goes back to sleeping normally.

### Options

| Option | What it does |
| --- | --- |
| **Allow display to sleep** | Keeps the system awake but lets the screen turn off on its normal schedule. |
| **Turn off at 20% and 10% battery** | Switches keep-awake off as the battery falls through 20% and again through 10%, so a Mac in a bag can't run itself flat. On by default. |
| **Keep awake when app opens** | Starts *Keep Screen Awake* at launch (the old always-on behaviour). On by default. |
| **Open at login** | Installs a small LaunchAgent in `~/Library/LaunchAgents`. |
| **Remove Lid-Close Permission…** | Deletes the sudoers rule (shown only while it's installed). |

---

## How it works

- **Keep Screen Awake** uses `ProcessInfo.beginActivity` with idle-system and idle-display sleep assertions. No special permissions needed.
- **Keep Awake on Lid Close** sets the `SleepDisabled` flag in `IOPMrootDomain` via `pmset -a disablesleep 1`. This is the only reliable way to keep an Apple Silicon Mac awake with the lid shut on battery power.

Because `pmset` needs root, the app installs a small, tightly-scoped [`sudoers`](https://www.sudo.ws/docs/man/sudoers.man/) rule the **first time you enable lid-closed mode** (or on first launch, if you opt in). This asks for your administrator password **once** via a native macOS prompt (Touch ID works too), and grants passwordless access to *exactly* these two commands and nothing else:

```
pmset -a disablesleep 1
pmset -a disablesleep 0
```

After that, the feature works silently with no more prompts. The rule lives at `/etc/sudoers.d/caffeinatecat`.

> **Safety:** `disablesleep` persists across reboots, so the app goes to some lengths never to leave it set:
>
> - It restores `disablesleep 0` when you turn a mode off or quit, and on `SIGTERM`/`SIGINT`/`SIGHUP` — and reads the value back from `pmset -g` to confirm it took.
> - While lid mode is on, a tiny watchdog process in its own process group waits for the app to exit and restores sleep itself, so even a crash, Force Quit or `kill -9` can't strand the flag.
> - If the app ever dies holding the flag anyway (power loss, kernel panic), it notices on next launch and restores it. If restoring fails, it tells you the one command to run.
> - Every 30 seconds, and after each wake, it re-checks the flag is still set and the watchdog is still alive.
>
> The sudoers rule is written, validated with `visudo` and installed entirely by the privileged shell, into a root-owned temp file — nothing staged in a user-writable location can be swapped in between the check and the install.

---

## Building from source

CaffeinateCat is a handful of Swift files. Its one dependency is [Sparkle](https://sparkle-project.org), used for automatic updates; `build.sh` downloads a pinned, checksum-verified release and embeds it. A plain `swiftc` build works without Sparkle and simply has no updater (the "Check for Updates…" row is hidden).

For a quick local binary, with no updater:

```sh
swiftc -O -o CaffeinateCat *.swift
```

To build a proper, universal `CaffeinateCat.app` into `build/` (optimised, with Sparkle, icon and `Info.plist`):

```sh
sh build.sh                                        # ad-hoc signed
IDENTITY="Developer ID Application: …" sh build.sh # hardened runtime, ready to notarize
IDENTITY="…" NOTARY_PROFILE=myprofile sh build.sh  # also notarizes, staples and zips
```

`VERSION` and `BUILD` can be overridden the same way. `BUILD` is an integer that must go up with every release, because Sparkle compares it. `FEED_URL` points the app at a different update feed, which is handy for testing an update locally.

`NOTARY_PROFILE` is a `notarytool` keychain profile, created once with `xcrun notarytool store-credentials`.

With a real `IDENTITY`, the script also writes `build/CaffeinateCat.xcarchive` and copies it into Xcode's archive folder, so you can notarize by hand from **Window → Organizer → Distribute App → Direct Distribution**.

| File | What's in it |
| --- | --- |
| `main.swift` | Entry point |
| `CaffeinateCat.swift` | App delegate: modes, timers, safety checks, menu bar item, alerts |
| `Power.swift` | `pmset`, the `sudoers` rule, the crash watchdog, battery monitoring |
| `Settings.swift` | Saved preferences and the open-at-login agent |
| `Updater.swift` | Sparkle: update checks and the "update available" flag |
| `PanelController.swift` | The popover — anchoring, sizing, dismissal |
| `PanelView.swift` | Panel layout |
| `Controls.swift` | Custom-drawn switch, segmented control, duration fields, menu and option rows |
| `Theme.swift` | Colours, fonts, and metrics |
| `build.sh` | Builds, signs and optionally notarizes the `.app` without Xcode; embeds Sparkle |
| `tools/` | `fetch-sparkle.sh` (downloads the pinned Sparkle), `sparkle.conf` (its version, checksum and the update feed URL), `sparkle_public_key.txt` (the public key updates are verified with) |

--- | --- |
| `main.swift` | Entry point |
| `CaffeinateCat.swift` | App delegate: modes, timers, menu bar item, `pmset` + `sudoers` |
| `PanelController.swift` | The popover — anchoring, sizing, dismissal |
| `PanelView.swift` | Panel layout |
| `Controls.swift` | Custom-drawn switch, segmented control, duration fields |
| `Theme.swift` | Colours, fonts, and metrics |

---

## Requirements

- macOS 12 (Monterey) or later
- Administrator access (once) to enable the lid-closed feature

---

## Updates

From version 1.3.0 CaffeinateCat updates itself with [Sparkle](https://sparkle-project.org). It checks `https://noxdrop.com/caffeinateCat/appcast.xml`, and every update is signed (EdDSA) and verified before it is installed. **Check for Updates…** in the panel runs a check on demand. An update restarts the app, which turns lid-closed mode off.

## Sharing it

The app is designed to be shareable. When a friend or family member runs it for the first time, it sets up its own permission with a single native admin prompt. A notarized build (see `build.sh`) opens without warnings; an ad-hoc build may need right-click → **Open** the first time to get past Gatekeeper.

---

## Uninstalling

Use **Options → Remove Lid-Close Permission…** and untick **Open at login**, then delete the app. Or, by hand:

```sh
sudo rm /etc/sudoers.d/caffeinatecat
rm -f ~/Library/LaunchAgents/com.caffeinatecat.launcher.plist
```

---

© 2026 Prem Poddar · Noxdrop Systems
