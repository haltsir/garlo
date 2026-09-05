---
paths:
  - "Sources/GarloCore/Rules.swift"
  - "Sources/GarloCore/SystemRules.swift"
  - "Sources/GarloCore/Baselines.swift"
  - "Tests/GarloCoreTests/**"
---

# Fixtures and rule changes

- Every rule change ships a fixture: a real recording from `garlo record` during an incident, or synthetic frames in `SyntheticRuleTests` when it cannot be reproduced.
- Run `python3 Tools/scrub-fixture.py <file>` before a recording is added under `Tests/GarloCoreTests/Fixtures/`. Never commit a raw recording; it carries every open path and process name on the machine.
- Assert the verdict, subject, severity and confirmation. Never assert a rate or a millisecond figure.
- After changing a rule, replay every fixture that touches it with `.build/debug/garlo replay` and read the output.
- Thresholds live in `StorageThresholds`, `SystemThresholds` or the rule's own static constants, never inline.
- Update `docs/RULES.md` in the same change.
