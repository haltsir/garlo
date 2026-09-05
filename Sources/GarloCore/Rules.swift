import Foundation

/// A rule is a small, testable function from a window to zero or more
/// candidates. The engine owns the lifecycle; rules only describe now.
public protocol Rule: Sendable {
    var id: String { get }
    func evaluate(_ w: Window) -> [Candidate]
}

/// Thresholds shared by the storage rules. Kept in one place so a fixture
/// test can say exactly which number a verdict rests on.
public enum StorageThresholds {
    public static let window = 15
    /// Sustained read rate that counts as "a transfer is reading here".
    public static let transferReadBytesPerSec = 5_000_000.0
    /// Average write rate on the destination; bursts average low.
    public static let transferWriteBytesPerSec = 2_000_000.0
    public static let boundBusyFraction = 0.8
    public static let boundIdleFraction = 0.7
    public static let slowBytesPerSec = 30_000_000.0
    public static let iopsSaturationOps = 150.0
    public static let iopsSmallRequestBytes = 262_144.0
    public static let iopsServiceMs = 15.0
    public static let contentionShare = 0.2
    /// Per-request latency that means requests are waiting in a queue.
    public static let queuedLatencyMs = 50.0
    public static let linkCeilingFraction = 0.9
    public static let volumeFullFraction = 0.8
    /// Files smaller than this are never probed for layout.
    public static let layoutMinBytes: UInt64 = 64 * 1024 * 1024
    /// Share of the destination's write rate its free space must drain at
    /// for the writes to count as a copy landing there.
    public static let drainFraction = 0.3
    /// Without a copier, the source must read at least this share of what
    /// the destination writes to be named as the source.
    public static let sourceMatchRatio = 0.5
}

// MARK: - Transfer

