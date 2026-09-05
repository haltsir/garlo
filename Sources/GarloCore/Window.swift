import Foundation

/// The last minute of frames at full resolution, plus everything a rule
/// needs to reason about them. Rules are pure functions over a Window.
public struct Window: Sendable {
    public private(set) var frames: [Frame] = []
    public var capacity: Int
    public var topology: Topology
    /// Latest open-file listing per pid (refreshed every few seconds).
    public var openFiles: [Int32: [OpenFile]] = [:]
    /// Probed layouts by path. `nil` value: probed and unreadable.
    public var layouts: [String: FileLayout?] = [:]
    /// Disks an earlier rule in this tick, or an open finding, already
    /// explains. Standalone rules skip them so one incident is one card.
    public var explainedDisks: Set<String> = []
    public var footprints = FootprintHistory()
    /// Source files the user pointed Garlo at ("Pick the file"), by transfer subject.
    public var pinnedSources: [String: OpenFile] = [:]
    /// Learned baselines by resource key ("disk:disk4"), from the rollup store.
    public var baselines: [String: RollupStore.Baseline] = [:]
    /// Result of the last opt-in throughput test.
    public var throughputTest: ThroughputTest.Result?
    /// True when the privileged helper answers; rules drop their tier hints.
    public var helperAvailable = false
    /// The helper's latest per-file I/O sample, when one was taken.
    public var fileIO: FileIOReport?
    /// Name of the interface with the default route, when known.
    public var primaryInterface: String?

    public init(capacity: Int = 60, topology: Topology = Topology()) {
        self.capacity = capacity
        self.topology = topology
    }

