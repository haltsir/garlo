import Foundation
import AppKit
import Observation
import GarloCore

struct Settings: Codable, Equatable {
    var notifyStorage = true
    var notifyNetwork = false
    var notifyCPU = false
    var notifyMemory = false
    var sendToVestitel = true
    var redactPaths = false
    var historyDays = 90
    var latencyAnchor = "one.one.one.one"
    var throughputURL = "https://speed.cloudflare.com/__down?bytes=200000000"
    var autoUpdateEnabled = true

    init() {}

    // Tolerant decoding: a new field must never lose the user's state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifyStorage = try c.decodeIfPresent(Bool.self, forKey: .notifyStorage) ?? true
        notifyNetwork = try c.decodeIfPresent(Bool.self, forKey: .notifyNetwork) ?? false
        notifyCPU = try c.decodeIfPresent(Bool.self, forKey: .notifyCPU) ?? false
        notifyMemory = try c.decodeIfPresent(Bool.self, forKey: .notifyMemory) ?? false
        sendToVestitel = try c.decodeIfPresent(Bool.self, forKey: .sendToVestitel) ?? true
        redactPaths = try c.decodeIfPresent(Bool.self, forKey: .redactPaths) ?? false
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? 90
        latencyAnchor = try c.decodeIfPresent(String.self, forKey: .latencyAnchor) ?? "one.one.one.one"
        throughputURL = try c.decodeIfPresent(String.self, forKey: .throughputURL) ?? "https://speed.cloudflare.com/__down?bytes=200000000"
        autoUpdateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
    }

    func notifies(_ domain: Domain) -> Bool {
        switch domain {
        case .storage, .fileLayout, .bus: return notifyStorage
        case .network: return notifyNetwork
        case .cpu, .thermal: return notifyCPU
        case .memory: return notifyMemory
        }
    }
}

struct PersistedState: Codable {
    var settings: Settings?
    var resolved: [Finding]?
    var lastUpdateCheck: Date?
    var lastRunVersion: String?
    var stagedUpdatePath: String?
    var stagedUpdateVersion: String?
}

/// The one observable object behind the UI. Owns the engine, settings,
/// persistence, notifications and every user action.
@Observable @MainActor
final class AppStore {
    let engine = Engine()
    var settings = Settings() {
        didSet {
            guard settings != oldValue else { return }
            engine.latencyAnchor = settings.latencyAnchor
            engine.retentionDays = settings.historyDays
            save()
        }
    }
    var popoverOpen = false {
        didSet {
            // a staged update installs the moment the popover closes
            if !popoverOpen, oldValue { installStagedUpdateIfIdle() }
        }
    }
    // Self-update state (Updater.swift)
    var updateStatus = ""
    var lastUpdateCheck: Date?
    var lastRunVersion: String?
    var stagedUpdatePath: String?
    var stagedUpdateVersion: String?
    var updaterTask: Task<Void, Never>?
    /// Resolved findings from earlier runs plus this one, newest first.
    private(set) var history: [Finding] = []
    var layoutSheet: LayoutRequest?
    var throughputRunning = false
    var lastThroughput: ThroughputTest.Result?

    struct LayoutRequest: Identifiable {
        var id: String { path }
        var path: String
        var layout: FileLayout?
        var done = false
    }

    static let stateDirectory: URL = {
        if let dir = ProcessInfo.processInfo.environment["GARLO_STATE_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Garlo", isDirectory: true)
    }()
    private var stateURL: URL { Self.stateDirectory.appendingPathComponent("state.json") }
    private var fixturesURL: URL { Self.stateDirectory.appendingPathComponent("Fixtures", isDirectory: true) }

