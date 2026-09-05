# GarloCoreTests

Swift Testing suites over `GarloCore`. Run with `swift test`. 23 tests in 9 suites as of 0.2.2; all must stay green.

| File | Suites |
| --- | --- |
| `FindingTrackerTests.swift` | Lifecycle: opens after consecutive ticks, a gap resets the count, confirms once and resolves after absence. |
| `FixtureTests.swift` | Real recordings replayed: the read-bound copy from Archive to the boot disk (`FixtureTests`) and ten `yes` loops saturating the performance cores (`CPUFixtureTests`). |
| `SyntheticRuleTests.swift` | Hand-built frames: Wi-Fi, bufferbloat, network hog, swapping, throttling, the idle machine; `TransferCorrelationTests` (seeding plus background writes is not a transfer, the drain sees a Finder copy, a copier process is enough); `TransferSourceMatchingTests`; `HelperParsingTests` (fs_usage lines); `HelperMergeTests`. |
| `BaselineTests.swift` | Rollup round trip and pruning, ten busy minutes and the median, three times slower is a finding, queueing is not. |
| `Fixtures/` | `copy-archive-to-boot.json`, `cpu-saturated.json`. Anonymised recordings, copied as a resource bundle. |

## Rules of the house

- Assert the verdict, the subject, the severity and the confirmation. Never assert a rate or a millisecond figure; those move with thresholds and hardware.
- A fixture goes through `python3 Tools/scrub-fixture.py` before it is added. The volume names in fixtures are Archive, Backup, Scratch and Boot disk; the torrent client is Torrent. Real names never appear.
- A synthetic test builds frames with the helpers at the top of `SyntheticRuleTests.swift` and runs them through an `Engine` with `openAfter` and `resolveAfter` set low; say in the test name what scenario it is.
- When a rule changes, replay every fixture that touches it (`garlo replay`) and read the output, not only the test result.
- Tests that touch the engine are `@MainActor`; the rollup store tests use a temporary directory and clean up.
