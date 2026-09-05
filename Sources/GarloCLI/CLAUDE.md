# GarloCLI

The `garlo` executable: one file, a thin front end over `Engine`. The directory is `GarloCLI` and the target is `garlo` on purpose; `Garlo`/`garlo` collided on the case-insensitive filesystem.

Commands: `sample`, `system`, `candidates`, `probe`, `topology`, `layout`, `record`, `replay`. `candidates` and `probe` are debugging aids and are left out of the usage line; keep them working anyway, they are the fastest way to answer "why did that card (not) appear".

Rules of the house:

- No persistence, notifications or helper here. If a command needs the rollup store or the helper, it is an app feature, not a CLI one.
- Print through `Units` so the CLI and the popover show the same numbers.
- `record` must keep writing a `Recording` that `replay` and `FixtureTests` can load; changing the fixture format means re-checking every file under `Tests/GarloCoreTests/Fixtures/`.
- The debug binary is `.build/debug/garlo`; `make cli` prints the release one. Document a new command in `docs/ADVANCED.md` and the root `CLAUDE.md` command list.