    /// Rate tables several rules ask for on the same tick, computed once.
    /// Reset on every append; the box is a class so non-mutating reads fill it.
    public final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [String: Any] = [:]
        public func get<T>(_ key: String, _ make: () -> T) -> T {
            lock.lock()
            if let hit = tables[key] as? T { lock.unlock(); return hit }
            lock.unlock()
            let value = make()
            lock.lock(); tables[key] = value; lock.unlock()
            return value
        }
    }
    public private(set) var cache = Cache()

    public mutating func append(_ frame: Frame) {
        frames.append(frame)
        cache = Cache()
        footprints.record(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
        for (pid, files) in frame.openFiles { openFiles[pid] = files }
        let live = Set(frame.processes.map(\.pid))
        openFiles = openFiles.filter { live.contains($0.key) }
    }

    public var now: Date { frames.last?.timestamp ?? Date() }
    public var count: Int { frames.count }

    // MARK: Disk rates

    /// Per-tick rates of one disk over the last `seconds` frames, oldest first.
    public func rates(disk id: String, last seconds: Int) -> [DiskRate] {
        guard frames.count >= 2 else { return [] }
        let slice = frames.suffix(seconds + 1)
        var out: [DiskRate] = []
        var previous: Frame?
        for f in slice {
            defer { previous = f }
            guard let p = previous,
                  let a = p.disks.first(where: { $0.id == id }),
                  let b = f.disks.first(where: { $0.id == id }) else { continue }
            let dt = f.timestamp.timeIntervalSince(p.timestamp)
            if let r = DiskRate.between(a, b, interval: dt) { out.append(r) }
        }
        return out
    }

    public var diskIDs: [String] { frames.last?.disks.map(\.id) ?? [] }

    /// The most recent tick's rate of every disk.
    public func latestRates() -> [DiskRate] {
        diskIDs.compactMap { rates(disk: $0, last: 1).last }
    }

    // MARK: Process rates

    /// Average rate of every process over the last `seconds` frames.
    public func processRates(last seconds: Int) -> [ProcessRate] {
        cache.get("proc-\(seconds)") { computeProcessRates(last: seconds) }
    }

    private func computeProcessRates(last seconds: Int) -> [ProcessRate] {
        guard frames.count >= 2 else { return [] }
        let slice = Array(frames.suffix(seconds + 1))
        guard let first = slice.first, let last = slice.last, first.timestamp < last.timestamp else { return [] }
        let dt = last.timestamp.timeIntervalSince(first.timestamp)
        let earliest = Dictionary(first.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return last.processes.compactMap { p in
            guard let e = earliest[p.pid] else { return nil }
            return ProcessRate.between(e, p, interval: dt)
        }
    }

    // MARK: Attribution

    /// Processes with open files on a disk's volumes, with their I/O rates.
    public struct Attribution: Sendable, Hashable {
        public var process: ProcessRate
        public var files: [OpenFile]
    }

    public func attributions(disk id: String, last seconds: Int) -> [Attribution] {
        let mounts = Set(topology.volumes(on: id).map(\.mountPoint))
        guard !mounts.isEmpty else { return [] }
        let rates = Dictionary(processRates(last: seconds).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Attribution] = []
        for (pid, files) in openFiles {
            let onDisk = files.filter { mounts.contains($0.mountPoint) }
            guard !onDisk.isEmpty, let rate = rates[pid] else { continue }
            out.append(Attribution(process: rate, files: onDisk))
        }
        return out.sorted { $0.process.bytesPerSec > $1.process.bytesPerSec }
    }
}

/// Summary of one disk over a window of ticks.
public struct DiskSummary: Sendable, Hashable {
    public var id: String
    public var ticks: Int
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double
    public var readOpsPerSec: Double
    public var writeOpsPerSec: Double
    public var serviceMsPerOp: Double
    public var latencyMsPerOp: Double
    public var queueDepth: Double
    /// Ticks during which the disk was busy more than half the time.
    public var busyTicks: Int
    /// Ticks with any completed write / read.
    public var writingTicks: Int
    public var readingTicks: Int
    public var maxWriteBytesInTick: Double

    public var bytesPerSec: Double { readBytesPerSec + writeBytesPerSec }
    public var opsPerSec: Double { readOpsPerSec + writeOpsPerSec }
    public var averageRequestBytes: Double { opsPerSec > 0 ? bytesPerSec / opsPerSec : 0 }
    public var busyFraction: Double { ticks > 0 ? Double(busyTicks) / Double(ticks) : 0 }
    public var idleTicks: Int { ticks - busyTicks }

    public init(rates: [DiskRate]) {
        id = rates.first?.id ?? ""
        ticks = rates.count
        let n = Double(max(1, rates.count))
        readBytesPerSec = rates.map(\.readBytesPerSec).reduce(0, +) / n
        writeBytesPerSec = rates.map(\.writeBytesPerSec).reduce(0, +) / n
        readOpsPerSec = rates.map(\.readOpsPerSec).reduce(0, +) / n
        writeOpsPerSec = rates.map(\.writeOpsPerSec).reduce(0, +) / n
        let ops = rates.map(\.opsPerSec).reduce(0, +)
        serviceMsPerOp = ops > 0 ? rates.map { $0.serviceMsPerOp * $0.opsPerSec }.reduce(0, +) / ops : 0
        latencyMsPerOp = ops > 0 ? rates.map { ($0.readMsPerOp * $0.readOpsPerSec + $0.writeMsPerOp * $0.writeOpsPerSec) }.reduce(0, +) / ops : 0
        queueDepth = rates.map(\.queueDepth).reduce(0, +) / n
        busyTicks = rates.filter { $0.busy > 0.5 }.count
        writingTicks = rates.filter { $0.writeOpsPerSec >= 1 }.count
        readingTicks = rates.filter { $0.readOpsPerSec >= 1 }.count
        maxWriteBytesInTick = rates.map { $0.writeBytesPerSec * $0.interval }.max() ?? 0
    }
}

// MARK: - M2 views over the window

public struct ProcessCPURate: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    /// Cores' worth of CPU time per second: 1.0 is one core fully busy.
    public var cores: Double
    public var footprintBytes: UInt64
}

public struct ProcessNetRate: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var inBytesPerSec: Double
    public var outBytesPerSec: Double
    public var bytesPerSec: Double { inBytesPerSec + outBytesPerSec }
}

extension Window {
    public var latestFrame: Frame? { frames.last }

