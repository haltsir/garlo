# Budget and privacy

- Sampling budget: under 20 ms per tick, under 1 percent of a core, under 60 MB. Settings shows the live numbers; a change that moves them needs a stated reason.
- Nothing leaves the Mac except the gateway and anchor round-trip probes, timed DNS lookups, the opt-in throughput test and the daily update check. Do not add a network call.
- No proactive disk reads: layouts are probed only for a file in a detected transfer or one the user picked, and never under 64 MB.
- Vestitel receives red alerts only (confirmed stalled, or the device-slow rule).
- Nothing personal in the repository: no raw recordings, no screenshots with real file names, no volume or drive names from the maintainer's Mac. `Tools/scrub-renames.json` and `release-notes.md` stay gitignored.
