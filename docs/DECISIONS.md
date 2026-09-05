# Decision log

Product and engineering decisions with the reason behind each, so nobody re-litigates them without new evidence. Newest first. Dates are when the decision was made.

## 2026-09-05

**Popover rows use hysteresis and a fixed order.** Now rows appear after 2 s of activity and stay 10 s after it ends, ordered disks, link, CPU, memory. The popover holds its height while open. Reason: rows that appear, vanish and reshuffle every second are unreadable and the popover jumped under the cursor.

**The helper re-registers itself after a self-update, waiting for launchd first.** Registering while launchd is still tearing down the old job reuses its record and the stale launch constraint, and the new daemon dies with "Launch Constraint Violation" (the 0.2.0 bug). The app polls until the service status leaves `.enabled`, then waits three more seconds.

**The privileged helper is an SMAppService daemon signed with the self-signed identity.** It was first deferred on the assumption that daemons need a Team ID. They do not: macOS only ignores the bundle grouping. One approval in Login Items, no password, no Apple fee. The daemon answers exactly three questions and exits after two minutes idle; the app diagnoses without it.

**The helper sends only what the app cannot see.** Other users' and root processes with I/O, and the open files of those moving now. Shipping the whole process table every few seconds broke the 1 percent budget.

**Garlo has its own self-signed "Garlo Signing" identity.** Ad-hoc signatures change every build and macOS re-asked for the removable-volume grant after each rebuild. Reusing another project's identity was rejected. Documented in SIGNING.md so it can be recreated.

**Updates are in-house, ed25519-signed GitHub releases, not Sparkle.** Sparkle wants notarisation and a Developer ID. The updater refuses anything not signed with the embedded public key; the private key never leaves the release machine.

**Vestitel receives red alerts only.** Confirmed stalled findings and the device-slow rule. Everything else stays in the popover and History; an inbox full of "copy is read-bound" would be noise.

**Proactive layout scanning stays off.** Scanning would read the disks that are already the problem. Layouts are probed only for files involved in a detected transfer, or one the user picks, and never for files under 64 MB.

**Two busy disks are not a transfer.** The transfer rule needs a copier process with files on both volumes or the destination's free space draining at the write rate. Torrent seeding plus background boot-disk writes had produced a false "Copy is read-bound". The copied file is only ever the copier's own largest open file or one the user picked; the drain is judged over the whole minute because APFS reports free space with a lag; and without a copier the source must read at least half of what the destination writes, the closest ratio winning.

**Disks are judged by queue-adjusted service time, not raw latency.** Total time delta over the interval is the average queue depth; service time is latency divided by depth. USB RAID enclosures run depths in the hundreds and are healthy. Raw latency blamed a healthy disk under a burst (the Troy case).

**Quiet rules.** One process saturating its own spinning disk is its workload, not a finding, until service time climbs or a second process waits. Read-only mounts and volumes without a physical disk are never "full".

**Fixtures are anonymised before commit.** Recordings carry every open-file path and process name on the machine. `Tools/scrub-fixture.py` replaces them; the machine's own volume and drive names live only in the gitignored `Tools/scrub-renames.json`. No raw recording and no screenshot with real file names is ever published.

**SwiftPM only, no Xcode project, no dependencies.** Same as the sibling Vestitel app. Target `garlo` and directory `GarloCLI` differ in more than case because the filesystem is case-insensitive.

**Copy rules.** Verdicts are one sentence, present tense, subject first. Numbers carry units. Actions are imperative and specific and say their expected effect. No em-dashes anywhere in the project.

## Open

- Notarisation and a Developer ID: not needed for anything that works today. Revisit if the Gatekeeper first-launch step becomes a support burden.
- Unified log signals (flush stalls, USB resets) and Thunderbolt link state are not sampled. The device-slow card says so in its tier hint.
- How much history Vestitel should receive beyond red alerts.
