import Foundation
import Observation

/// Samplers at 1 Hz into a Window, rules over the Window, findings out.
/// Everything observable lives on the main actor; sampling runs detached
/// and must finish well under the 20 ms budget per tick.
@Observable @MainActor
public final class Engine {
    public private(set) var window: Window
    public private(set) var latestRates: [DiskRate] = []
    public private(set) var processRates: [ProcessRate] = []
    public private(set) var findings: [Finding] = []
    public private(set) var resolvedFindings: [Finding] = []
    public private(set) var isRunning = false
    public private(set) var tickCount = 0
    /// Wall time the last tick spent sampling, seconds.
    public private(set) var lastSampleCost: TimeInterval = 0
    public private(set) var overhead = Overhead(cpuFraction: 0, memoryBytes: 0)
    public var topology: Topology { window.topology }

    public var rules: [any Rule]
    public var onEvent: (@MainActor (FindingEvent) -> Void)?
    /// When set, every live frame is appended so the incident can be saved.
    public var recording: Recording?

    private var tracker: FindingTracker
    private var loop: Task<Void, Never>?
    private var lastTopologyRefresh = Date.distantPast
    private var openFilesRefreshed: [Int32: Date] = [:]
    private var layoutsInFlight: Set<String> = []
    private let processSampler = ProcessSampler()
    private var lastOverheadSample: (cpuNs: UInt64, at: Date)?
    private var lastNetProcessSample = Date.distantPast
    private var netProcessInFlight = false
    private var pendingProcessNet: [ProcessNetSample]?
    private var lastLatencyProbe = Date.distantPast
    private var lastDNSProbe = Date.distantPast
    private var dnsIndex = 0
    private var probeInFlight = false
    private var pendingLatency: [LatencySample] = []
    /// Set by the app from NSWorkspace; the core has no AppKit.
    public var foregroundPID: Int32?
    /// Host probed for round-trip time; nothing else leaves the Mac.
    public var latencyAnchor = "one.one.one.one"
    /// The privileged helper, when installed. Its snapshot rides the next
    /// frame so root processes get open files and counters like any other.
    public var helper: (any PrivilegedSource)? {
        didSet { window.helperAvailable = helper?.isAvailable ?? false }
    }
    private var helperInFlight = false
    private var lastHelperSnapshot = Date.distantPast
    private var pendingHelperSnapshot: HelperSnapshot?
    private var previousHelperProcesses: [Int32: ProcessSample] = [:]
    private var lastFileIO = Date.distantPast
    /// Minute rollups and baselines. Optional: the CLI runs without one.
    public var store: RollupStore? {
        didSet { loadBaselines() }
    }
    public var retentionDays = 90
    private var accumulator = RollupAccumulator()
    private var lastMaintenance = Date.distantPast

    public struct Overhead: Sendable, Hashable {
        public var cpuFraction: Double
        public var memoryBytes: UInt64
    }

    public init(rules: [any Rule] = AllRules.all, topology: Topology = Topology(), openAfter: Int = 10, resolveAfter: Int = 30) {
        self.rules = rules
        self.window = Window(topology: topology)
        self.tracker = FindingTracker(openAfter: openAfter, resolveAfter: resolveAfter)
    }

    // MARK: Live sampling

