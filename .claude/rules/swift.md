---
paths:
  - "Sources/**/*.swift"
  - "Tests/**/*.swift"
---

# Swift conventions

- Swift 6 language mode, strict concurrency. Core types are `Sendable`; the engine and stores are `@MainActor`; samplers are stateless enums or structs called from a detached task.
- No third-party packages and no Xcode project. If a framework is needed, link it in `Package.swift`.
- `GarloCore` imports no UI framework. Anything that needs AppKit, SwiftUI, ServiceManagement or UserNotifications belongs in `GarloApp`.
- Rules are pure functions over `Window`. New facts go into `Frame` (optional or defaulted so old fixtures decode) and are exposed as `Window` queries.
- Expensive work (shelling out, fd listings, registry walks, XPC) is throttled and never awaited inside the tick. Budget: under 20 ms per tick, under 1 percent of a core, under 60 MB.
- Every `Settings` field has a default in `init(from:)`.
- Comments say why, not what, and follow the copy rules (no em-dashes).
- A non-Swift file inside a target directory (such as a `CLAUDE.md`) needs an `exclude:` entry for that target in `Package.swift`, or SwiftPM warns on every build.
