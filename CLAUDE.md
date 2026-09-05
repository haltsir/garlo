# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

Garlo (Гърло, "throat", as in a bottleneck) is a menu-bar-only macOS app that finds what is holding the Mac back, names the cause with evidence, and remembers it. The product requirements live in the PRD artifact (Garlo PRD) and the screens in the design canvas (Garlo Screens); both are Claude artifacts owned by Strahil. SwiftPM only, no Xcode project, no third-party dependencies. macOS 15 and later, Apple silicon.

## Commands

```sh
swift build            # debug build, fastest compile check
swift test             # GarloCore tests: tracker lifecycle and fixture replays
make app               # release build + package Garlo.app (ad-hoc signed)
make run               # make app + open Garlo.app
make icon              # regenerate Resources/AppIcon.icns from Tools/make-icon.swift
.build/debug/garlo sample [s]           # live disk rates and findings, once per second
.build/debug/garlo topology             # disks, USB links, volumes, defrag status
.build/debug/garlo layout <file>        # extent walk: pieces, median piece, span
.build/debug/garlo record <out.json> [s]  # capture a fixture from a live incident
.build/debug/garlo replay <fixture.json>  # run a fixture through the rules
```

Dev loop for the running app:

```sh
make app && pkill -f Garlo.app/Contents/MacOS/Garlo; sleep 1; open Garlo.app
```

App state lives in `~/Library/Application Support/Garlo/state.json` (settings + resolved findings). A second instance for tests: `GARLO_STATE_DIR=<dir> Garlo.app/Contents/MacOS/Garlo`. Fixtures the user marks "Wrong" land in `<state dir>/Fixtures/`.

Popover screenshots: `osascript -e 'tell application "System Events" to tell process "Garlo" to click menu bar item 1 of menu bar 2'` toggles it (check `count of windows` first), then `get {position, size} of window 1` and `screencapture -x -R "x,y,w,h"`.

## Layout

- `Sources/GarloCore` (library, no UI imports): samplers, window, rules, findings, engine, fixtures.
- `Sources/GarloApp` (target `GarloApp`, copied into the bundle as `Garlo`): SwiftUI `MenuBarExtra` app, AppStore, views.
- `Sources/GarloCLI` (target `garlo`): command-line front end over the core.
- `Tests/GarloCoreTests` with `Fixtures/` (recorded incidents, replayed by `FixtureTests`).
- `design/`: the `.dc.html` artboards and `canvas.json` behind the design canvas; re-seed and republish from here.

Target and directory names differ in more than case on purpose: the filesystem is case-insensitive, and `Garlo`/`garlo` collided once.

## Architecture

Samplers (1 Hz) -> `Window` (60 s ring at full resolution) -> rules (pure functions over the window) -> `FindingTracker` (lifecycle) -> `Engine` (observable, main actor) -> UI, notifications, Vestitel.