/// Detects a bulk transfer between two disks and says which side limits it.
/// Absorbs fragmentation, IOPS saturation and contention on the involved
/// disks into one card: that is the finding the user is waiting for.
public struct TransferRule: Rule {
    public let id = "transfer"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = StorageThresholds.self
        let ids = w.diskIDs
        guard ids.count >= 2, w.count >= 3 else { return [] }
        let summaries = Dictionary(uniqueKeysWithValues: ids.map { ($0, DiskSummary(rates: w.rates(disk: $0, last: T.window))) })
        var out: [Candidate] = []
        for dst in ids {
            guard let d = summaries[dst], d.writeBytesPerSec >= T.transferWriteBytesPerSec else { continue }
            // APFS reports free space with a lag of seconds, so the drain is
            // judged over the whole minute against the same minute's writes
            let drain = w.freeSpaceDrain(disk: dst, last: w.capacity)
            let minuteWrite = DiskSummary(rates: w.rates(disk: dst, last: w.capacity)).writeBytesPerSec
            let draining = drain.map { $0 >= minuteWrite * T.drainFraction && $0 >= T.transferWriteBytesPerSec * T.drainFraction } ?? false
            var byCopier: [Candidate] = []
            var byDrain: [(ratio: Double, candidate: Candidate)] = []
            for src in ids where src != dst {
                guard let s = summaries[src], s.readBytesPerSec >= T.transferReadBytesPerSec else { continue }
                // the destination must not be reading heavily itself (that is a second transfer)
                guard d.readBytesPerSec < s.readBytesPerSec * 0.5 else { continue }
                // two busy disks are not a transfer: a process must hold files on
                // both, or the destination's free space must drain at the write rate
                if let copier = copierProcess(src: src, dst: dst, w: w) {
                    byCopier.append(candidate(src: src, dst: dst, s: s, d: d, copier: copier, draining: draining, w: w))
                } else if draining {
                    // without a copier the source must read about what the destination
                    // writes; a seeder reading elsewhere does not become the source
                    let ratio = s.readBytesPerSec / max(d.writeBytesPerSec, 1)
                    guard ratio >= T.sourceMatchRatio else { continue }
                    byDrain.append((ratio, candidate(src: src, dst: dst, s: s, d: d, copier: nil, draining: true, w: w)))
                }
            }
            out += byCopier
            if byCopier.isEmpty, let best = byDrain.min(by: { abs(log($0.ratio)) < abs(log($1.ratio)) }) {
                out.append(best.candidate)
            }
        }
        return out
    }

    private func copierProcess(src: String, dst: String, w: Window) -> Window.Attribution? {
        let srcAttrib = w.attributions(disk: src, last: StorageThresholds.window)
        let dstAttrib = w.attributions(disk: dst, last: StorageThresholds.window)
        return srcAttrib.first { a in dstAttrib.contains { $0.process.pid == a.process.pid } }
    }

    private func candidate(src: String, dst: String, s: DiskSummary, d: DiskSummary, copier: Window.Attribution?, draining: Bool, w: Window) -> Candidate {
        let T = StorageThresholds.self
        let topo = w.topology
        let srcName = topo.displayName(forDisk: src), dstName = topo.displayName(forDisk: dst)
        let srcDisk = topo.disk(src), dstDisk = topo.disk(dst)
        let subject = "\(srcName) to \(dstName)"

        // which side is the limit
        let readBound = s.busyFraction >= T.boundBusyFraction && Double(d.idleTicks) / Double(max(1, d.ticks)) >= T.boundIdleFraction
        let writeBound = d.busyFraction >= T.boundBusyFraction && Double(s.idleTicks) / Double(max(1, s.ticks)) >= T.boundIdleFraction
        // chunk cadence: the idle side moves in a few bursts per window
        let dstBursty = d.writingTicks > 0 && d.writingTicks <= max(1, d.ticks / 4)
        let srcBursty = s.readingTicks > 0 && s.readingTicks <= max(1, s.ticks / 4)
        // queueing: the busy side's requests wait far longer than the other side's
        let srcQueued = s.latencyMsPerOp >= T.queuedLatencyMs && s.queueDepth >= 2 && d.latencyMsPerOp < s.latencyMsPerOp / 10
        let dstQueued = d.latencyMsPerOp >= T.queuedLatencyMs && d.queueDepth >= 2 && s.latencyMsPerOp < d.latencyMsPerOp / 10

        // saturation and layout on the source
        let srcSaturated = (srcDisk?.behavesRotational ?? true)
            && s.readOpsPerSec >= T.iopsSaturationOps
            && s.averageRequestBytes < T.iopsSmallRequestBytes
            && s.bytesPerSec < T.slowBytesPerSec
        let srcAttrib = w.attributions(disk: src, last: T.window)
        let dstAttrib = w.attributions(disk: dst, last: T.window)
        // the copied file: the copier's largest open file on the source, or the
        // one the user picked. Never another process's file.
        let sourceFile = copier.flatMap { $0.files.filter { $0.sizeBytes >= T.layoutMinBytes }.max { $0.sizeBytes < $1.sizeBytes } }
            ?? w.pinnedSources[subject]
        let layout = sourceFile.flatMap { w.layouts[$0.path] ?? nil }

        // other processes on the busy side
        let busyDisk = readBound ? src : (writeBound ? dst : src)
        let others = (readBound || !writeBound ? srcAttrib : dstAttrib)
            .filter { $0.process.pid != copier?.process.pid && ($0.process.bytesPerSec > 100_000 || $0.files.count >= 5) }
        let contributors = others.prefix(3).map { a -> Contributor in
            let verb = a.process.readBytesPerSec >= a.process.writeBytesPerSec ? "reading" : "writing"
            let rate = a.process.bytesPerSec > 100_000 ? ", \(verb) \(Units.rate(a.process.bytesPerSec))" : ""
            return Contributor(name: a.process.name,
                               detail: "\(a.files.count) open file\(a.files.count == 1 ? "" : "s") on \(topo.displayName(forDisk: busyDisk))\(rate)",
                               bundleID: a.process.bundleID)
        }

        // verdict
        var verdict: String, cause: String, severity: Severity, confirmedBy: String?, pending: String?
        let sizeText = sourceFile.map { ", \(Units.bytes(Double($0.sizeBytes)))" } ?? ""
        let rate = min(s.readBytesPerSec, max(d.writeBytesPerSec, 1))
        let slow = rate < T.slowBytesPerSec
        if readBound {
            verdict = "Copy is read-bound"
            severity = slow ? .slow : .notice
            confirmedBy = dstBursty ? "chunk cadence"
                : (srcQueued ? "source queueing, \(Units.ms(s.latencyMsPerOp)) per read against \(Units.ms(d.latencyMsPerOp)) per write" : nil)
            pending = confirmedBy == nil ? "waiting for the destination's write cadence or the source's queue to settle" : nil
            var why: [String] = []
            if let l = layout, l.isFragmented {
                why.append("The source file is in \(Units.count(l.pieces)) pieces (median \(Units.binaryBytes(Double(l.medianPieceBytes)))), so reading it is random I/O on a \(srcDisk?.behavesRotational == true ? "spinning" : "busy") disk.")
            } else if srcSaturated {
                why.append("\(srcName) is answering \(Units.ops(s.readOpsPerSec)) of \(Units.binaryBytes(s.averageRequestBytes)) requests: random I/O on a spinning disk.")
            } else {
                why.append("\(srcName) is busy the whole time while \(dstName) waits.")
            }
            if let first = contributors.first {
                why.append("\(first.name) is using the same disk.")
            }
            cause = "\(subject)\(sizeText). " + why.joined(separator: " ")
        } else if writeBound {
            verdict = "Copy is write-bound"
            severity = slow ? .slow : .notice
            confirmedBy = srcBursty ? "chunk cadence"
                : (dstQueued ? "destination queueing, \(Units.ms(d.latencyMsPerOp)) per write against \(Units.ms(s.latencyMsPerOp)) per read" : nil)
            pending = confirmedBy == nil ? "waiting for the source's read cadence or the destination's queue to settle" : nil
            var why = ["\(dstName) is busy the whole time while \(srcName) waits."]
            if d.serviceMsPerOp > T.iopsServiceMs {
                why.append("Writes take \(Units.ms(d.serviceMsPerOp)) each once queueing is taken out.")
            }
            if let first = contributors.first { why.append("\(first.name) is using the same disk.") }
            cause = "\(subject)\(sizeText). " + why.joined(separator: " ")
        } else {
            verdict = "Copying \(srcName) to \(dstName)"
            severity = .notice
            confirmedBy = copier != nil ? "open files on both volumes" : (draining ? "destination free space draining" : nil)
            pending = confirmedBy == nil ? "waiting to see which side limits it" : nil
            cause = "\(subject)\(sizeText). Both disks are keeping up with each other."
        }

        // evidence
        var evidence = [
            pad(srcName) + "\(Units.rate(s.readBytesPerSec)) · \(Units.ops(s.readOpsPerSec)) · \(Units.ms(s.latencyMsPerOp)) · busy \(s.busyTicks)/\(s.ticks) s",
            pad(dstName) + "\(Units.rate(d.writeBytesPerSec)) · \(d.maxWriteBytesInTick > 0 ? Units.binaryBytes(d.maxWriteBytesInTick) + " bursts" : Units.ops(d.writeOpsPerSec)) · idle \(d.idleTicks)/\(d.ticks) s",
        ]
        if let f = sourceFile, let written = bytesWritten(to: dst, w: w), f.sizeBytes > written {
            let left = Double(f.sizeBytes - written)
            evidence.append(pad("Rate") + "\(Units.rate(rate)) · \(Units.bytes(left)) left · \(Units.duration(left / max(rate, 1)))")
        } else {
            evidence.append(pad("Rate") + Units.rate(rate))
        }

        // actions
        var actions: [Action] = []
        if readBound || writeBound {
            for c in contributors.prefix(2) {
                actions.append(Action("Pause \(c.name)", effect: "it shares the \(readBound ? "source" : "destination") disk",
                                      kind: c.bundleID.map { .openApp(bundleID: $0) } ?? .none))
            }
            actions.append(Action("Do not restart the copy", effect: "a restart rereads the same pieces"))
        }
        if let f = sourceFile {
            actions.append(Action("Show file layout", kind: .showLayout(path: f.path)))
        } else if readBound {
            actions.append(Action("Pick the file", effect: "map its layout to see whether it is fragmented", kind: .pickSource(subject: subject)))
        }

        var tierHint: String?
        if copier == nil {
            tierHint = sourceFile == nil
                ? "Unprivileged diagnosis: the copy runs in a root helper that hides its files. Pick the file, or enable the helper."
                : "Unprivileged diagnosis: enable the helper to attribute reads per process."
        }

        return Candidate(rule: id, subject: subject, domain: .storage, verdict: verdict, cause: cause,
                         contributors: contributors, evidence: evidence, actions: actions,
                         severity: severity, confirmedBy: confirmedBy, pending: pending, tierHint: tierHint,
                         explainsDisks: [src, dst])
    }

    /// Bytes written to `disk` since the window started.
    private func bytesWritten(to disk: String, w: Window) -> UInt64? {
        guard let first = w.frames.first?.disks.first(where: { $0.id == disk }),
              let last = w.frames.last?.disks.first(where: { $0.id == disk }),
              last.bytesWritten >= first.bytesWritten else { return nil }
        return last.bytesWritten - first.bytesWritten
    }

}

