# Garlo for AI agents

Read this before touching the code. It is the map; `CLAUDE.md` in the root and in each source directory carries the constraints; `docs/` explains the product and the rules.

## Read in this order

1. `CLAUDE.md` (root): what the app is, the pipeline, the invariants that were learned the hard way.
2. The `CLAUDE.md` of the directory you are changing (`Sources/GarloCore`, `Sources/GarloApp`, `Sources/GarloCLI`, `Sources/GarloHelper`, `Tests/GarloCoreTests`, `Tools`, `design`, `docs`).
3. `.claude/rules/`: short rules on copy, fixtures, Swift, signing and releases, the helper, and the budget. Some are scoped to paths.
4. `docs/RULES.md` when a finding is involved, `docs/ADVANCED.md` for the CLI, state files and release steps, `docs/DECISIONS.md` before proposing to change a design decision.

## Build, test, run

```sh
swift build                              # compile check, all targets
swift test                               # 23 tests in 9 suites; must stay green
make app                                 # Garlo.app, signed with "Garlo Signing" when present
make app && pkill -f Garlo.app/Contents/MacOS/Garlo; sleep 1; open Garlo.app
.build/debug/garlo candidates 20         # what every rule proposes per tick
.build/debug/garlo replay Tests/GarloCoreTests/Fixtures/copy-archive-to-boot.json
```

A second app instance for experiments: `GARLO_STATE_DIR=<dir> Garlo.app/Contents/MacOS/Garlo`. Popover screenshots: see the root `CLAUDE.md`.

## The shape of the code

```
Samplers (1 Hz) -> Frame -> Window (60 s ring) -> Rules -> Candidates
    -> FindingTracker (10 s open, confirm on signal, 30 s resolve) -> Engine -> AppStore -> Views
```

- `Sources/GarloCore` is a library with no UI imports. Everything a rule needs is on `Window`; rules are pure and testable against recorded frames.
- `Sources/GarloApp` owns settings, persistence, notifications, Vestitel delivery, the updater and the helper client. Views read `AppStore`.
- `Sources/GarloCLI` is a thin front end over the same `Engine`.
- `Sources/GarloHelper` is the root daemon. It shares types with the core through `Helper.swift` and does its work in `HelperWork` so tests can call it.

## Invariants (do not break)

- **Verdicts are evidence-backed sentences.** One sentence, present tense, subject first; numbers carry units; actions are imperative and say their effect. No em-dashes anywhere, including comments and commit messages.
- **Every rule change gets a fixture.** A real recording (`garlo record`, then `python3 Tools/scrub-fixture.py`) or synthetic frames in `SyntheticRuleTests`. Assert verdict, subject and confirmation, never numbers.
- **Never commit a raw recording** or a screenshot with real file names. Fixtures carry every open path and process name on the machine.
- **Thresholds live in the `Thresholds` enums**, not inline.
- **Candidate keys are stable across ticks** (rule id plus subject). A subject that changes wording tick to tick makes a finding flicker.
- **`confirmedBy` is an independent signal**, never the same measurement the threshold rests on. Until then, `pending` says what is awaited.
- **Composite before standalone.** A rule that explains a disk lists it in `explainsDisks` and runs earlier in `AllRules.all`.
- **Two busy disks are not a transfer.** See the transfer rule in `docs/RULES.md` before touching `TransferRule`.
- **Judge disks by queue-adjusted service time**, never raw latency.
- **Budget**: under 20 ms per tick, under 1 percent of a core, under 60 MB. Anything slow (shelling out, fd listings, registry walks) is throttled and never awaited inside the tick.
- **Settings decode tolerantly.** Every new field gets a default in `Settings.init(from:)`.
- **Sign only with "Garlo Signing"** or ad-hoc. Never another project's identity.
- **Paths on the boot volume never carry `/System/Volumes/Data`.** `Topology.volume(containing:)` handles it; do not special-case elsewhere.
- **Do not add dependencies or an Xcode project.**

## Recipes

**Change a threshold.** Edit the enum, run `swift test`, replay the fixtures that touch the rule (`garlo replay`), and check `docs/RULES.md` still describes it.

**Add a rule.** Create a `struct XRule: Rule` next to its domain (`Rules.swift` for storage, `SystemRules.swift` for the rest), add thresholds to the enum, append it to `StorageRules.all` or `SystemRules.all` in the right position, write the fixture or synthetic test, add a section to `docs/RULES.md`, and mention the domain's notification switch if it is a new domain.

**Add a sampler field.** Extend the sample struct in `Samples.swift` with an optional or defaulted field (fixtures recorded before the field must still decode), fill it in the sampler, expose a query on `Window`, and keep the per-tick cost inside the budget. Old fixtures in `Tests/GarloCoreTests/Fixtures/` are the regression check.

**Add a setting.** Field with default in `Settings`, a line in `init(from:)`, a row in `SettingsView`, and, if it changes what leaves the Mac, a sentence in `docs/USER-GUIDE.md` under Privacy.

**Change UI copy.** Follow the copy rules. Keep `Tools/make-icon.swift` and `MenuBarIcon.swift` visually in sync if the glyph changes. Update the design artboards in `design/` when a screen changes materially.

**Touch the helper.** Read `Sources/GarloHelper/CLAUDE.md`. Keep the protocol identical in `HelperClient.swift` and `GarloHelper/main.swift`; bump `HelperIdentity.protocolVersion` when it changes. After a rebuild, cycle Remove, wait, Install in Settings, or the daemon dies with a launch constraint violation.

**Cut a release.** Bump both version keys in `Resources/Info.plist`, write `release-notes.md`, commit, tag `v<version>`, `make release`. The private key is at `~/.config/garlo/release-key` and is never in the repo.

## Before you report done

- `swift build` and `swift test` pass; paste failures verbatim if not.
- A rule change has a fixture and a `docs/RULES.md` entry.
- Nothing personal is in the diff: run the scrubber on fixtures, grep for volume names and home paths.
- No em-dash anywhere in the diff: `git diff | grep -n $'\xe2\x80\x94'` returns nothing.
- Docs that describe what you changed (`README.md`, `docs/`, the directory `CLAUDE.md`) say the new truth.

## What not to do

- Do not enable proactive layout scanning, whole-disk scans, or anything that reads the disks on its own.
- Do not add network calls beyond the latency probe, DNS timing, the opt-in throughput test and the update check.
- Do not send anything other than red alerts to Vestitel.
- Do not commit `release-notes.md`, `Tools/scrub-renames.json`, `Garlo.app` or zips; they are gitignored on purpose.
- Do not run `git push` or `make release` without being asked.
