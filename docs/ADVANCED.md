# Garlo advanced guide

For people who build Garlo from source, run the command-line front end, record incidents, run the helper, or cut releases. The [user guide](USER-GUIDE.md) explains what the app shows; this guide explains how it works and how to drive it.

## Build from source

SwiftPM only. No Xcode project, no third-party dependencies, Swift 6 language mode. macOS 15 SDK.

```sh
swift build                 # debug build of every target, fastest compile check
swift test                  # GarloCore tests: tracker lifecycle, fixtures, synthetic frames
make app                    # release build packaged as Garlo.app
make run                    # make app, then open it
make icon                   # regenerate Resources/AppIcon.icns from Tools/make-icon.swift
make cli                    # release build, prints the path of the garlo binary
make clean
```

`make app` signs the bundle with the self-signed identity "Garlo Signing" if it is in the login keychain, and ad-hoc otherwise. The identity exists so the removable-volume privacy grant survives rebuilds; see [SIGNING.md](SIGNING.md) for how it was created and how to recreate it. Override with `make app SIGN_IDENTITY=-`.

The dev loop for the running app:

```sh
make app && pkill -f Garlo.app/Contents/MacOS/Garlo; sleep 1; open Garlo.app
```

Targets in `Package.swift`:

| Target | Product | What it is |
| --- | --- | --- |
| `GarloCore` | library | Samplers, window, rules, findings, engine, rollups, fixtures. No UI imports. |
| `GarloApp` | executable, copied into the bundle as `Garlo` | SwiftUI `MenuBarExtra` app, store, views, notifier, updater, helper client. |
| `garlo` | executable | Command-line front end over the core. |
| `GarloHelper` | executable, bundled at `Contents/MacOS/GarloHelper` | The privileged daemon. |
| `GarloCoreTests` | tests | Swift Testing suites plus `Fixtures/`. |

The target `garlo` and the directory `Sources/GarloCLI` differ on purpose: the filesystem is case-insensitive and `Garlo`/`garlo` collided once.

## The command line

The debug binary is at `.build/debug/garlo` after `swift build`. It runs the same engine as the app, without persistence, notifications or the helper.

| Command | What it prints |
| --- | --- |
| `garlo sample [seconds]` | Once per second: every busy disk with read and write rate, ops per second, service time per op and queue depth, plus the sampling cost. Findings print as they open, confirm and resolve. Runs until stopped when no count is given. |
| `garlo system [seconds]` | The M2 view: CPU per core type and speed limit, memory pressure, compressor and swap, thermal state, GPU, network rates and utilisation, Wi-Fi rate and signal, latency probes, top CPU and network processes. Default five samples. |
| `garlo topology` | Every disk with size, interconnect, media kind, USB link speed and what it could support, hubs and controller; every volume with mount point, use, free space, filesystem and APFS defragmentation status. Volumes without a physical disk are listed with a question mark. |
| `garlo layout <file>` | The extent walk of one file: size, pieces, median piece, physical span, pieces per 8 MB, and whether it counts as fragmented. |
| `garlo candidates [ticks]` | What every rule proposes on each tick, before the lifecycle, with the disks each candidate explains and any volume draining free space. The tool for "why did (or did not) that card appear". |
| `garlo probe [host]` | The default route, three gateway round trips, three round trips to the host (default one.one.one.one), and three DNS timings. |
| `garlo record <out.json> [seconds]` | `sample` that also saves every frame, the topology and probed layouts as a fixture. Default 60 seconds. |
| `garlo replay <fixture.json>` | Runs a fixture through the rules and prints the events and the findings open at the end. |

Reading a `sample` line: `Archive r 28 MB/s w 0 B/s 210 ops 4.1 ms/op depth 0.9`. Service time per op is latency with queueing taken out; depth is the average number of requests in flight over the second. A depth in the hundreds on a USB RAID enclosure is real: requests wait hundreds of milliseconds in a queue and the disk itself is healthy. Judging a disk by raw latency blames a healthy disk under a burst.