func pad(_ s: String, _ width: Int = 10) -> String {
    s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

// MARK: - IOPS saturation

/// A rotational disk answering many small requests: random I/O.
public struct IOPSSaturationRule: Rule {
    public let id = "iops"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = StorageThresholds.self
        var out: [Candidate] = []
        for id in w.diskIDs where !w.explainedDisks.contains(id) {
            guard let disk = w.topology.disk(id), disk.behavesRotational else { continue }
            let s = DiskSummary(rates: w.rates(disk: id, last: T.window))
            guard s.ticks >= 3, s.opsPerSec >= T.iopsSaturationOps, s.averageRequestBytes < T.iopsSmallRequestBytes, s.bytesPerSec < T.slowBytesPerSec else { continue }
            let attrib = w.attributions(disk: id, last: T.window)
            // one process saturating its own disk is its workload, not a finding;
            // it becomes one when the disk struggles or a second process waits
            guard s.serviceMsPerOp > T.iopsServiceMs || attrib.count >= 2 else { continue }
            let name = w.topology.displayName(forDisk: id)
            let contributors = attrib.prefix(3).map {
                Contributor(name: $0.process.name, detail: "\($0.files.count) open file\($0.files.count == 1 ? "" : "s"), \(Units.rate($0.process.bytesPerSec))", bundleID: $0.process.bundleID)
            }
            let kind = s.readOpsPerSec >= s.writeOpsPerSec ? "reads" : "writes"
            out.append(Candidate(
                rule: self.id, subject: name, domain: .storage,
                verdict: "\(name) is saturated by small \(kind)",
                cause: "\(Units.ops(s.opsPerSec)) of \(Units.binaryBytes(s.averageRequestBytes)) requests move only \(Units.rate(s.bytesPerSec)). On a spinning disk that is seek time, not bandwidth." + (contributors.first.map { " \($0.name) is the main user." } ?? ""),
                contributors: contributors,
                evidence: [pad(name) + "\(Units.rate(s.bytesPerSec)) · \(Units.ops(s.opsPerSec)) · \(Units.ms(s.serviceMsPerOp))/op service · depth \(String(format: "%.1f", s.queueDepth))"],
                actions: contributors.compactMap { c in c.bundleID.map { Action("Pause \(c.name)", kind: .openApp(bundleID: $0)) } },
                severity: .slow,
                confirmedBy: s.serviceMsPerOp > T.iopsServiceMs ? "service time \(Units.ms(s.serviceMsPerOp)) per op" : nil,
                pending: s.serviceMsPerOp > T.iopsServiceMs ? nil : "waiting for service time above \(Units.ms(T.iopsServiceMs)) per op"
            ))
        }
        return out
    }
}