    /// Per-tick rates of one interface over the last `seconds` frames.
    public func networkRates(interface name: String, last seconds: Int) -> [NetworkRate] {
        guard frames.count >= 2 else { return [] }
        var out: [NetworkRate] = []
        var previous: Frame?
        for f in frames.suffix(seconds + 1) {
            defer { previous = f }
            guard let p = previous,
                  let a = p.network?.first(where: { $0.name == name }),
                  let b = f.network?.first(where: { $0.name == name }) else { continue }
            if let r = NetworkRate.between(a, b, interval: f.timestamp.timeIntervalSince(p.timestamp)) { out.append(r) }
        }
        return out
    }

    public var interfaceNames: [String] { frames.last?.network?.map(\.name) ?? [] }

    public func latestNetworkRates() -> [NetworkRate] {
        interfaceNames.compactMap { networkRates(interface: $0, last: 1).last?.withLinkRate(wifi: latestWiFi) }
    }

    /// Average rate of an interface over a window.
    public func networkAverage(interface name: String, last seconds: Int) -> NetworkRate? {
        let rates = networkRates(interface: name, last: seconds)
        guard let first = rates.first else { return nil }
        let n = Double(rates.count)
        return NetworkRate(name: name, interval: rates.map(\.interval).reduce(0, +),
                           inBytesPerSec: rates.map(\.inBytesPerSec).reduce(0, +) / n,
                           outBytesPerSec: rates.map(\.outBytesPerSec).reduce(0, +) / n,
                           packetsPerSec: rates.map(\.packetsPerSec).reduce(0, +) / n,
                           errorsPerSec: rates.map(\.errorsPerSec).reduce(0, +) / n,
                           dropsPerSec: rates.map(\.dropsPerSec).reduce(0, +) / n,
                           baudrate: rates.last?.baudrate ?? first.baudrate).withLinkRate(wifi: latestWiFi)
    }

    public var latestWiFi: WiFiSample? { frames.last?.wifi }

    /// Per-tick CPU rates over the last `seconds` frames.
    public func cpuRates(last seconds: Int) -> [CPURate] {
        guard frames.count >= 2 else { return [] }
        var out: [CPURate] = []
        var previous: Frame?
        for f in frames.suffix(seconds + 1) {
            defer { previous = f }
            guard let p = previous, let a = p.cpu, let b = f.cpu, let r = CPURate.between(a, b) else { continue }
            out.append(r)
        }
        return out
    }

    /// Per-process CPU over the last `seconds` frames, heaviest first.
    public func processCPURates(last seconds: Int) -> [ProcessCPURate] {
        cache.get("cpu-\(seconds)") { computeProcessCPURates(last: seconds) }
    }

    private func computeProcessCPURates(last seconds: Int) -> [ProcessCPURate] {
        let slice = Array(frames.suffix(seconds + 1))
        guard let first = slice.first, let last = slice.last, first.timestamp < last.timestamp else { return [] }
        let dt = last.timestamp.timeIntervalSince(first.timestamp)
        let earliest = Dictionary(first.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return last.processes.compactMap { p -> ProcessCPURate? in
            guard let e = earliest[p.pid], p.cpuNs >= e.cpuNs else { return nil }
            return ProcessCPURate(pid: p.pid, name: p.name, bundleID: p.bundleID,
                                  cores: Double(p.cpuNs - e.cpuNs) / 1e9 / dt, footprintBytes: p.footprintBytes)
        }.sorted { $0.cores > $1.cores }
    }

    /// Per-process network over the last `seconds` frames, from the nettop listings in them.
    public func processNetRates(last seconds: Int) -> [ProcessNetRate] {
        let slice = frames.suffix(seconds + 1).filter { $0.processNet != nil }
        guard let first = slice.first, let last = slice.last, first.timestamp < last.timestamp,
              let a = first.processNet, let b = last.processNet else { return [] }
        let dt = last.timestamp.timeIntervalSince(first.timestamp)
        let start = Dictionary(a.map { ($0.pid, $0) }, uniquingKeysWith: { x, _ in x })
        return b.compactMap { p -> ProcessNetRate? in
            guard let s = start[p.pid] else { return nil }
            func d(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) : 0 }
            return ProcessNetRate(pid: p.pid, name: p.name, inBytesPerSec: d(s.bytesIn, p.bytesIn) / dt, outBytesPerSec: d(s.bytesOut, p.bytesOut) / dt)
        }.sorted { $0.bytesPerSec > $1.bytesPerSec }
    }

