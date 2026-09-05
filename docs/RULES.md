# Rule catalogue

Every finding Garlo can show, by rule id. Rules are pure functions from the last minute of samples (the `Window`) to zero or more candidates; the lifecycle (suspected after 10 s, confirmed by an independent signal, resolved 30 s after it clears) is the same for all of them. Thresholds are in `StorageThresholds` (`Sources/GarloCore/Rules.swift`), `SystemThresholds` (`Sources/GarloCore/SystemRules.swift`) and `DeviceSlowRule` (`Sources/GarloCore/Baselines.swift`). Wording follows the copy rules: verdicts are one sentence, present tense, subject first; numbers carry units; actions are imperative and specific.

Evaluation order matters. `TransferRule` runs first and claims the disks a copy involves (`explainsDisks`); `IOPSSaturationRule` and `ContentionRule` skip those, so one incident is one card. `MemoryPressureRule` runs right after the transfer rule so swapping is explained before boot-disk contention is. The order is `AllRules.all`.

## Storage

### transfer, "Copy is read-bound" / "Copy is write-bound" / "Copying A to B"

The composite card. Domain storage, subject "A to B".

- **Detects** a destination writing at least 2 MB/s on average and a source reading at least 5 MB/s over the last 15 s, where the destination is not itself reading heavily. Two busy disks are not a transfer: a process must have open files on both volumes (the copier), or the destination's free space must drain over the whole minute at 30 percent or more of its write rate. Without a copier, the source must read at least half of what the destination writes, and among several candidates the one whose read-to-write ratio is closest to one wins.
- **Judges** read-bound when the source is busy 80 percent of ticks and the destination idle 70 percent; write-bound the other way round; otherwise "Copying A to B" as a notice.
- **Confirms** by chunk cadence (the idle side moves in bursts, writing or reading in a quarter of the ticks or fewer) or by queueing (the busy side's latency per op is at least 50 ms with depth at least 2 and at least ten times the other side's). The plain "Copying" form confirms by open files on both volumes or by the free-space drain.
- **Severity** slow when the effective rate is under 30 MB/s, notice otherwise.
- **Absorbs** the source file's layout (copier's largest open file of 64 MB or more, or the file the user picked; probed on first sight, never proactively), IOPS saturation on the source, and contention from processes sharing the busy disk. Contributors get "Pause X" actions when they have a bundle id.
- **Tier hint** when the copier runs as root and the helper is off: the card offers "Pick the file" and "Enable the helper".
- **Tests**: `FixtureTests.copyFromFragmentedStorageIsReadBound` (real recording `copy-archive-to-boot.json`), `TransferCorrelationTests`, `TransferSourceMatchingTests`.

### iops, "A is saturated by small reads/writes"

Rotational disks only. At least 150 ops/s of requests averaging under 256 KiB moving under 30 MB/s. Quiet for one process saturating its own disk unless service time exceeds 15 ms per op or a second process has files open there. Confirmed by service time above 15 ms; pending otherwise. Severity slow. Skips disks a transfer explains.

### contention, "X and Y contend for A"

A disk busy 80 percent of ticks where at least two processes each take a fifth or more of the attributed traffic. Confirmed when the attributed bytes account for half of the disk's traffic; without the helper root processes are unattributed and the card says how much is missing. Severity slow. Skips disks a transfer explains. Actions: "Pause X" per contributor with a bundle id.

### link, "A is at its link ceiling" / "A and B share one USB controller"

Domain bus. A USB disk moving 90 percent or more of its link's practical rate. Severity slow with a reconnect action when the device is linked below what it supports (a USB 3 device at 480 Mb/s or lower; `bcdUSB` only states the spec version, so the capability is a floor) or when it sits behind a USB 2.0 hub; notice otherwise. Separately, two or more busy disks on one host controller whose combined rate reaches 90 percent of the fastest link among them get one card that explains both disks. Confirmed by topology and counters.

### full, "V is N percent full"

Notice. A writable volume with a physical disk and at least 1 GB total at 80 percent or more used. On rotational media the card adds that new files will land in pieces and, when APFS defragmentation is off, offers to enable it. Read-only mounts and images without a disk are skipped (a read-only NTFS image once reported 100 percent full). Confirmed by `statfs`.

### deviceslow, "A is slower than it used to be"

Needs a learned baseline (ten busy minutes, median service time over the last week). Over the last 30 s, at least two thirds of ticks busy (20 ops/s or more) and queue-adjusted service time at least three times the baseline and at least 5 ms. Confirmed after 20 busy ticks. Severity slow, and a red alert: it goes to Vestitel. Actions: check the enclosure and cables, reset the baseline. Tier hint about unified-log flush stalls. Tests: `BaselineTests`.