// MARK: - Contention

/// Two or more processes each taking a real share of one saturated disk.
public struct ContentionRule: Rule {
    public let id = "contention"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = StorageThresholds.self
        var out: [Candidate] = []
        for id in w.diskIDs where !w.explainedDisks.contains(id) {
            let s = DiskSummary(rates: w.rates(disk: id, last: T.window))
            guard s.ticks >= 3, s.busyFraction >= T.boundBusyFraction else { continue }
            let attrib = w.attributions(disk: id, last: T.window).filter { $0.process.bytesPerSec > 0 }
            let total = attrib.map(\.process.bytesPerSec).reduce(0, +)
            guard total > 0 else { continue }
            let sharers = attrib.filter { $0.process.bytesPerSec / total >= T.contentionShare }
            guard sharers.count >= 2 else { continue }
            let name = w.topology.displayName(forDisk: id)
            let names = sharers.map(\.process.name)
            let contributors = sharers.map {
                Contributor(name: $0.process.name, detail: "\(Units.rate($0.process.bytesPerSec)), \(Units.percent($0.process.bytesPerSec / total)) of attributed traffic", bundleID: $0.process.bundleID)
            }
            let accounted = total / max(s.bytesPerSec, 1)
            out.append(Candidate(
                rule: self.id, subject: name, domain: .storage,
                verdict: "\(names.prefix(2).joined(separator: " and ")) contend for \(name)",
                cause: "\(name) is busy \(s.busyTicks) of \(s.ticks) s and \(names.count) processes each take at least a fifth of its traffic. Each one is slowing the others.",
                contributors: contributors,
                evidence: [pad(name) + "\(Units.rate(s.bytesPerSec)) · \(Units.ops(s.opsPerSec)) · busy \(s.busyTicks) of \(s.ticks) s"]
                    + contributors.map { pad($0.name) + $0.detail },
                actions: contributors.compactMap { c in c.bundleID.map { Action("Pause \(c.name)", kind: .openApp(bundleID: $0)) } },
                severity: .slow,
                confirmedBy: accounted >= 0.5 ? "per-process disk bytes" : nil,
                pending: accounted >= 0.5 ? nil : "only \(Units.percent(accounted)) of the traffic is attributable without the helper"
            ))
        }
        return out
    }
}

