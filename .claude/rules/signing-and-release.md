---
paths:
  - "Makefile"
  - "Resources/**"
  - "Sources/GarloApp/Updater.swift"
  - "Tools/sign-release.swift"
  - "docs/SIGNING.md"
---

# Signing and releases

- Sign only with the "Garlo Signing" identity (falls back to ad-hoc when absent). Never sign Garlo with another project's identity; the removable-volume privacy grant and the helper's client requirement are keyed to this certificate.
- The ed25519 private key lives in `~/.config/garlo/release-key` and never in the repository. The public key is embedded in `Updater.swift`; changing it orphans every installed copy.
- A release is: bump both version keys in `Resources/Info.plist`, write `release-notes.md` (gitignored), commit, tag `v<version>`, `make release`. Do not run `make release` or push tags unless asked.
- Both `Garlo-<version>.zip` and `Garlo-<version>.zip.sig` must be release assets; the updater refuses a release without a valid signature.
- After a release that changes the helper, confirm the re-registration path (`reregisterAfterUpdate`) still cycles Remove, wait, Install.