## Network

Domain network. The primary interface is the one with the default route; virtual interfaces are filtered by name. Wi-Fi link rate comes from CoreWLAN because the driver's baudrate is stale.

### nethog, "Link is saturated" / "Link is saturated by X"

Utilisation of the primary link at 85 percent or more over 15 s. Without a process taking 60 percent of the per-process bytes it is a notice, pending the name. With one, severity slow, confirmed when the gateway round trip rises under load. Test: `SyntheticRuleTests.hogNamesTheProcess`.

### wifi, "Wi-Fi is the limit"

Over 30 s, the transmit rate is under 30 percent of what the band and width allow, or RSSI is at or below -75 dBm, while the link is at least half busy. Confirmed once both, or one, have held for the full 30 s. Severity slow. Tests: `weakWiFiIsTheLimit`, `quietWiFiSaysNothing`.

### bufferbloat, "Link is queueing under load"

The link at least half utilised and the gateway round trip at least 100 ms above its idle minimum. Confirmed by two consecutive inflated probes. Severity slow. Test: `bufferbloatNeedsTwoInflatedProbes`.

### remote, "The remote end is the limit for X"

Over 30 s the link is not saturated, the gateway round trip is within 50 ms of idle, and one process takes 80 percent of the traffic at 200 KB/s or more. Notice. Confirmed only by the opt-in throughput test reaching the link's rate; the card offers to run it.

### loss, "Link is dropping packets"

Interface error and drop counters at 0.5 percent or more of packets over 15 s, at 100 packets/s or more. Severity slow, confirmed by the counters.

### dns, "DNS is slow"

Two consecutive lookups over 300 ms. Notice. Lookups rotate through a short list of well-known names.

## CPU, memory, thermal

### cpu, "X is using all performance cores" / "F is starved by X"

Performance cores at 90 percent or more over 15 s. Same-named processes are merged, so ten `yes` loops read as "yes (10 processes)". When the frontmost app is a different process getting under a tenth of the busy cores, the verdict names it as starved and severity is slow; otherwise notice. Confirmed when the load average exceeds the core count or per-process CPU time adds up to the cores. Test: `CPUFixtureTests` on the real recording `cpu-saturated.json`.

### throttle, "CPU is throttled to N percent" / "Mac is thermally limited"

The speed limit from `IOPMCopyCPUPowerStatus` under 100, or the thermal state above nominal, on the latest tick and at least three ticks of the window. Names the process producing the heat. Confirmed after 30 s. Severity slow. Test: `throttlingConfirmsAfterThirtySeconds`.

### singlethread, "F is limited to one core"

The frontmost app holding between 0.9 and 1.15 cores for 30 s on a machine with more than two cores and performance utilisation under 50 percent. Notice, confirmed by duration.

### memory, "Memory is under pressure" / "Mac is swapping"

Pressure at warning or above, or page-outs at 5 MB/s or more. Swapping when pressure is critical or page-outs pass the threshold. Severity stalled at critical pressure (a red alert), slow otherwise. Names the largest consumer. Confirmed by swap traffic on the boot disk. Test: `swappingIsStalledAndConfirmedByBootDiskWrites`.

### runaway, "X is growing without bound"

A process whose footprint grew by 500 MB or more over the recorded span without ever shrinking. Notice, confirmed by the monotonic growth.

### lowpower, "Low Power Mode is on during a heavy task"

Low Power Mode on while total CPU is at 70 percent or more. Notice.

### charger, "The charger cannot sustain the load"

On mains, not charging, and the battery current negative on at least five ticks including the latest. Severity slow, confirmed after 30 s.

### gpu, "The GPU is the limit"

GPU utilisation at 90 percent or more over at least five samples while performance cores are under 50 percent. Notice, names the frontmost app.

## Adding or changing a rule

1. Put thresholds in the right `Thresholds` enum, never inline.
2. Give the candidate a stable subject: the key is rule id plus subject and must survive from tick to tick or the finding flickers.
3. Set `confirmedBy` only from an independent signal; while it is nil, say in `pending` what you are waiting for.
4. If the rule explains a disk another rule would also fire on, list it in `explainsDisks` and run before that rule.
5. Write the fixture: `garlo record` during a real incident, then `python3 Tools/scrub-fixture.py`, or synthetic frames in `SyntheticRuleTests` when the incident cannot be reproduced. Assert the verdict, subject and confirmation, not the numbers.
6. Update this catalogue.