- **Samplers** are enums/structs with no state: `DiskStatsSampler` reads IOBlockStorageDriver `Statistics` (cumulative bytes, ops, total time in ns; "Latency Time" keys are always 0 and unused). `TopologySampler` (every 30 s) walks the registry for disk identity, USB speed/hubs/controller (Device Speed 2 = 480 Mb/s, 3 = 5 Gb/s), maps APFS volumes to physical disks by walking parents to the non-synthesized whole IOMedia, reads volumes with `getfsstat`, and shells out to `diskutil apfs defragment <vol> status` (cached an hour, rotational volumes only). `ProcessSampler` uses `proc_pid_rusage` V4 (own-user processes; root ones answer EPERM and are skipped) and `proc_pidinfo` fd listings for processes doing >= 1 MB/s, refreshed every 5 s per pid. `FileLayout.probe` walks `F_LOG2PHYS_EXT`.
- **Rates** (`DiskRate.between`): total-time delta over the interval is the average queue depth (Little's law); `busy = min(1, depth)`; `serviceMsPerOp = latency / max(1, depth)`. Depths in the hundreds are real on the USB RAID enclosures: requests queue for hundreds of ms. Judging a disk by raw latency blames a healthy disk under a burst; that was the wrong turn in the Troy case.
- **Rules** live in `Rules.swift` with thresholds in `StorageThresholds`. `TransferRule` is the composite card: it detects src->dst, decides read-bound vs write-bound from busy/idle tick counts, confirms by chunk cadence (idle side moves in bursts) or by queueing (busy side's latency >= 50 ms and >= 10x the other side), and absorbs fragmentation, saturation and contention on the involved disks. The standalone `IOPSSaturationRule` and `ContentionRule` skip disks a transfer already explains (`TransferRule.involvedDisks`). `LinkCeilingRule` and `VolumeFullRule` are independent.
- **Lifecycle** (`FindingTracker`): a key opens as suspected after 10 consecutive ticks, confirms the first tick a candidate carries `confirmedBy` (never drops back), resolves after 30 ticks absent. Same key merges. Only confirmed slow/stalled findings notify.
- **Paths on the boot volume** (`/Users`, `/private`) never carry the `/System/Volumes/Data` prefix; `Topology.volume(containing:)` falls back to the Data volume for any path not under `/Volumes/`. Without this the copier's destination file is missed and the wrong source file gets blamed.
- **bcdUSB** only says the spec version; `USBLink.capableSpeed` is a floor (>= 0x0300 means at least 5 Gb/s), so "linked below capability" fires only for a USB 3 device at 480 Mb/s or lower.
- **M2 samplers** live in `SystemSamplers.swift`: `NetworkSampler` (sysctl `NET_RT_IFLIST2`; virtual interfaces filtered by name; the driver's `ifi_baudrate` is stale for Wi-Fi, so `NetworkRate.withLinkRate(wifi:)` substitutes the CoreWLAN transmit rate), `WiFiSampler` (CoreWLAN), `CPUSampler` (`host_processor_info`; efficiency cores are the first `hw.perflevel1.logicalcpu` entries; speed limit from `IOPMCopyCPUPowerStatus`), `MemorySampler` (`host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level`), `SystemSampler` (thermal state, Low Power Mode, power sources, `IOAccelerator` utilisation), `NetProcessSampler` (shells out to `nettop -P -x -L 1`, cumulative bytes, run every 5 s while the link is busy, never awaited inside the tick), `LatencyProbe` (non-blocking TCP connect timing; a refused connection still measures the round trip; DNS timed over a rotating name list). Rules for these are in `SystemRules.swift` with `SystemThresholds`; same-named processes are merged by `Window.groupedCPURates` so ten `yes` loops read as one contributor. The frontmost app's pid comes from the app via `Engine.foregroundPID`.
- **Transfer correlation**: two busy disks are not a transfer. `TransferRule` needs a process with open files on both volumes, or the destination volume's free space draining at the write rate (`Frame.volumeFree`, sampled every tick with `getfsstat`). Without either, Torrent seeding plus background boot-disk writes produced a false "Copy is read-bound"; that is the fixture in `TransferCorrelationTests`. The copied file is only ever the copier's own largest open file or one the user picked (`Engine.pinSource`), never another process's. The drain is judged over the whole minute (APFS reports free space with a lag of seconds), and without a copier the source must read at least half of what the destination writes; among several candidates the closest ratio wins, so Torrent seeding from Archive does not become the source of a ddrescue image landing on Backup (`TransferSourceMatchingTests`). `garlo candidates` prints every rule's proposals per tick for this kind of debugging.
- **M3**: `RollupStore` (SQLite, `history.sqlite` next to `state.json`) keeps one row per resource per minute (`RollupAccumulator` folds the per-second rates; keys `disk:<bsd>`, `net:<iface>`, `cpu`, `memory`, `thermal`) and the learned baselines. `BaselineLearner.relearn` runs hourly: the median service time over the last week's busy minutes (ops >= 20, busy >= 0.3), needing ten such minutes; a reset writes a marker row (`busySeconds == -1`) so learning restarts from that moment. `DeviceSlowRule` compares queue-adjusted service time against three times the baseline. The History window (`HistoryView`) draws lanes from the rollups with findings as bars and a device page with baseline, daily trend and week-over-week sentence.
- **Quiet rules**: `IOPSSaturationRule` stays silent for one process saturating its own disk unless service time is high or a second process waits; `VolumeFullRule` skips read-only mounts and volumes without a physical disk (a read-only NTFS image reported 100 percent full).
- **Updater** (`Updater.swift`, ported from Vestitel): a daily check at 12:30 ridden on the 30 s housekeeping task, `releases/latest` from GitHub, the zip and its `.zip.sig` verified against the embedded ed25519 public key (private half only in `~/.config/garlo/release-key`), unpacked with `ditto`, plist version checked, staged; a detached shell script swaps the bundle once the app exits and relaunches it. The swap waits for the popover to close (`popoverOpen` didSet); Settings offers Check Now and Install Now. Unsigned or badly signed releases are refused. `make release` builds, zips, signs and publishes; write `release-notes.md` first and tag `v<version>`. Test instances (`GARLO_STATE_DIR`) update only with `GARLO_UPDATE_URL` pointing at a stand-in releases JSON.
- **M4, the privileged helper** (`Sources/GarloHelper`, `Sources/GarloApp/HelperClient.swift`, `Sources/GarloCore/Helper.swift`): a daemon inside the bundle (`Contents/MacOS/GarloHelper`, plist in `Contents/Library/LaunchDaemons`), registered with `SMAppService.daemon` and approved once in System Settings > Login Items. The self-signed identity is enough; macOS only ignores the bundle grouping without a Team ID. The daemon accepts XPC only from a client matching `HelperIdentity.clientRequirement` (bundle id plus the Garlo Signing leaf), exposes exactly three calls (a snapshot of the processes the client cannot inspect, an fs_usage-based per-file I/O sample, SMART status via diskutil), and exits after two minutes without a request. The engine merges the snapshot into the next frame (`pendingHelperSnapshot`) every 10 s while a disk is busy or a storage finding is open, so root processes get open files like any other and `TransferRule` finds the copier. Launchd pins a launch constraint to the registered build: after any rebuild the running daemon must be cycled through Remove, a few seconds, then Install in Settings, or it is killed at launch ("Launch Constraint Violation"); `AppStore` does that automatically after a self-update (`reregisterAfterUpdate`). Budget: the helper sends only other users' and root processes with I/O, and `Window.cache` memoises the per-tick rate tables; with it running the app stays near 1 percent of a core.
- **App**: `AppStore` (`@Observable`, main actor) owns the engine, settings (tolerant decoding: every new field needs a default in `init(from:)`), persistence, notifications (`Notifier`, bundle only) and Vestitel drop-folder delivery (`Vestitel.post`, writes only if the folder exists). The menu bar icon is drawn in code (`MenuBarIcon`), template at rest, amber/red dot for confirmed slow/stalled; keep `Tools/make-icon.swift` visually in sync.

## Known gaps

- Notarisation would need a paid Developer ID; updates use the in-house ed25519 updater instead of Sparkle. The helper works without it (see M4 below).
- Proactive layout scanning is off by design: it would read the disks that are already the problem. Layouts are probed only for files involved in a detected transfer, or one the user picks.
- Vestitel receives red alerts only (`Finding.isRedAlert`: confirmed stalled, or the device-slow rule). Everything else stays in the popover and History.
- The app is signed with its own self-signed "Garlo Signing" identity when present (`SIGN_IDENTITY` in the Makefile, created 5 September 2026 as documented in `docs/SIGNING.md`), so the removable-volume privacy grant survives rebuilds; ad-hoc signing made macOS ask again after every build. Never sign Garlo with another project's identity.
- Unified log signals (tier 1: flush stalls, USB resets) and Thunderbolt link state are not sampled; the device-slow card says so in its tier hint.
- Real fixtures exist for the read-bound copy and CPU saturation; the other rules are covered by synthetic frames in `SyntheticRuleTests`. Record real ones with `garlo record` when an incident happens.
- A macOS privacy prompt ("access files on a removable volume") appears the first time the layout probe opens a file on a removable disk. Answering it is the user's call.

## Conventions

- No em-dashes anywhere. Copy rules from the PRD: verdicts are one sentence, present tense, subject first; numbers carry units; actions are imperative and specific.
- Every rule change gets a fixture. Record with `garlo record` during a real incident (a `cp` of a torrent-downloaded file from Archive to the boot disk reproduces the read-bound case in under a minute), keep the fixture under `Tests/GarloCoreTests/Fixtures/`, and assert the verdict, not the numbers.
- A recording carries every open-file path and process name on the machine. Always run `python3 Tools/scrub-fixture.py <fixture>` before a fixture is committed: paths become `file-N` placeholders under their volume root, process names outside a short allowlist become `app-N`. Never publish a raw recording.
- Sampling budget: under 20 ms per tick, under 1 percent of a core, under 60 MB. The Settings window shows the live numbers.
