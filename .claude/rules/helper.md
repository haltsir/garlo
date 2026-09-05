---
paths:
  - "Sources/GarloHelper/**"
  - "Sources/GarloApp/HelperClient.swift"
  - "Sources/GarloCore/Helper.swift"
  - "Resources/com.strahil.garlo.helper.plist"
---

# The privileged helper

- Exactly the four XPC calls that exist (version, snapshot, fileIO, smart). A new capability is a product decision; ask before adding one.
- The protocol in `Sources/GarloHelper/main.swift` and `Sources/GarloApp/HelperClient.swift` must match; bump `HelperIdentity.protocolVersion` on change.
- Never widen `HelperIdentity.clientRequirement`. Validate every argument that reaches a shell (`smart` takes a BSD name matching `^disk[0-9]+$`, nothing else).
- The daemon sends only other users' and root processes with I/O, and exits after two minutes idle.
- After a rebuild the running daemon must be cycled in Settings (Remove, wait a few seconds, Install) or it dies with "Launch Constraint Violation". Say so in the summary whenever the helper binary changed.
- Root-only work goes in `HelperWork` so it can be unit-tested without root.