// MARK: - Link ceiling

/// Throughput within 10 percent of the negotiated USB link rate, or two
/// busy enclosures sharing one host controller.
public struct LinkCeilingRule: Rule {
    public let id = "link"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = StorageThresholds.self
        var out: [Candidate] = []
        out += sharedControllers(w)
        for id in w.diskIDs {
            guard let disk = w.topology.disk(id), let usb = disk.usb else { continue }
            let ceiling = usb.speed.practicalBytesPerSecond
            let s = DiskSummary(rates: w.rates(disk: id, last: T.window))
            guard s.ticks >= 3, s.bytesPerSec >= ceiling * T.linkCeilingFraction else { continue }
            let name = w.topology.displayName(forDisk: id)
            let below = usb.capableSpeed.map { $0.rawValue > usb.speed.rawValue } ?? false
            var cause = "\(name) is moving \(Units.rate(s.bytesPerSec)) on a \(usb.speed.label) link, which tops out near \(Units.rate(ceiling))."
            var actions: [Action] = []
            // a USB 2.0 hub caps everything behind it at 480 Mb/s, whatever the device can do
            let slowHub = usb.speed.rawValue <= USBSpeed.high.rawValue && usb.hubs.contains { $0.contains("2.0") || $0.contains("2.1") }
            if below, let cap = usb.capableSpeed {
                cause += " The device supports \(cap.label) but negotiated \(usb.speed.label)" + (usb.hubs.isEmpty ? "." : " behind \(usb.hubs.joined(separator: ", ")).")
                actions.append(Action("Reconnect without the hub or on a faster port", effect: "expect up to \(Units.rate(cap.practicalBytesPerSecond))"))
            } else if slowHub {
                cause += " It sits behind \(usb.hubs.joined(separator: " and ")), and a USB 2.0 hub caps every device behind it at 480 Mb/s."
                actions.append(Action("Connect it directly or through a USB 3 hub", effect: "if the device supports USB 3, expect up to \(Units.rate(USBSpeed.superSpeed.practicalBytesPerSecond))"))
            }
            // a shared controller already explains this disk
            if out.contains(where: { $0.explainsDisks.contains(id) }) { continue }
            out.append(Candidate(
                rule: self.id, subject: name, domain: .bus,
                verdict: "\(name) is at its link ceiling",
                cause: cause,
                evidence: [pad(name) + "\(Units.rate(s.bytesPerSec)) · link \(usb.speed.label) · \(Units.percent(s.bytesPerSec / ceiling)) of ceiling",
                           pad("Path") + ([usb.productName] + usb.hubs + [usb.controller]).filter { !$0.isEmpty }.joined(separator: " > ")],
                actions: actions,
                severity: below || slowHub ? .slow : .notice,
                confirmedBy: below ? "device linked below its capability" : "sustained \(s.ticks) s"
            ))
        }
        return out
    }
}

