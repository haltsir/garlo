# docs

Human-facing documentation. `README.md` here is the index. Keep each document for its audience: `USER-GUIDE.md` never mentions a source file; `ADVANCED.md` may; `RULES.md` mirrors the code rule by rule; `DECISIONS.md` records why, newest first; `SIGNING.md` is the maintainer's runbook.

When code changes, the document that describes it changes in the same commit:

- a rule or threshold: `RULES.md`
- anything the user sees or a new setting: `USER-GUIDE.md`
- a CLI command, state file, environment variable or release step: `ADVANCED.md`
- a decision that overrides an earlier one: a dated entry in `DECISIONS.md`, and remove the old one from Open if it was there

Style: plain prose, short sentences, tables for reference material, fenced blocks for commands, no em-dashes. Numbers carry units. Screenshots, when added, go under `docs/screenshots/` and must not show real file names; the README already links `docs/screenshots/popover-read-bound.png`, which does not exist yet.
