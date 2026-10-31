# Deep Sleep

> **A native macOS sleep and power manager, written in Swift.** Keep the system awake, schedule sleep and wake, lock the lid, manage `pmset` settings, monitor CPU/RAM/temperature, and edit `/etc/hosts` — all from a single menubar app.

<p align="center">
  <img src="./docs/images/icon.png" width="128" alt="Deep Sleep icon">
</p>

macOS has never had a real answer to: *"I want my Mac to stay awake until this download finishes, sleep at 2am, and wake me up at 7:30."* `pmset` works, but its CLI is hostile. `caffeinate` does half the job. AlDente owns one slice of it. Deep Sleep owns the whole shape of sleep, wake, and power — and it stays out of your way the rest of the time.

![Platform](https://img.shields.io/badge/Platform-macOS%2026%2B-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Release](https://img.shields.io/github/v/release/Mofan2020/DeepSleep)
![Downloads](https://img.shields.io/github/downloads/Mofan2020/DeepSleep/total)

[中文文档](./README.zh-CN.md) · [Releases](https://github.com/Mofan2020/DeepSleep/releases)

- **Bundle ID**: `com.skyc8266.deepsleep`
- **App name**: Deep Sleep
- **Minimum system**: macOS 26.0
- **Language / framework**: Swift 5, SwiftUI + AppKit, IOKit, LocalAuthentication
- **当前版本**：1.9.3

## Highlights

- **Keep awake** — block idle sleep, keep the display lit, prevent system sleep (lid closed too).
- **Scheduled sleep & wake** — countdown sleep and scheduled wake, executed by the system power service. Schedule several one-off wake-ups or a repeating weekly one; cancelling removes only the entry Deep Sleep created.
- **Server mode** — keep the system awake forever, auto-lock the screen every N minutes.
- **Automation rules** — combine time windows, power source, and frontmost app into persistent rules evaluated every 5 seconds.
- **Full control** — install a privileged helper once, never re-enter your password. It writes `pmset -a disablesleep 1` if you want it to actually stick.
- **Siri, Shortcuts, Focus, Control Center** — `App Intents` exposes every action; full phrases via `deepsleep --automation`.
- **`deepsleep://` URL scheme** — call any action from shell scripts, AppleScript, or Automator.
- **Quick Quit** — bind a global hotkey (default ⌥⇧⌘H) to force-kill selected apps and their entire process tree.
- **Toolbox** — every tool lives on one page; pin the ones you use most to the top.
- **AI keep-alive** — send a tiny request to a subscription AI service at set times each day, so its rolling usage window keeps moving.
- **External activity** — see who else is blocking sleep or changing power settings (`--blockers`, `--changes`, `--rivals`).
- **System monitor** — CPU/RAM overload alerts, single-process RSS threshold, and live CPU temperature with an adjustable alert threshold (40–105°C). A temperature alert notifies you; it never freezes or kills a process.
- **Temperature monitoring** — live readings from the SoC, battery, and storage sensors. Reads the IOHID private temperature channel through the privileged helper, so the app and the 90°C fan fallback always agree on the numbers.
- **Fan control** — hand the fans back to the system, pin them to a fixed RPM, or map temperature to RPM with a rule of your own (target fan, low temperature, high temperature). Fixed and rule modes need the privileged helper and an accepted disclaimer. At 90°C every fan is forced to maximum regardless of your settings.
- **Custom alert rules** — your own thresholds on CPU load, memory use, per-process memory, CPU temperature, or disk usage, with a hold time before each one fires.
- **Prevent external disk sleep** — keeps attached disks out of their low-power idle state so transfers don't stall. Optional, in Power settings.
- **Menubar resident** — left-click opens main window, right-click opens quick settings, hides Dock icon when no windows are open.
- **Auto-update** — Sparkle-style with edDSA verification; the privileged helper updates itself in place.

## Requirements

- macOS 26.0 or later
- Touch ID recommended (for `Full Control` install)

## Install

```sh
brew install mofan2020/tap/deepsleep
```

Or download `DeepSleep.zip` from [Releases](https://github.com/Mofan2020/DeepSleep/releases), unzip, and drag `Deep Sleep.app` into `/Applications`.

The app is ad-hoc signed. If Gatekeeper blocks it on first launch, go to **System Settings → Privacy & Security** and click **Open Anyway**.

To build from source, see the [Build](#build) section.

## CLI

```sh
open -a "Deep Sleep" --args --hold idle-system,display
open -a "Deep Sleep" --args --release
open -a "Deep Sleep" --args --status
```

| Flag | Purpose |
| --- | --- |
| `--hold <kinds>` | Comma-separated: `idle-system` / `display` / `system` / `disk-idle` (aliases: `idle`, `screen`, `lid`, `all`) |
| `--release` | Release all holds |
| `--status` | Print current state with `powerWatcher=`, `audits=`, and other diagnostic fields |
| `--wait <seconds>` | Used with `--status` to verify reconciliation frequency |
| `--enable-full-control` | One-shot admin auth to install the privileged helper |
| `--disable-full-control` | Uninstall the privileged helper and restore system state |
| `--window-self-test` | Self-test the window display and Dock icon policy (close → hide Dock → reopen → restore) |
| `--blockers` | List all processes currently blocking sleep |
| `--changes` | List detected `pmset` changes (self vs. external) |
| `--rivals` | List other apps that may modify power settings |
| `--helper-version` | Show privileged helper version state |
| `--helper-update` | Manually check and update the helper |
| `--update-check` | Check for app updates immediately |
| `--update-script` | Print the updater script (does not execute) |
| `--quick-quit` | Trigger Quick Quit immediately |
| `--dry-run` | Used with `--quick-quit`: list targets but do not kill |
| `--automation` | Print Siri phrases and `deepsleep://` commands |
| `--hotkey-status` | Print the Quick Quit hotkey registration status (for "the key does nothing" issues) |
| `--autostart` | Mark this launch as LaunchAgent-driven (no window focus) |
| `--server-mode <0\|1>` | Enable or disable server mode |
| `--nice <pid> <value>` | Set process nice value (system processes are rejected by the helper) |
| `--hosts <sub>` | Hosts editor: `list` / `read` / `write <file>` / `allow [uids=...] [names=...]` |
| `--quarantine <sub>` | Quarantine: `scan <dir>` / `clear <dir>` |

> `--hold` and `--release` act on the instance that was launched. macOS is single-instance — passing args to an already-running instance has no effect. For persistent control, use the URL scheme or automation rules.

### `deepsleep://` URL Scheme

```sh
open "deepsleep://hold?kind=idle-system,display&minutes=60"
open "deepsleep://release"
open "deepsleep://quick-quit?dry-run=1"
```

URLs are always routed to the running instance, so they are the right tool for repeated calls. AppleScript: `open location "deepsleep://release"`. Automator: use the "Open URL" action.

See [`docs/architecture.md`](docs/architecture.md) for the full URL command list.

## Toolbox

Every tool sits on one page. The sidebar has a single **Toolbox** entry; each tool is a card. Click a card to open it, click the pin to keep that card at the top, and **Reset order** puts everything back.

| Card | What it does |
| --- | --- |
| Process priority (`nice`) | View and change the `nice` value of any non-system process. |
| Hosts editor | Read and write `/etc/hosts`, manage who is allowed to change it. |
| Quarantine manager | Scan a directory and clear the `com.apple.quarantine` attribute from its files. |
| AI keep-alive | Send a tiny request to a subscription AI service at set times each day. |
| Image upscaler | Enlarge an image 2–4×: neural super-resolution, Lanczos, bicubic, or nearest neighbour. |
| lsof query | Find which process holds a port or file — by port, PID, or path. |
| Shell config | Edit `.zshrc` and friends, with a backup and a syntax check before saving. |

## AI Keep-Alive

Subscription AI services (Claude, Codex, Gemini, DeepSeek and the like) usually run a rolling usage window that starts from your last request. Leave one idle and the window resets.

AI Keep-Alive sends a tiny request to a service you pick, at fixed times each day, so the window keeps moving.

Pick the times of day you want, and the weekdays it runs on. Times are local, to the minute.

Each task needs:

| Field | What to fill in |
| --- | --- |
| Service address | The base URL, e.g. `https://api.anthropic.com`. A trailing `/v1` is optional. |
| Request format | `OpenAI` (Bearer token, `/v1/chat/completions`) or `Anthropic` (`x-api-key`, `/v1/messages`). |
| Model | Any model the service accepts. **Refresh model list** pulls the names from the service; you can also type one by hand. |
| API Key | Stored in the macOS Keychain. Never written into preferences, never printed in the log. |
| Send times | One or more times of day. Default 09:00 and 14:00. |
| Run days | Which weekdays it runs on. Default Monday to Friday. |
| Request content | The text to send. Default asks the model to reply with `ping`. **Restore default template** puts it back. |

Worth knowing:

- Each request asks for one token of output, so the cost is minimal, but it still lands in that service's usage statistics.
- How the rolling window resets is the service's call. Deep Sleep sends on schedule; whether that keeps the window alive follows the service's own rules.
- Days you did not pick get no request, so those windows reset on their own.
- If Deep Sleep was closed when a time came around, that time is skipped. The next one is a fresh start.
- Keep-alive stops when Deep Sleep quits.

## Privileged Helper & Security

Truly persistent sleep control requires root. Deep Sleep uses a one-shot install + long-lived helper to avoid password prompts on every action.

1. Click **Enable Full Control** in the app — system shows one admin auth (Touch ID on supported Macs).
2. The helper binary is written to `/Library/PrivilegedHelperTools/`, and a launchd LaunchDaemon registers it.
3. Subsequent elevated operations need only local Touch ID / login confirmation; the request goes through a UNIX socket to the helper.

Helper-side protections:

- Socket at `/var/run/com.skyc8266.deepsleep.sock`, owned by the logged-in user, mode `0600`.
- Each connection validates peer uid via `getpeereid()`; non-logged-in users are rejected.
- Writable `pmset` keys are whitelisted; values must be pure numbers.
- Only a fixed set of commands is accepted; no shell strings from external input are executed.
- Must run as root, otherwise exits immediately.

## Build

Requires Xcode 26+ (with macOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen

cd DeepSleep
xcodegen generate                     # generate DeepSleep.xcodeproj from project.yml

xcodebuild -project DeepSleep.xcodeproj -scheme DeepSleep \
           -configuration Release -derivedDataPath build build

open "build/Build/Products/Release/Deep Sleep.app"
```

The build automatically embeds `deepsleep-helper` into `Deep Sleep.app/Contents/Library/PrivilegedHelperTools/`. `project.yml` configures ad-hoc signing, so the binary runs locally without further setup.

## Project Structure

```
DeepSleep/
├── project.yml                     XcodeGen project definition
├── Shared/                         Code shared by both targets
│   ├── HelperProtocol.swift        Command / response / constants
│   ├── UnixSocket.swift            UNIX socket wrapper (length-prefixed framing)
│   ├── PMSetOutput.swift           `pmset -g` parsing (shared by app and helper)
│   ├── Version.swift               Version parsing & comparison
│   ├── ProcessInventory.swift      Process enumeration & process tree (for Quick Quit)
│   ├── ProcessSnapshot.swift       Process stats snapshot (RSS / CPU% / start time)
│   ├── ProcessStats.swift          Shared codec for process snapshots
│   ├── ProcessGuard.swift          Hard-kill protection list and "who to kill" arbitration
│   └── TerminationReport.swift     Hard-kill result structure and codec
├── DeepSleep/                      Main app
│   ├── DeepSleepApp.swift          App entry (main window scene)
│   ├── AppDelegate.swift           Lifecycle + CLI + URL entry
│   ├── Windows/                    MenuBarController, WindowCoordinator
│   ├── Core/                       SleepController, PowerWatcher, UpdateManager, etc.
│   ├── Intents/                    DeepSleepIntents (Siri / Shortcuts / Focus)
│   ├── Privileged/                 HelperClient, HelperInstaller
│   ├── Auth/BiometricAuth.swift    Touch ID wrapper
│   ├── Views/                      SwiftUI views
│   └── Resources/                  Info.plist, install-helper.sh, uninstall-helper.sh
└── DeepSleepHelper/                Privileged helper daemon
    ├── main.swift                  Helper entry
    └── SelfUpdate.swift            Helper self-replacement (highest-permission path)
```

`scripts/` contains: `build-release.sh`, `check-docs.py`, `test-check-docs.py`, `helper-probe.py`, `probe-unknown-command.py`, `make-icon.py`, plus regression / end-to-end tests.

## Documentation

Before changing code, read [`docs/`](docs/README.md). It explains *why things are the way they are* and *what to watch out for when changing them* — neither is obvious from the code alone.

| Document | Content |
| --- | --- |
| [`docs/README.md`](docs/README.md) | Index, five-minute setup, doc-freshness mechanism, hard conventions |
| [`docs/architecture.md`](docs/architecture.md) | Architecture & operation: permission model, three-layer protection, reconciliation scope, two update paths |
| [`docs/maintenance.md`](docs/maintenance.md) | How to make common changes, how to verify, debug tools |
| [`docs/release.md`](docs/release.md) | Release process and checklist |
| [`docs/gotchas.md`](docs/gotchas.md) | Pitfalls already hit — read before simplifying any code |
| [`docs/notes.md`](docs/notes.md) | Dev notes: real-test evidence, un-tested items and why, design decisions |

Documentation/code sync is enforced by a script. After changes:

```sh
python3 scripts/check-docs.py
```

It compares the CLI flag table, protocol command table, URL command table, Siri phrases, protection list, version numbers, and file references.

## License

MIT. See [LICENSE](LICENSE). Copyright © 2026 Skyc8266.