# Contributing to Garlo

Garlo is a personal project with a public repository. Issues and pull requests are welcome; the bar is the same for everyone, including the automated agents that do much of the work here.

## Ground rules

- **Evidence over impressions.** A verdict Garlo shows must rest on a measurement it can print. Rules that "feel right" without a fixture are not merged.
- **Every rule change ships a fixture.** Record a real incident with `garlo record`, anonymise it with `python3 Tools/scrub-fixture.py`, put it under `Tests/GarloCoreTests/Fixtures/`, and assert the verdict. When the incident cannot be reproduced, synthetic frames in `SyntheticRuleTests` will do.
- **Nothing personal in the repository.** No raw recordings, no screenshots with real file names, no volume or drive names from your own Mac. The scrubber exists for this.
- **Copy rules.** Verdicts are one sentence, present tense, subject first. Numbers carry units. Actions are imperative and specific. No em-dashes anywhere, not in code, comments, UI, docs or commit messages.
- **Budget.** Sampling stays under 20 ms per tick, under 1 percent of a core and under 60 MB. Settings shows the live numbers; a change that moves them needs a reason.
- **No dependencies, no Xcode project.** SwiftPM and the Makefile are the whole build.

## Workflow

```sh
swift build
swift test
make app && open Garlo.app
```

1. Branch from `main`.
2. Make the change with its test or fixture.
3. Update the docs that describe it: `docs/RULES.md` for rules, `docs/USER-GUIDE.md` for anything the user sees, `docs/ADVANCED.md` for the CLI, state or release process, the directory `CLAUDE.md` for constraints an agent needs.
4. Open a pull request with a one-paragraph description of the incident or gap it addresses and how the fixture proves the fix.

## Reporting a wrong finding

Press Wrong on the card. Garlo saves the last minute of measurements under `~/Library/Application Support/Garlo/Fixtures/`. Run the scrubber on that file before attaching it to an issue, and say what the right verdict would have been.

## Signing and releases

Builds are signed with a self-signed identity described in `docs/SIGNING.md`; on a machine without it, `make app` signs ad-hoc and everything still works except that the removable-volume privacy prompt returns after each rebuild. Releases are cut by the maintainer with `make release` and an ed25519 key that is not in the repository.
