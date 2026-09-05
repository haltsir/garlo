# Garlo (Гърло)

A macOS menu-bar app that finds what is holding your Mac back, names the cause, and remembers it.

Every Mac ships with Activity Monitor, and it answers the wrong question: how busy things are. Garlo says *why* a copy is slow, whether a download is limited by the link or the server, and whether the machine feels sluggish because of memory pressure or a throttled CPU. Each finding names the resource, the cause, the evidence and what to do about it, in one sentence.

![The popover during a slow copy](docs/screenshots/popover-read-bound.png)

## What it finds

**Storage.** A bulk copy is detected between two disks and judged read-bound or write-bound from busy and idle seconds, confirmed by the idle side's chunk cadence or by queueing on the busy side. The card names the source file's fragmentation (pieces per 8 MB, walked from the extent map), the processes sharing the disk, and the rate and time left. Standalone findings: a spinning disk saturated by small random requests, two processes contending for one disk, a device answering three times slower than its own learned baseline, a disk at its USB link ceiling or linked below its capability, two enclosures sharing one host controller, and a volume above 80 percent full.

**Network.** The link saturated by a named process (confirmed by gateway latency rising under load), Wi-Fi as the limit (transmit rate or signal), bufferbloat, packet loss, slow DNS, and a transfer that is limited by the remote end, confirmed by an opt-in five-second throughput test.

**CPU, memory, thermal.** The foreground app starved by background work, a process using all performance cores, throttling with the process producing the heat, a single-threaded task the user is waiting on, memory pressure and swapping with the largest consumer, a process growing without bound, Low Power Mode during a heavy task, a charger that cannot sustain the load, and GPU-bound work.

Findings open as *suspected* after ten seconds over threshold, become *confirmed* when an independent signal agrees, and resolve thirty seconds after the signal clears. Only confirmed slow or stalled findings notify, and every domain can be silenced. Findings can also be delivered to [Vestitel](../vestitel) as inbox events.

## Privileges

Everything above works with no admin password and no helper. Root processes (Finder's copy helper among them) hide their open files; the card says so and offers "Pick the file" to map the layout by hand, or "Enable the helper". The optional helper is a small daemon inside the app, registered through System Settings > Login Items (one approval, no password), that answers only the signed app and only three questions: which files root processes hold open, how a disk's I/O splits per file, and what SMART says about a disk. It exits when idle and can be removed from Settings in one click.

## Build and run

SwiftPM only, no Xcode project, no dependencies. macOS 15 and later.

```sh
make app        # release build, packaged as Garlo.app (ad-hoc signed)
make run        # build and open
swift test      # rules replayed against recorded and synthetic fixtures
```

The command-line front end runs the same core:

```sh
.build/debug/garlo sample        # live rates and findings, once per second
.build/debug/garlo system        # network, CPU, memory, thermal view
.build/debug/garlo topology      # disks, USB links, hubs, controllers, volumes
.build/debug/garlo layout <file> # extent walk: pieces, median piece size, span
.build/debug/garlo record out.json 60   # capture a fixture from a live incident
.build/debug/garlo replay out.json      # run it through the rules
```

## Privacy

All data stays on the Mac: one-minute rollups for 90 days in `~/Library/Application Support/Garlo/history.sqlite`, findings in `state.json`. The only network calls are a round-trip probe to the gateway and to the anchor host you configure, timed DNS lookups, the throughput test you start yourself, and a daily check of this repository's releases for updates (which can be turned off). Updates are only installed when their signature verifies against the release key built into the app.

## Status

All four milestones of the requirements are implemented: M1 storage, M2 network, CPU, memory and thermal, M3 history and baselines, M4 the privileged helper. The app self-updates from this repository's releases; every release is signed with an ed25519 key and unsigned builds are refused.