// MARK: - Volume nearly full

/// APFS degrades above roughly 80 percent; on rotational media the free
/// space fragments and so do new files.
public struct VolumeFullRule: Rule {
    public let id = "full"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = StorageThresholds.self
        return w.topology.volumes.compactMap { v in
            // read-only mounts and images without a physical disk cannot be filling up
            guard !v.isReadOnly, v.diskID != nil, v.totalBytes > 1_000_000_000, v.usedFraction >= T.volumeFullFraction else { return nil }
            let disk = v.diskID.flatMap { w.topology.disk($0) }
            var cause = "\(v.name) is \(Units.percent(v.usedFraction)) used with \(Units.bytes(Double(v.freeBytes))) free."
            var actions: [Action] = []
            if disk?.behavesRotational == true {
                cause += " New large files on a nearly full spinning disk land in many small pieces."
                if v.defragmentEnabled == false {
                    cause += " APFS defragmentation is off on this volume."
                    actions.append(Action("Enable defragmentation", effect: "future writes are coalesced", kind: .openURL("x-garlo://defrag/\(v.bsdName)")))
                }
            }
            actions.append(Action("Keep it under 80 percent", effect: "move finished downloads elsewhere"))
            return Candidate(
                rule: id, subject: v.name, domain: .storage,
                verdict: "\(v.name) is \(Units.percent(v.usedFraction)) full",
                cause: cause,
                evidence: [pad(v.name) + "\(Units.bytes(Double(v.totalBytes - v.freeBytes))) of \(Units.bytes(Double(v.totalBytes))) · \(v.fileSystem)" + (v.defragmentEnabled.map { " · defrag \($0 ? "on" : "off")" } ?? "")],
                actions: actions,
                severity: .notice,
                confirmedBy: "statfs"
            )
        }
    }
}

extension LinkCeilingRule {
    /// Disks behind one USB host controller add up against that controller's
    /// fastest link: two 5 Gb/s enclosures on one controller share 5 Gb/s.
    func sharedControllers(_ w: Window) -> [Candidate] {
        let T = StorageThresholds.self
        var groups: [String: [(DiskDevice, DiskSummary)]] = [:]
        for id in w.diskIDs {
            guard let disk = w.topology.disk(id), let usb = disk.usb, !usb.controller.isEmpty else { continue }
            let s = DiskSummary(rates: w.rates(disk: id, last: T.window))
            guard s.ticks >= 3, s.bytesPerSec > 1_000_000 else { continue }
            groups[usb.controller, default: []].append((disk, s))
        }
        return groups.compactMap { controller, members in
            guard members.count >= 2 else { return nil }
            let ceiling = members.map { $0.0.usb!.speed.practicalBytesPerSecond }.max() ?? 0
            let total = members.map(\.1.bytesPerSec).reduce(0, +)
            guard ceiling > 0, total >= ceiling * T.linkCeilingFraction else { return nil }
            let names = members.map { w.topology.displayName(forDisk: $0.0.id) }
            return Candidate(
                rule: id, subject: controller, domain: .bus,
                verdict: "\(names.joined(separator: " and ")) share one USB controller",
                cause: "Together they move \(Units.rate(total)), which is all a \(members[0].0.usb!.speed.label) controller can carry. Each one only gets what the other leaves.",
                contributors: members.map { Contributor(name: w.topology.displayName(forDisk: $0.0.id), detail: Units.rate($0.1.bytesPerSec)) },
                evidence: [pad("Controller") + "\(Units.rate(total)) of \(Units.rate(ceiling)) · \(controller)"],
                actions: [Action("Move one enclosure to a port on another controller", effect: "each gets its own \(members[0].0.usb!.speed.label)")],
                severity: .slow,
                confirmedBy: "registry topology and counters",
                explainsDisks: members.map(\.0.id)
            )
        }
    }
}

public enum StorageRules {
    public static var all: [any Rule] {
        [TransferRule(), IOPSSaturationRule(), ContentionRule(), LinkCeilingRule(), VolumeFullRule()]
    }
}