    public func start() {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    public func tick() async {
        let started = Date()
        if started.timeIntervalSince(lastTopologyRefresh) > 30 {
            lastTopologyRefresh = started
            let topo = await Task.detached(priority: .utility) { TopologySampler.sample() }.value
            window.topology = topo
        }
        let sampler = processSampler
        let sampled = await Task.detached(priority: .userInitiated) {
            (disks: DiskStatsSampler.sample(), procs: sampler.sample(), net: NetworkSampler.sample(),
             wifi: WiFiSampler.sample(), cpu: CPUSampler.sample(), memory: MemorySampler.sample(), system: SystemSampler.sample(),
             free: TopologySampler.freeSpace())
        }.value
        let disks = sampled.disks
        // Garlo never blames itself: its own probes and store writes are noise
        let own = getpid()
        var procs = sampled.procs.filter { $0.pid != own }
        if tickCount % 30 == 0 {
            window.primaryInterface = NetworkSampler.defaultRoute()?.interface
        }

        // open files for processes that are doing I/O, every 5 s per pid
        var openFiles: [Int32: [OpenFile]] = [:]
        if let last = window.frames.last {
            let dt = max(0.001, started.timeIntervalSince(last.timestamp))
            let previous = Dictionary(last.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            let busy = procs.filter { p in
                guard let e = previous[p.pid], let r = ProcessRate.between(e, p, interval: dt) else { return false }
                return r.bytesPerSec >= 1_000_000
            }
            let due = busy.filter { started.timeIntervalSince(openFilesRefreshed[$0.pid] ?? .distantPast) >= 5 }
            if !due.isEmpty {
                let topo = window.topology
                let pids = due.map(\.pid)
                for pid in pids { openFilesRefreshed[pid] = started }
                openFiles = await Task.detached(priority: .utility) {
                    var out: [Int32: [OpenFile]] = [:]
                    for pid in pids { out[pid] = sampler.openFiles(of: pid, topology: topo) }
                    return out
                }.value
            }
        }
        // per-process network bytes every 5 s while the link carries traffic;
        // nettop takes most of a second, so it lands in a later frame
        if !netProcessInFlight, started.timeIntervalSince(lastNetProcessSample) >= 5,
           let busyNet = window.latestNetworkRates().max(by: { $0.bytesPerSec < $1.bytesPerSec }), busyNet.bytesPerSec >= 500_000 {
            lastNetProcessSample = started
            netProcessInFlight = true
            Task { [weak self] in
                let listing = await Task.detached(priority: .utility) { NetProcessSampler.sample() }.value
                guard let self else { return }
                pendingProcessNet = listing
                netProcessInFlight = false
            }
        }
        let processNet = pendingProcessNet
        pendingProcessNet = nil
        lastSampleCost = Date().timeIntervalSince(started)

        let latency = pendingLatency
        pendingLatency = []
        // the helper's view of root processes merges into this frame
        if let snap = pendingHelperSnapshot {
            pendingHelperSnapshot = nil
            Self.merge(snap, into: &procs, openFiles: &openFiles, ownPID: own)
        }
        let frame = Frame(timestamp: started, disks: disks, processes: procs, openFiles: openFiles,
                          network: sampled.net, wifi: sampled.wifi, cpu: sampled.cpu, memory: sampled.memory,
                          system: sampled.system, processNet: processNet, latency: latency.isEmpty ? nil : latency,
                          foregroundPID: foregroundPID, volumeFree: sampled.free)
        recording?.frames.append(frame)
        evaluate(frame)
        probeLayoutsIfNeeded()
        probeLatencyIfDue(at: started)
        askHelperIfDue(at: started)
        sampleOverhead()
        rollup(at: started)
    }

    // MARK: Helper

    /// Processes the app could not see itself join the frame; a listing the
    /// app already has wins over the helper's.
    static func merge(_ snap: HelperSnapshot, into procs: inout [ProcessSample], openFiles: inout [Int32: [OpenFile]], ownPID: Int32) {
        let seen = Set(procs.map(\.pid))
        procs += snap.processes.filter { !seen.contains($0.pid) && $0.pid != ownPID }
        for (pid, files) in snap.openFiles where openFiles[pid] == nil && pid != ownPID { openFiles[pid] = files }
    }

    /// Every 5 s while a disk is busy or a storage finding is open, ask the
    /// helper what the app cannot see; every 30 s in that state, take a
    /// per-file I/O sample.
    private func askHelperIfDue(at now: Date) {
        guard let helper, helper.isAvailable, !helperInFlight else { return }
        window.helperAvailable = true
        let busy = latestRates.contains { $0.bytesPerSec >= StorageThresholds.transferReadBytesPerSec }
        let storageOpen = findings.contains { $0.domain == .storage || $0.domain == .bus }
        guard busy || storageOpen, now.timeIntervalSince(lastHelperSnapshot) >= 10 else { return }
        lastHelperSnapshot = now
        let wantFileIO = now.timeIntervalSince(lastFileIO) >= 30 && storageOpen
        if wantFileIO { lastFileIO = now }
        helperInFlight = true
        Task { [weak self] in
            let snap = await helper.snapshot()
            let io = wantFileIO ? await helper.fileIO(seconds: 5) : nil
            guard let self else { return }
            if let snap { pendingHelperSnapshot = snap }
            if let io { window.fileIO = io }
            helperInFlight = false
        }
    }

    // MARK: Rollups and baselines

    private func rollup(at date: Date) {
        guard let store else { return }
        let rows = accumulator.add(window, at: date)
        if !rows.isEmpty {
            let s = store
            Task.detached(priority: .utility) { s.upsert(rows) }
        }
        if date.timeIntervalSince(lastMaintenance) >= 3600 {
            lastMaintenance = date
            let s = store, topo = window.topology, days = retentionDays
            Task { [weak self] in
                let learned = await Task.detached(priority: .utility) { () -> [RollupStore.Baseline] in
                    s.prune(olderThan: date.addingTimeInterval(-Double(days) * 86400))
                    return BaselineLearner.relearn(store: s, topology: topo, now: date)
                }.value
                guard let self else { return }
                for b in learned { window.baselines[b.resource] = b }
            }
        }
    }

    public func loadBaselines() {
        guard let store else { window.baselines = [:]; return }
        window.baselines = Dictionary(store.allBaselines().map { ($0.resource, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Opt-in: a five-second download against the user's endpoint.
    public func runThroughputTest(url: URL) async -> ThroughputTest.Result {
        let result = await ThroughputTest.run(url: url)
        window.throughputTest = result
        return result
    }

    public func setBaselines(_ baselines: [RollupStore.Baseline]) {
        window.baselines = Dictionary(baselines.map { ($0.resource, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func resetBaseline(_ resource: String) {
        guard let store else { return }
        BaselineLearner.reset(store: store, resource: resource)
        loadBaselines()
    }

    // MARK: Latency probes

    /// Gateway and anchor every 30 s at rest, every 2 s while the link is
    /// busy or a network finding is open. DNS every 60 s. Results land in
    /// the next frame.
    private func probeLatencyIfDue(at now: Date) {
        guard !probeInFlight else { return }
        let busy = window.latestNetworkRates().contains { ($0.utilisation ?? 0) > 0.3 }
        let networkOpen = findings.contains { $0.domain == .network }
        let cadence: TimeInterval = (busy || networkOpen) ? 2 : 30
        let dueLatency = now.timeIntervalSince(lastLatencyProbe) >= cadence
        let dueDNS = now.timeIntervalSince(lastDNSProbe) >= 60
        guard dueLatency || dueDNS else { return }
        probeInFlight = true
        let gateway = NetworkSampler.defaultRoute()?.gateway ?? ""
        let anchor = latencyAnchor
        let dnsName = LatencyProbe.dnsNames[dnsIndex % LatencyProbe.dnsNames.count]
        if dueLatency { lastLatencyProbe = now }
        if dueDNS { lastDNSProbe = now; dnsIndex += 1 }
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) { () -> [LatencySample] in
                var out: [LatencySample] = []
                if dueLatency {
                    if !gateway.isEmpty { out.append(LatencySample(target: .gateway, milliseconds: LatencyProbe.connectTime(host: gateway, port: 80, timeoutMs: 1500))) }
                    if !anchor.isEmpty { out.append(LatencySample(target: .anchor, milliseconds: LatencyProbe.connectTime(host: anchor, port: 443))) }
                }
                if dueDNS { out.append(LatencySample(target: .dns, milliseconds: LatencyProbe.resolveTime(host: dnsName))) }
                return out
            }.value
            guard let self else { return }
            pendingLatency += results
            probeInFlight = false
        }
    }

    // MARK: Evaluation (shared by live and replay)

    /// Append a frame, run the rules, advance the finding lifecycle.
    @discardableResult
    public func evaluate(_ frame: Frame) -> [FindingEvent] {
        window.append(frame)
        latestRates = window.latestRates()
        processRates = window.processRates(last: 5)
        // rules run in order; each sees the disks earlier ones (and open
        // findings) already explain, so one incident stays one card
        var explained = Set(tracker.openFindings.flatMap(\.explainsDisks))
        var candidates: [Candidate] = []
        for rule in rules {
            window.explainedDisks = explained
            let found = rule.evaluate(window)
            candidates += found
            for c in found { explained.formUnion(c.explainsDisks) }
        }
        let events = tracker.ingest(candidates, at: frame.timestamp)
        findings = tracker.openFindings
        resolvedFindings = tracker.resolved
        tickCount += 1
        for e in events { onEvent?(e) }
        return events
    }

    public func setTopology(_ topology: Topology) {
        window.topology = topology
    }

    public func setPrimaryInterface(_ name: String?) {
        window.primaryInterface = name
    }

    /// "Pick the file": the user names the source of a transfer Garlo could
    /// not see behind a root copy helper. Its layout is probed at once.
    public func pinSource(path: String, forSubject subject: String) {
        guard let vol = window.topology.volume(containing: path) else { return }
        var size: UInt64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let n = attrs[.size] as? NSNumber { size = n.uint64Value }
        window.pinnedSources[subject] = OpenFile(path: path, mountPoint: vol.mountPoint, sizeBytes: size)
        guard window.layouts[path] == nil else { return }
        Task { [weak self] in
            let layout = await Task.detached(priority: .utility) { FileLayout.probe(path: path) }.value
            self?.setLayout(layout, for: path)
        }
    }

    public func setLayout(_ layout: FileLayout?, for path: String) {
        window.layouts[path] = layout
        recording?.layouts[path] = layout
    }

    public func markWrong(_ finding: Finding) {
        tracker.markWrong(id: finding.id)
        findings = tracker.openFindings
    }

    // MARK: Layout probing

    private func probeLayoutsIfNeeded() {
        guard layoutsInFlight.isEmpty else { return }
        let reading = Set(latestRates.filter { $0.readBytesPerSec >= StorageThresholds.transferReadBytesPerSec }.map(\.id))
        guard !reading.isEmpty else { return }
        let mounts = Set(reading.flatMap { window.topology.volumes(on: $0).map(\.mountPoint) })
        // the heaviest reader's largest file first: that is the one being copied
        let readRate = Dictionary(processRates.map { ($0.pid, $0.readBytesPerSec) }, uniquingKeysWith: { a, _ in a })
        var candidates: [(rate: Double, file: OpenFile)] = []
        for (pid, files) in window.openFiles {
            let rate = readRate[pid] ?? 0
            for f in files where mounts.contains(f.mountPoint) && f.sizeBytes >= StorageThresholds.layoutMinBytes && window.layouts[f.path] == nil {
                candidates.append((rate, f))
            }
        }
        candidates.sort { a, b in
            if a.rate != b.rate { return a.rate > b.rate }
            return a.file.sizeBytes > b.file.sizeBytes
        }
        guard let file = candidates.first?.file else { return }
        layoutsInFlight.insert(file.path)
        let path = file.path
        Task { [weak self] in
            let layout = await Task.detached(priority: .utility) { FileLayout.probe(path: path) }.value
            guard let self else { return }
            self.setLayout(layout, for: path)
            self.layoutsInFlight.remove(path)
        }
    }

    // MARK: Overhead

    private func sampleOverhead() {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let cpuNs = (info.ri_user_time + info.ri_system_time) * UInt64(tb.numer) / UInt64(max(1, tb.denom))
        let now = Date()
        if let last = lastOverheadSample {
            let dt = now.timeIntervalSince(last.at)
            if dt >= 10 {
                let fraction = Double(cpuNs - min(cpuNs, last.cpuNs)) / 1e9 / dt
                overhead = Overhead(cpuFraction: fraction, memoryBytes: info.ri_phys_footprint)
                lastOverheadSample = (cpuNs, now)
            }
        } else {
            lastOverheadSample = (cpuNs, now)
            overhead = Overhead(cpuFraction: 0, memoryBytes: info.ri_phys_footprint)
        }
    }
}

// MARK: - Fixtures

/// A recorded incident: topology, frames and probed layouts. Replayable
/// through the same rules that run live.
public struct Recording: Codable, Sendable {
    public var note: String
    public var recordedAt: Date
    public var topology: Topology
    public var frames: [Frame]
    public var layouts: [String: FileLayout?]

    public init(note: String = "", recordedAt: Date = Date(), topology: Topology, frames: [Frame] = [], layouts: [String: FileLayout?] = [:]) {
        self.note = note
        self.recordedAt = recordedAt
        self.topology = topology
        self.frames = frames
        self.layouts = layouts
    }

    /// Drop processes whose counters never moved during the recording and
    /// open-file listings of processes that are gone. Keeps fixtures small
    /// without changing what the rules see.
    public func compacted() -> Recording {
        guard let first = frames.first, let last = frames.last else { return self }
        let start = Dictionary(first.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var moved = Set<Int32>()
        for p in last.processes {
            if let s = start[p.pid], s.bytesRead == p.bytesRead, s.bytesWritten == p.bytesWritten,
               p.cpuNs < s.cpuNs + 50_000_000 { continue }
            moved.insert(p.pid)
        }
        // processes that came and went mid-recording
        for f in frames { for p in f.processes where start[p.pid] == nil { moved.insert(p.pid) } }
        for f in frames { for pid in f.openFiles.keys { moved.insert(pid) } }
        var out = self
        out.frames = frames.map { f in
            var g = f
            g.processes = f.processes.filter { moved.contains($0.pid) }
            return g
        }
        return out
    }

    public static func load(_ url: URL) throws -> Recording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Recording.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(compacted()).write(to: url)
    }

    /// Run the recording through an engine and collect every event.
    @MainActor
    public func replay(rules: [any Rule] = AllRules.all, openAfter: Int = 10, resolveAfter: Int = 30) -> (engine: Engine, events: [FindingEvent]) {
        let engine = Engine(rules: rules, topology: topology, openAfter: openAfter, resolveAfter: resolveAfter)
        for (path, layout) in layouts { engine.setLayout(layout, for: path) }
        var events: [FindingEvent] = []
        for f in frames { events += engine.evaluate(f) }
        return (engine, events)
    }
}