    /// Bytes per second by which the free space of a disk's volumes shrank
    /// over the last `seconds` frames; nil when no frame carries it.
    public func freeSpaceDrain(disk id: String, last seconds: Int) -> Double? {
        let mounts = topology.volumes(on: id).map(\.mountPoint)
        let slice = frames.suffix(seconds + 1).filter { $0.volumeFree != nil }
        guard mounts.count > 0, let first = slice.first, let last = slice.last, first.timestamp < last.timestamp,
              let a = first.volumeFree, let b = last.volumeFree else { return nil }
        var drained = 0.0
        for m in mounts {
            guard let x = a[m], let y = b[m] else { continue }
            drained += x > y ? Double(x - y) : 0
        }
        return drained / last.timestamp.timeIntervalSince(first.timestamp)
    }

    /// Latency samples for a target, oldest first, across the whole window.
    public func latencies(_ target: LatencySample.Target) -> [LatencySample] {
        frames.flatMap { $0.latency ?? [] }.filter { $0.target == target }
    }

    public var latestMemory: MemorySample? { frames.last?.memory }
    public var latestSystem: SystemSample? { frames.last?.system }

    /// Page-outs in bytes per second over the last `seconds` frames.
    public func pageOutRate(last seconds: Int) -> Double {
        let slice = Array(frames.suffix(seconds + 1))
        guard let a = slice.first?.memory, let b = slice.last?.memory, let t0 = slice.first?.timestamp, let t1 = slice.last?.timestamp, t1 > t0,
              b.pageOuts >= a.pageOuts else { return 0 }
        return Double(b.pageOuts - a.pageOuts) * Double(b.pageSize) / t1.timeIntervalSince(t0)
    }
}

/// Footprints sampled every 30 s for ten minutes, for the runaway-growth
/// rule; the one-minute window is too short for it.
public struct FootprintHistory: Sendable {
    public struct Point: Sendable, Hashable { public var at: Date; public var bytes: UInt64 }
    public private(set) var points: [Int32: [Point]] = [:]
    public private(set) var names: [Int32: String] = [:]
    private var lastSampled = Date.distantPast

    public init() {}

    public mutating func record(_ frame: Frame) {
        guard frame.timestamp.timeIntervalSince(lastSampled) >= 30 else { return }
        lastSampled = frame.timestamp
        let cutoff = frame.timestamp.addingTimeInterval(-600)
        var live = Set<Int32>()
        for p in frame.processes where p.footprintBytes > 0 {
            live.insert(p.pid)
            names[p.pid] = p.name
            points[p.pid, default: []].append(Point(at: frame.timestamp, bytes: p.footprintBytes))
            points[p.pid]?.removeAll { $0.at < cutoff }
        }
        points = points.filter { live.contains($0.key) }
        names = names.filter { live.contains($0.key) }
    }

    /// Processes whose footprint grew by at least `minGrowth` over the
    /// history without ever shrinking. Returns (pid, name, growth, span).
    public func runaways(minGrowth: UInt64) -> [(pid: Int32, name: String, growth: UInt64, span: TimeInterval)] {
        points.compactMap { pid, pts in
            guard pts.count >= 4, let first = pts.first, let last = pts.last, last.bytes > first.bytes else { return nil }
            let growth = last.bytes - first.bytes
            guard growth >= minGrowth else { return nil }
            for (a, b) in zip(pts, pts.dropFirst()) where b.bytes < a.bytes { return nil }
            return (pid, names[pid] ?? "pid \(pid)", growth, last.at.timeIntervalSince(first.at))
        }.sorted { $0.growth > $1.growth }
    }
}