    init() {
        load()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.store = try? RollupStore(url: Self.stateDirectory.appendingPathComponent("history.sqlite"))
        engine.retentionDays = settings.historyDays
        engine.latencyAnchor = settings.latencyAnchor
        engine.foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            Task { @MainActor in self?.engine.foregroundPID = pid }
        }
        engine.start()
        noteVersionChange()
        // housekeeping every 30 s: the daily update check and a staged install
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.maybeRunDailyUpdateCheck()
            }
        }
    }

    /// Persist without going through a settings change.
    func saveState() { save() }

    // MARK: Derived

    var openFindings: [Finding] { engine.findings.filter { !$0.markedWrong } }
    var notices: [Finding] { openFindings.filter { $0.severity == .notice } }
    var problems: [Finding] { openFindings.filter { $0.severity > .notice } }

    var iconState: MenuBarIcon.State {
        let confirmed = problems.filter { $0.confidence == .confirmed }
        if confirmed.contains(where: { $0.severity == .stalled }) { return .stalled }
        if !confirmed.isEmpty { return .slow }
        return .rest
    }

    /// Disks with traffic right now, for the Now section.
    var busyDisks: [DiskRate] {
        engine.latestRates.filter { $0.opsPerSec >= 5 || $0.bytesPerSec >= 500_000 }
            .sorted { $0.bytesPerSec > $1.bytesPerSec }
    }

    struct NowItem: Identifiable, Hashable {
        var id: String
        var name: String
        var figure: String
        var fraction: Double
        var label: String
        var hot: Bool
    }

    /// One row per busy resource: disks, the primary link, CPU, memory.
    var nowItems: [NowItem] {
        var items: [NowItem] = []
        let w = engine.window
        for r in busyDisks {
            let side = r.readBytesPerSec >= r.writeBytesPerSec ? "read \(Units.rate(r.readBytesPerSec))" : "write \(Units.rate(r.writeBytesPerSec))"
            items.append(NowItem(id: "disk-\(r.id)", name: engine.topology.displayName(forDisk: r.id),
                                 figure: "\(side) · \(Units.ops(r.opsPerSec)) · \(Units.ms(r.serviceMsPerOp))",
                                 fraction: r.busy,
                                 label: r.queueDepth >= 1.5 ? "queue \(Int(r.queueDepth))" : "busy \(Int(r.busy * 100))%",
                                 hot: r.busy > 0.8))
        }
        if let n = w.primaryRate, n.bytesPerSec >= 300_000 || (n.utilisation ?? 0) >= 0.1 {
            let util = n.utilisation ?? 0
            let side = n.outBytesPerSec >= n.inBytesPerSec ? "up \(Units.rate(n.outBytesPerSec))" : "down \(Units.rate(n.inBytesPerSec))"
            let top = w.processNetRates(last: 5).first.map { " · \($0.name)" } ?? ""
            items.append(NowItem(id: "net", name: w.interfaceLabel(n.name),
                                 figure: "\(side)\(top) · \(n.baudrate / 1_000_000) Mb/s link",
                                 fraction: util, label: "\(Int(util * 100))% of link", hot: util > 0.85))
        }
        if let c = w.cpuRates(last: 1).last, c.performanceUtilisation >= 0.5 || c.speedLimit < 100 {
            let top = w.groupedCPURates(last: 2).first.map { " · \($0.name) \(String(format: "%.1f", $0.cores))" } ?? ""
            items.append(NowItem(id: "cpu", name: "CPU",
                                 figure: "P \(Int(c.performanceUtilisation * 100))% · E \(Int(c.efficiencyUtilisation * 100))%\(top)",
                                 fraction: c.performanceUtilisation,
                                 label: c.speedLimit < 100 ? "limit \(c.speedLimit)%" : "busy \(Int(c.performanceUtilisation * 100))%",
                                 hot: c.performanceUtilisation >= 0.9 || c.speedLimit < 100))
        }
        if let m = w.latestMemory, m.pressure > .normal || w.pageOutRate(last: 5) > 0 {
            let out = w.pageOutRate(last: 5)
            items.append(NowItem(id: "mem", name: "Memory",
                                 figure: "\(m.pressure.rawValue) · swap \(Units.bytes(Double(m.swapUsedBytes))) · out \(Units.rate(out))",
                                 fraction: m.pressure == .critical ? 1 : (m.pressure == .warning ? 0.7 : 0.3),
                                 label: m.pressure.rawValue, hot: m.pressure >= .warning))
        }
        return items
    }

    var lastResolved: Finding? { history.first }

    // MARK: Events

    private func handle(_ event: FindingEvent) {
        switch event {
        case .confirmed(let f):
            guard f.mayNotify, settings.notifies(f.domain) else { return }
            Notifier.shared.post(f)
            if settings.sendToVestitel, f.isRedAlert { Vestitel.post(f, redact: settings.redactPaths) }
        case .resolved(let f):
            history.insert(f, at: 0)
            prune()
            save()
        case .opened, .updated:
            break
        }
    }

    // MARK: Actions

    func perform(_ action: Action, of finding: Finding) {
        switch action.kind {
        case .none:
            break
        case .openApp(let bundleID):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .revealFile(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .showLayout(let path):
            showLayout(path)
        case .openURL(let s):
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case .resetBaseline(let resource):
            engine.resetBaseline(resource)
        case .throughputTest:
            runThroughputTest()
        case .pickSource(let subject):
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = "Which file is being copied? Garlo will map its layout."
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                engine.pinSource(path: url.path, forSubject: subject)
                showLayout(url.path)
            }
        }
    }

    func runThroughputTest() {
        guard !throughputRunning, let url = URL(string: settings.throughputURL) ?? Optional(ThroughputTest.defaultURL) else { return }
        throughputRunning = true
        Task { [weak self] in
            guard let self else { return }
            let result = await engine.runThroughputTest(url: url)
            lastThroughput = result
            throughputRunning = false
        }
    }

    func showLayout(_ path: String) {
        if let known = engine.window.layouts[path], let l = known {
            layoutSheet = LayoutRequest(path: path, layout: l, done: true)
            return
        }
        layoutSheet = LayoutRequest(path: path, layout: nil, done: false)
        Task { [weak self] in
            let layout = await Task.detached(priority: .utility) { FileLayout.probe(path: path) }.value
            guard let self else { return }
            engine.setLayout(layout, for: path)
            if layoutSheet?.path == path { layoutSheet = LayoutRequest(path: path, layout: layout, done: true) }
        }
    }

    /// "Wrong": hide the finding and keep the window that produced it as a fixture.
    func markWrong(_ finding: Finding) {
        engine.markWrong(finding)
        let rec = Recording(note: "marked wrong by the user: \(finding.verdict)", topology: engine.topology,
                            frames: engine.window.frames, layouts: engine.window.layouts)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = fixturesURL.appendingPathComponent("\(stamp)-\(finding.rule).json")
        try? FileManager.default.createDirectory(at: fixturesURL, withIntermediateDirectories: true)
        try? rec.save(url)
    }

    func clearHistory() {
        history = []
        engine.store?.clearAll()
        engine.loadBaselines()
        save()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PersistedState.self, from: data) else { return }
        history = state.resolved ?? []
        lastUpdateCheck = state.lastUpdateCheck
        lastRunVersion = state.lastRunVersion
        stagedUpdatePath = state.stagedUpdatePath
        stagedUpdateVersion = state.stagedUpdateVersion
        prune()
        // settings last: its didSet saves
        settings = state.settings ?? Settings()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(PersistedState(settings: settings, resolved: history, lastUpdateCheck: lastUpdateCheck,
                                                            lastRunVersion: lastRunVersion, stagedUpdatePath: stagedUpdatePath,
                                                            stagedUpdateVersion: stagedUpdateVersion)) else { return }
        try? FileManager.default.createDirectory(at: Self.stateDirectory, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(settings.historyDays) * 86400)
        history.removeAll { ($0.ended ?? $0.lastSeen) < cutoff }
        if history.count > 2000 { history.removeLast(history.count - 2000) }
    }
}