## Where the app keeps things

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Garlo/state.json` | Settings, resolved findings, update bookkeeping. Pretty-printed JSON, sorted keys. |
| `~/Library/Application Support/Garlo/history.sqlite` | One row per resource per minute (`disk:<bsd>`, `net:<iface>`, `cpu`, `memory`, `thermal`) and the learned baselines. |
| `~/Library/Application Support/Garlo/Fixtures/` | Recordings saved when you press Wrong on a card, named by timestamp and rule. |
| `~/Library/Application Support/Vestitel/Events/` | Where red alerts are dropped for Vestitel, only if the folder exists. |
| `~/.config/garlo/release-key` | The ed25519 private key, on the release machine only. |

Environment variables:

| Variable | Effect |
| --- | --- |
| `GARLO_STATE_DIR` | Use another state directory. A second instance for testing: `GARLO_STATE_DIR=/tmp/g Garlo.app/Contents/MacOS/Garlo`. Such an instance never self-updates unless the next variable is set. |
| `GARLO_UPDATE_URL` | A stand-in for the GitHub releases API (same JSON shape as `releases/latest`) so the updater can be exercised without publishing. |

## How a finding comes to be

Samplers run once a second on a detached task and must finish well under 20 ms. Every sample becomes a `Frame`. The `Window` keeps the last 60 frames and answers questions rules ask: rates per disk, busy and idle ticks, attributions (which process has which files open on which volume), free-space drain, CPU per process grouped by name, network per process, latency probes. Rules are pure functions from a window to zero or more candidates. The `FindingTracker` turns candidates into findings with a lifecycle:

- A key (rule plus subject) opens as suspected after 10 consecutive ticks present.
- It confirms the first tick a candidate carries `confirmedBy`, and never drops back.
- It resolves after 30 consecutive ticks absent.
- A fresh candidate for an open key merges: text and numbers update, confidence only ratchets up.

Composite rules run first. `TransferRule` claims the disks a copy involves; `IOPSSaturationRule` and `ContentionRule` stay silent about disks that are already explained, so one incident is one card.

Rates from the IOKit counters: total-time delta over the interval is the average queue depth (Little's law); busy is that depth capped at one; service time per op is latency divided by depth. All thresholds live in two enums, `StorageThresholds` in `Rules.swift` and `SystemThresholds` in `SystemRules.swift`, so a test can say exactly which number a verdict rests on. The [rule catalogue](RULES.md) lists every rule with its verdicts, thresholds, confirming signal and tests.

## Recording and replaying incidents

Every rule change ships with a fixture. When something slow happens:

```sh
swift build
.build/debug/garlo record incident.json 90
```

Then replay it and check what the rules say:

```sh
.build/debug/garlo replay incident.json
```

A `cp` of a torrent-downloaded file from an external disk to the boot disk reproduces the read-bound copy in under a minute; ten `yes > /dev/null &` loops reproduce CPU saturation.

**Before a fixture is committed** it must be anonymised. A recording carries every open-file path and process name on the machine.

```sh
python3 Tools/scrub-fixture.py incident.json
```

Paths become `file-N` placeholders under their volume root (`/Volumes/<name>/file-3.mkv`, `/Users/user/file-7`), process names outside a short allowlist become `app-N`, and bundle identifiers are dropped for those. A gitignored `Tools/scrub-renames.json` (`{"renames": [[old, new], ...], "keep": [...], "keepBundles": [...]}`) maps the machine's own volume and drive names to generic ones in every string of the file. The script is deterministic per run, so one file keeps one name across frames and the layouts map. Never publish a raw recording.

Fixtures live under `Tests/GarloCoreTests/Fixtures/` and are replayed by `FixtureTests`. Tests assert the verdict, the subject and the confirmation, not the numbers.

## The privileged helper

`GarloHelper` is a launchd daemon inside the bundle, described by `Contents/Library/LaunchDaemons/com.strahil.garlo.helper.plist`, registered with `SMAppService.daemon` and approved once in System Settings > Login Items. A Team ID is not needed: the self-signed identity is enough, and macOS merely ignores the bundle grouping.

It listens on the Mach service `com.strahil.garlo.helper` and accepts XPC connections only from a client matching the requirement in `HelperIdentity.clientRequirement`: bundle identifier `com.strahil.garlo` and a leaf certificate with common name "Garlo Signing". It exposes four calls: protocol version, a snapshot of the processes the client cannot inspect (other users' and root's, only those that have moved data, with open files for those moving now), an fs_usage-based per-file I/O sample over a few seconds, and SMART status through `diskutil` for a BSD disk name. It exits after two minutes without a request.

The engine asks for a snapshot every 10 seconds while a disk is busy or a storage finding is open, and merges it into the next frame, so root processes get open files like any other and the transfer rule finds Finder's copy helper. The app's own view of a process wins over the helper's.

**Launch constraints.** launchd pins a constraint to the exact build that was registered. After any rebuild the running daemon is killed at launch ("Launch Constraint Violation") until it is re-registered. In Settings press Remove, wait a few seconds, then Install. Registering while launchd is still tearing the old job down reuses its record and the stale constraint; that was the 0.2.0 bug. After a self-update the app does this cycle itself, polling until the service status leaves `.enabled` and waiting three more seconds. The Login Items approval survives the cycle.

To watch the daemon: open Console.app and filter for `GarloHelper`, or `log stream --predicate 'process == "GarloHelper" OR eventMessage CONTAINS "garlo.helper"'`.

## The History store and baselines

`RollupStore` writes `history.sqlite` next to `state.json`. `RollupAccumulator` folds the per-second rates into one row per resource per minute; rows older than the retention setting are pruned during housekeeping. `BaselineLearner.relearn` runs hourly: for each disk, the median service time over the last week's busy minutes (at least 20 ops per second and 30 percent busy), needing ten such minutes. A reset writes a marker row with `busySeconds == -1` so learning restarts from that moment. `DeviceSlowRule` compares queue-adjusted service time against three times the baseline and needs it sustained over its window.

## Updates and releases

The updater is in-house (ported from Vestitel), not Sparkle. Once a day at 12:30, ridden on the 30-second housekeeping task, the app fetches `releases/latest` from GitHub. A newer version is downloaded with its detached `.zip.sig`, verified against the ed25519 public key embedded in `Updater.swift`, unpacked with `ditto`, checked for a matching plist version, and staged. A detached shell script swaps the bundle once the app exits and relaunches it. The swap waits for the popover to close. Unsigned or badly signed releases are refused.

Cutting a release:

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Write `release-notes.md` (gitignored; it becomes the release body). One short paragraph on what changed, then a bullet list, then the requirements line.
3. Commit, then tag: `git tag -a v<version> -m "Garlo <version>"` and push the tag.
4. `make release`: builds, packages, zips with `ditto`, signs with `Tools/sign-release.swift` using `~/.config/garlo/release-key`, and creates the GitHub release with both assets through `gh`.

Both assets must be uploaded; the app refuses a release without a valid signature.

## Vestitel events

A red alert is written as JSON to `~/Library/Application Support/Vestitel/Events/garlo-<uuid>.json`:

```json
{
  "source": "Garlo",
  "title": "<verdict>",
  "summary": "<cause> Try: <first action>.",
  "tag": "stalled",
  "symbol": "externaldrive",
  "id": "garlo-<uuid>",
  "published": "2026-09-05T18:03:11Z"
}
```

`symbol` is `wifi` for network findings and `externaldrive` for the rest. With Redact file paths on, every path that appears in an action is replaced by its last component in the summary.

## Sampling budget

Under 20 ms per tick, under 1 percent of a core, under 60 MB. The Settings window shows the live numbers, measured by Garlo's own samplers and judged by the same rules. Expensive things are throttled: topology every 30 s, defragmentation status cached an hour, open-file listings every 5 s per busy process, `nettop` every 5 s while the link is busy and never awaited inside the tick, latency probes on their own cadence, helper snapshots every 10 s while busy. `Window.cache` memoises the per-tick rate tables so several rules asking the same question pay once.

## Troubleshooting

- **"Launch Constraint Violation" in the log, helper "not answering yet".** Cycle Remove, wait, Install.
- **The updater says "not available".** It is a test instance (`GARLO_STATE_DIR` set) without `GARLO_UPDATE_URL`, or the binary runs outside a bundle.
- **No notifications from the bare binary.** Notifications need a bundle; run `Garlo.app`.
- **A copy is not detected although two disks are busy.** Two busy disks are not a transfer. Garlo needs a process with open files on both volumes or the destination's free space draining at the write rate. Run `garlo candidates` to see what the rule proposes and what drains.
- **A card names the wrong source file.** The source is only ever the copier's own largest open file, or one you picked. If the copier is root and the helper is off, use Pick the file.
- **Fragmentation is never reported for small files.** Files under 64 MB are not probed.
- **The removable-volume prompt keeps coming back.** The build is ad-hoc signed. Create the "Garlo Signing" identity per SIGNING.md.
