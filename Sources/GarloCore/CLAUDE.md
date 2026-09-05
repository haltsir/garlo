# GarloCore

The library every front end runs. No AppKit, SwiftUI or UserNotifications imports, ever: that is what makes every rule replayable from a JSON fixture in `swift test`.

## Files

| File | Holds |
| --- | --- |
| `Samples.swift` | The sample structs (`DiskSample`, `ProcessSample`, `OpenFile`, network, Wi-Fi, CPU, memory, system, latency), `Frame`, the topology types (`DiskDevice`, `Volume`, `USBLink`, `USBSpeed`, `Topology`), and the rate types (`DiskRate.between`, `NetworkRate`, `CPURate`). |
| `DiskStatsSampler.swift` | IOBlockStorageDriver `Statistics` counters. Cumulative bytes, ops, total time in ns. The "Latency Time" keys are always 0 and unused. |
| `TopologySampler.swift` | Registry walk every 30 s: disk identity, USB speed, hubs and controller, APFS volume to physical disk, `getfsstat`, `diskutil apfs defragment status` (cached an hour, rotational only). |
| `ProcessSampler.swift` | `proc_pid_rusage` V4 and `proc_pidinfo` fd listings. Root processes answer EPERM and are skipped; the helper fills them in. |
| `SystemSamplers.swift` | M2: `NetworkSampler`, `WiFiSampler`, `CPUSampler`, `MemorySampler`, `SystemSampler`, `NetProcessSampler` (`nettop`), `LatencyProbe`. |
| `FileLayout.swift` | `F_LOG2PHYS_EXT` extent walk; pieces, median piece, span, pieces per 8 MB. |
| `Window.swift` | The 60 s ring, every query rules ask (rates, summaries, attributions, drain, grouped CPU, per-process net), `DiskSummary`, `FootprintHistory`, and `Window.cache`. |
| `Findings.swift` | `Candidate`, `Finding`, `Action`, `Contributor`, severities, and `FindingTracker` (the lifecycle). |
| `Rules.swift` | `Rule` protocol, `StorageThresholds`, the storage rules. `TransferRule` is the composite card. |
| `SystemRules.swift` | `SystemThresholds`, the network, CPU, memory and thermal rules, `SystemRules.all` and `AllRules.all` (evaluation order). |
| `Baselines.swift` | `BaselineLearner.relearn` (hourly, median service time over a week's busy minutes, ten needed) and `DeviceSlowRule`. |
| `RollupStore.swift` | SQLite `history.sqlite`: one row per resource per minute, baselines, reset markers, pruning. `RollupAccumulator` folds ticks into minutes. |
| `Engine.swift` | The main-actor loop: sample on a detached task, append, evaluate, track, roll up, throttle expensive work, merge the helper snapshot. Also `Recording` (fixture format, `compacted()`, `replay()`). |
| `Helper.swift` | Types shared with the daemon, `PrivilegedSource`, `HelperIdentity`, and `HelperWork` (the root-only samplers, callable from tests). |
| `ThroughputTest.swift` | The opt-in five-second download. |
| `Units.swift` | Every number the user sees is formatted here: rates, bytes, ms, percent, clock, duration. |

## Rules of the house

- A rule is a pure function `(Window) -> [Candidate]`. No state, no clocks other than frame timestamps, no I/O. If a rule needs a new fact, add a query to `Window` and a field to `Frame`.
- New `Frame` fields are optional or defaulted so the fixtures in `Tests/GarloCoreTests/Fixtures/` still decode. The Swift encoder writes `[Int32: X]` as a flat `[key, value, ...]` array; the scrubber knows.
- Thresholds go in `StorageThresholds` or `SystemThresholds`, never inline. Each is a fact a fixture test can cite.
- `explainsDisks` plus order in `AllRules.all` is the only mechanism for "one incident, one card". `Engine` seeds `Window.explainedDisks` from open findings before evaluating.
- `Window.cache` memoises per-tick tables; use `w.cache.get("key") { ... }` for anything several rules ask for.
- Rates are derived by `DiskRate.between`: depth from total-time delta (Little's law), busy capped at one, service time per op with queueing removed. Do not judge a disk by raw latency.
- Everything here must stay `Sendable`; the engine samples on a detached task and hands frames to the main actor.
- Formatting only through `Units`; never `String(format:)` a user-facing number elsewhere unless a test pins it.