// MARK: - Vestitel drop folder

/// Delivers a finding as an event to Vestitel's drop folder, so it lands in
/// an inbox instead of vanishing with the banner. Nothing is written when
/// Vestitel is not installed.
enum Vestitel {
    static var eventsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Vestitel/Events", isDirectory: true)
    }

    static func post(_ f: Finding, redact: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: eventsFolder.path, isDirectory: &isDir), isDir.boolValue else { return }
        var summary = f.cause
        if redact {
            for path in f.actions.compactMap({ a -> String? in
                if case .showLayout(let p) = a.kind { return p }
                if case .revealFile(let p) = a.kind { return p }
                return nil
            }) {
                summary = summary.replacingOccurrences(of: path, with: URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        let event: [String: Any] = [
            "source": "Garlo",
            "title": f.verdict,
            "summary": summary + (f.actions.first.map { " Try: \($0.title)." } ?? ""),
            "tag": f.severity.rawValue,
            "symbol": f.domain == .network ? "wifi" : "externaldrive",
            "id": "garlo-\(f.id.uuidString)",
            "published": ISO8601DateFormatter().string(from: f.started),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.prettyPrinted]) else { return }
        let url = eventsFolder.appendingPathComponent("garlo-\(f.id.uuidString).json")
        try? data.write(to: url, options: .atomic)
    }
}
