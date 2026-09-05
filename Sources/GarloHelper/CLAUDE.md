# GarloHelper

The privileged daemon (M4). Bundled at `Contents/MacOS/GarloHelper`, described by `Resources/com.strahil.garlo.helper.plist` (copied to `Contents/Library/LaunchDaemons/`), registered by the app with `SMAppService.daemon`, approved once in Login Items, started by launchd on demand as root.

## What it is allowed to do

Exactly four XPC calls, and nothing else: `version`, `snapshot` (processes the client cannot inspect, with open files of those moving now), `fileIO(seconds:)` (an fs_usage-based per-file sample), `smart(diskID:)` (diskutil, BSD name only, validated by regex). The work lives in `HelperWork` in `Sources/GarloCore/Helper.swift` so tests can call it without root.

## Rules of the house

- The protocol in `main.swift` and in `Sources/GarloApp/HelperClient.swift` must match method for method. Bump `HelperIdentity.protocolVersion` on any change.
- Connections are accepted only from a client matching `HelperIdentity.clientRequirement` (bundle id `com.strahil.garlo` and the "Garlo Signing" leaf). Never widen it, never accept a path or shell argument from the client that is not validated.
- Send only what the app cannot see itself: other users' and root processes with I/O. The whole process table every few seconds breaks the 1 percent budget.
- Exit after two minutes idle (`IdleExit`). Nothing runs as root while Garlo has no question.
- launchd pins a launch constraint to the registered build. After every rebuild: Settings > Remove, wait a few seconds, Install. Registering while launchd still tears down the old job reuses the stale record (the 0.2.0 bug); `HelperClient.reregisterAfterUpdate` waits for the status to leave `.enabled` plus three seconds.
- The Login Items approval survives Remove and Install; a fresh identity or bundle id would not.
- Log lines are visible in Console.app filtered for `GarloHelper`.
