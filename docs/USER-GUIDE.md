# Garlo user guide

Garlo (Гърло, "throat", as in a bottleneck) lives in the menu bar and answers one question: what is holding this Mac back right now, and why. This guide is for anyone who installs the app and wants to read what it says. The [advanced guide](ADVANCED.md) covers the command line, fixtures, the helper daemon and releases.

## What you need

- A Mac with Apple silicon running macOS 15 or later.
- Nothing else. No admin password, no account, no network service. Everything runs and stays on the Mac.

## Install

1. Download `Garlo-<version>.zip` from the [releases page](https://github.com/haltsir/garlo/releases) and unzip it.
2. Move `Garlo.app` to `/Applications` (or anywhere you like).
3. Open it. The app is signed with its own certificate, not an Apple Developer ID, so macOS blocks the first launch. Right-click the app, choose Open, and confirm. Or open System Settings > Privacy & Security and press Open Anyway. This happens once. Updates the app downloads itself are never blocked again.

Garlo has no Dock icon and no main window. Look for its icon at the right end of the menu bar.

To start Garlo every time you log in, open Settings from the popover and turn on Launch at login.

## The menu bar icon

The icon is a bottle neck: a wide mouth narrowing to a throat. It is monochrome while nothing is wrong and never animates.

| Icon | Meaning |
| --- | --- |
| Plain | Nothing confirmed. The Mac may be busy, but nothing is slow. |
| Amber dot | A confirmed finding says something is slow. |
| Red dot | A confirmed finding says something has stalled, or a disk looks like it is failing. |

Click the icon to open the popover.

## The popover

From top to bottom:

- **Now.** One row per resource that is busy at this moment: a disk, the network link, the CPU, memory. Each row shows the rate, a bar for how busy it is, and a label such as "busy 92%" or "queue 40" (requests waiting). Rows appear after two seconds of activity and stay ten seconds after it ends, so the list does not flicker.
- **Findings.** Cards for things that are slow or stalled. This is what the app exists for.
- **Notices.** Cards for things worth knowing that are not slowing you down yet: a volume nearing full, a copy that is keeping up on both sides, two enclosures sharing one USB controller.
- **Last resolved.** The most recent finding that cleared, with its start and end time.
- **Open History** opens the History window (see below). The gear opens Settings.
- A footer with Garlo's own cost: its CPU share and memory.

When nothing is busy and nothing is open, the popover says so and stays empty.

## Reading a card

Every card has the same shape:

1. **Verdict.** One sentence, present tense, subject first: "Copy is read-bound", "Wi-Fi is the limit", "Safari is starved by Compressor".
2. **Cause.** One or two sentences with numbers: which file, how many pieces it is in, which process shares the disk, how far the link is from its ceiling.
3. **Contributors.** The processes adding to the problem, each with what it is doing.
4. **Evidence.** The measurements the verdict rests on: rates, queue depths, service times, link speeds.
5. **Actions.** Buttons for what to do about it: pause the process that competes for the disk, reveal the file, show its layout, run a throughput test, enable the helper. The first action is the one Garlo recommends. Each action says what effect to expect.
6. **Wrong.** Press this when Garlo got it wrong. The card disappears, and the last minute of measurements is saved under `~/Library/Application Support/Garlo/Fixtures/` so the mistake can be turned into a test. The file contains the names of open files and processes on your Mac. Share it only after running it through the anonymiser described in the advanced guide.

### Suspected and confirmed

A card starts as **suspected** after ten seconds over threshold and says what it is waiting for ("waiting for the destination's write cadence or the source's queue to settle"). It becomes **confirmed** the moment a second, independent signal agrees: the idle side of a copy moving in bursts, the gateway round trip rising under load, boot-disk writes during swapping. A confirmed card never drops back to suspected. A card resolves thirty seconds after the signal clears.

### Severity

| Severity | What it means |
| --- | --- |
| Notice | Worth knowing. Nothing you are waiting on is slower for it. |
| Slow | Something you are waiting on runs below what the hardware can do. |
| Stalled | Something is not progressing, or the Mac is swapping. |

### The tier hint

Some cards end with a line such as "Root processes' open files are hidden without the helper" or "Unified log flush stalls would corroborate this". These say what Garlo could not see from a normal user account and what would sharpen the verdict. Nothing is wrong with the card; it is telling you the limits of its evidence.

## What Garlo can find

**Storage.** A copy between two disks, judged read-bound or write-bound, with the source file's fragmentation, the processes sharing the disk, and the time left. A spinning disk saturated by small random requests. Two processes contending for one disk. A disk answering three times slower than it used to. A disk at the ceiling of its USB link, or linked below what it supports. Two enclosures on one USB controller. A volume above 80 percent full.

**Network.** The link saturated by a named process. Wi-Fi as the limit, from transmit rate or signal. Bufferbloat (the link queueing under load). Packet loss. Slow DNS. A transfer limited by the remote end, confirmed by a throughput test you start yourself.

**CPU, memory, thermal.** The app in front starved by background work. A process using all performance cores. Throttling, with the process producing the heat. An app limited to one core. Memory pressure and swapping, with the largest consumer. A process growing without bound. Low Power Mode during a heavy task. A charger that cannot sustain the load. The GPU as the limit.

The full list with verdict wording is in the [rule catalogue](RULES.md).

## Notifications

Only confirmed findings of severity slow or stalled ever notify, and they notify once. Suspected cards and notices wait in the popover. Settings has one switch per domain: storage transfers (on by default), network, CPU and thermal, memory (off by default). macOS asks for notification permission the first time Garlo has something to say.

If [Vestitel](https://github.com/haltsir/vestitel) is installed, red alerts (stalled findings and a disk that looks like it is failing) also land in its inbox, so they do not vanish with the banner. Turn this off in Settings, or turn on Redact file paths to keep file names out of those events.

## The privileged helper

Garlo diagnoses without any privileges. What it cannot see from a normal account is the open files of processes owned by root, and Finder copies files through one of those. A card about such a copy says so and offers two ways forward:

- **Pick the file.** You choose the file being copied, and Garlo maps its layout by hand.
- **Enable the helper.** A small daemon inside the app that runs as root only while Garlo has a question and exits after two minutes without one.

To install it: Settings > Privileged helper > Install. macOS opens System Settings > Login Items; switch Garlo on there. No password is asked. The helper answers only the signed Garlo app and only three questions: which files root processes hold open, how a disk's traffic splits per file, and what SMART says about a disk. Remove it with one click in the same place.

After you install a new build of Garlo by hand (not through the built-in updater), the helper has to be removed and installed again, because macOS ties the approval to the exact build. Self-updates do this for you.

## The History window

Open History shows one lane per resource (each disk, the network interface, CPU, memory, thermal) over the last 24 hours, 7, 30 or 90 days, with findings drawn as bars on the lane they concern. Click a bar to see the finding as it was at the time. Click a lane to open the device page:

- **Learned baseline.** What "normal" service time looks like for this device, learned from its own busy minutes. Garlo needs ten busy minutes before it has a baseline. The "slower than it used to be" finding compares against this number. Reset it from the card or from this page if the device changed (a new enclosure, a new cable).
- **Trend.** Service time per day over the range.
- **Findings here.** Every finding on this device in the range.

History keeps one row per resource per minute for the period chosen in Settings (7, 30 or 90 days). The last minute is always kept at full one-second resolution.

## Settings

| Setting | What it does |
| --- | --- |
| Notifications | One switch per domain. Only confirmed slow or stalled findings notify. |
| Send red alerts to Vestitel | Stalled findings and failing hardware go to the Vestitel inbox. |
| Redact file paths | Keeps volume names, drops paths, in events and exports. |
| Privileged helper | Install, Remove, or open Login Items when approval is pending. |
| Keep history for | 7, 30 or 90 days of findings and one-minute rollups. |
| Latency anchor | The one host Garlo probes for round-trip time. Default one.one.one.one. |
| Throughput test | The URL of the opt-in five-second download. Run it from here or from a card. |
| Clear history | Removes findings, rollups and learned baselines. |
| Overhead now | Garlo's own CPU and memory, measured by its own samplers. |
| Last sample took | Milliseconds spent on the last one-second sample. Budget: under 20 ms. |
| Launch at login | Registers Garlo as a login item. |
| Check for updates daily | Once a day, at 12:30, Garlo asks GitHub for a newer release. Only releases signed with Garlo's release key are installed. Check Now and Install Now are next to it. |

## Privacy

Everything stays on the Mac. Findings live in `~/Library/Application Support/Garlo/state.json`, rollups and baselines in `history.sqlite` beside it. The only things that leave the Mac are:

- a round-trip probe to your router and to the latency anchor you configure,
- timed DNS lookups against a short list of well-known names,
- the throughput test you start yourself,
- the daily check of the releases page, which can be turned off.

The first time Garlo maps the layout of a file on a removable disk, macOS asks whether Garlo may access files on removable volumes. Say yes if you want the layout; say no and Garlo skips it.

## When something looks wrong

- **A card blames the wrong thing.** Press Wrong. The card goes away and the measurements are kept so the rule can be fixed.
- **The icon shows a dot but the popover has no card.** The finding resolved a moment ago. Look under Last resolved.
- **The helper says "not answering yet".** Give it a few seconds after approval. If it stays that way after a manual reinstall of the app, press Remove, wait a few seconds, then Install.
- **A copy card says the source file is hidden.** The copier runs as root. Use Pick the file or enable the helper.
- **Garlo's own overhead turns amber.** Its CPU or memory exceeded the budget. Quit and reopen, and if it recurs, record it (advanced guide) and open an issue.
