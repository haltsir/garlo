# GarloApp

The SwiftUI `MenuBarExtra` app (`LSUIElement`, no Dock icon). Copied into the bundle as `Contents/MacOS/Garlo` by `make app`.

## Files

| File | Holds |
| --- | --- |
| `GarloApp.swift` | `@main`, the `MenuBarExtra` (window style), the History and Settings `Window` scenes, `AppDelegate` (notification categories). |
| `AppStore.swift` | `Settings` (tolerant decoding), `PersistedState`, the `AppStore` (`@Observable`, main actor): engine ownership, the Now rows with hysteresis, notifications, Vestitel delivery, actions, Wrong-fixture capture, persistence, the 30 s housekeeping task. |
| `HelperClient.swift` | `SMAppService.daemon` registration, XPC to the helper, `reregisterAfterUpdate`. Implements `PrivilegedSource`. |
| `Updater.swift` | Daily check, ed25519 verification, staging, the detached swap script, Check Now and Install Now. |
| `Notifier.swift` | `UNUserNotificationCenter`; bundle only, the bare binary skips silently. |
| `MenuBarIcon.swift` | The throat glyph drawn in code, template at rest, amber or red dot. Keep `Tools/make-icon.swift` in sync. |
| `Views/ContentView.swift` | The popover: header, Now, Findings, Notices, Last resolved, footer. |
| `Views/FindingCard.swift` | The card, action chips, the Wrong button, the layout sheet. |
| `Views/HistoryView.swift` | Lanes, bars, the device page with baseline and trend. |
| `Views/SettingsView.swift` | Every setting, the helper controls, overhead, updates. |

## Rules of the house

- Every new `Settings` field gets a default in `init(from:)`, or an old `state.json` fails to decode and the user's settings vanish.
- The store is the only thing that talks to the engine; views read the store. Anything the core cannot know (foreground pid, the helper, the rollup store) is injected here.
- Now rows: 2 s to appear, 10 s to stay, fixed order disks, link, CPU, memory; the popover never shrinks while open. Do not undo this for a cosmetic change; it was the 0.2.2 fix.
- Notifications go out once, on confirmation, for slow or stalled only, gated by the domain switch. Vestitel gets red alerts only (`Finding.isRedAlert`).
- The updater swap waits for `popoverOpen` to turn false. Test instances (`GARLO_STATE_DIR`) never update without `GARLO_UPDATE_URL`.
- After a self-update the helper is re-registered by polling until the status leaves `.enabled` and waiting three more seconds. Registering earlier reuses launchd's stale record.
- User-facing text follows the copy rules in `.claude/rules/copy.md`. Numbers come from `Units`. Use fixed-width digits where values change every second.
- Screens live in `design/`; a material UI change updates the artboard.
