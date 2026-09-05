# Tools

Scripts that are run by hand or by the Makefile. None ship in the bundle.

| Script | Run as | Does |
| --- | --- | --- |
| `scrub-fixture.py` | `python3 Tools/scrub-fixture.py <fixture.json>` | Anonymises a recording in place: paths become `file-N` under their volume root, process names outside the allowlist become `app-N`, bundle ids are dropped for those, the note is replaced. Reads the gitignored `scrub-renames.json` for the machine's own volume and drive names. Mandatory before a fixture is committed. |
| `scrub-renames.json` | read by the scrubber | `{"renames": [[old, new], ...], "keep": [...], "keepBundles": [...]}`. Gitignored because it contains the real names. Recreate it on a new machine before scrubbing. |
| `make-icon.swift` | `make icon` | Draws the app icon into an iconset that `iconutil` turns into `Resources/AppIcon.icns`. Keep the glyph in step with `Sources/GarloApp/MenuBarIcon.swift`. |
| `sign-release.swift` | `make release` | Signs the release zip with the ed25519 key at `~/.config/garlo/release-key` and writes `<zip>.sig`. The public half is embedded in `Updater.swift`. |

Rules of the house:

- Never add a step that uploads or publishes without `make release` asking for it explicitly.
- The scrubber must stay deterministic within a run so one path keeps one placeholder across frames and the layouts map.
- The Swift encoder writes `[Int32: [OpenFile]]` as a flat array; the scrubber handles both shapes. Keep that if the fixture format changes.
