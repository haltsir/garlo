import Foundation

public enum Domain: String, Codable, Sendable, CaseIterable {
    case storage, fileLayout, bus, network, cpu, memory, thermal

    public var label: String {
        switch self {
        case .storage: return "Storage"
        case .fileLayout: return "File layout"
        case .bus: return "Bus"
        case .network: return "Network"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .thermal: return "Thermal"
        }
    }
}

public enum Severity: String, Codable, Sendable, Comparable {
    case notice, slow, stalled
    private var rank: Int { switch self { case .notice: 0; case .slow: 1; case .stalled: 2 } }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public enum Confidence: String, Codable, Sendable {
    case suspected, confirmed
}

/// What the user can do about a finding, with the effect Garlo expects.
public struct Action: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        case none
        case openApp(bundleID: String)
        case revealFile(path: String)
        case showLayout(path: String)
        case openURL(String)
        case pickSource(subject: String)
        case resetBaseline(resource: String)
        case throughputTest
        case installHelper
    }
    public var id: String { title }
    public var title: String
    public var effect: String?
    public var kind: Kind

    public init(_ title: String, effect: String? = nil, kind: Kind = .none) {
        self.title = title
        self.effect = effect
        self.kind = kind
    }
}

/// A process or condition adding to the problem.
public struct Contributor: Codable, Sendable, Hashable {
    public var name: String
    public var detail: String
    public var bundleID: String?

    public init(name: String, detail: String, bundleID: String? = nil) {
        self.name = name
        self.detail = detail
        self.bundleID = bundleID
    }
}

/// What a rule proposes on one tick. The engine turns a run of candidates
/// with the same key into a finding with a lifecycle.
public struct Candidate: Sendable {
    public var rule: String
    public var key: String            // rule + subject, stable across ticks
    public var domain: Domain
    public var subject: String
    public var verdict: String
    public var cause: String
    public var contributors: [Contributor]
    public var evidence: [String]
    public var actions: [Action]
    public var severity: Severity
    public var confirmedBy: String?   // nil while only suspected
    public var pending: String?       // what Garlo is waiting for, when unsure
    public var tierHint: String?
    /// Disk ids this candidate explains; standalone rules stay quiet about them.
    public var explainsDisks: [String]

    public init(rule: String, subject: String, domain: Domain, verdict: String, cause: String,
                contributors: [Contributor] = [], evidence: [String] = [], actions: [Action] = [],
                severity: Severity, confirmedBy: String? = nil, pending: String? = nil, tierHint: String? = nil,
                explainsDisks: [String] = []) {
        self.rule = rule
        self.key = rule + "|" + subject
        self.domain = domain
        self.subject = subject
        self.verdict = verdict
        self.cause = cause
        self.contributors = contributors
        self.evidence = evidence
        self.actions = actions
        self.severity = severity
        self.confirmedBy = confirmedBy
        self.pending = pending
        self.tierHint = tierHint
        self.explainsDisks = explainsDisks
    }
}

/// The unit of everything Garlo shows, stores and sends.
public struct Finding: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var rule: String
    public var key: String
    public var domain: Domain
    public var subject: String
    public var verdict: String
    public var cause: String
    public var contributors: [Contributor]
    public var evidence: [String]
    public var actions: [Action]
    public var severity: Severity
    public var confidence: Confidence
    public var confirmedBy: String?
    public var pending: String?
    public var tierHint: String?
    public var explainsDisks: [String]
    public var started: Date
    public var lastSeen: Date
    public var ended: Date?
    /// User pressed "wrong": kept for the fixture, hidden from the popover.
    public var markedWrong: Bool

    public var isOpen: Bool { ended == nil }
    /// Only confirmed slow or stalled findings may notify.
    public var mayNotify: Bool { confidence == .confirmed && severity >= .slow }
    /// Red alerts: stalled, or hardware that looks like it is failing.
    /// These are the only findings that go to Vestitel.
    public var isRedAlert: Bool { confidence == .confirmed && (severity == .stalled || rule == "deviceslow") }

    /// The id a red alert carries into Vestitel: rule, subject and the day it
    /// started, never the finding's own UUID. A finding that flaps (device
    /// slow while a copy pauses and resumes) re-opens with a new UUID each
    /// time; Vestitel dedupes on the id, so one incident per day is one event.
    public func alertID(timeZone: TimeZone = .current) -> String {
        let slug = subject.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let d = cal.dateComponents([.year, .month, .day], from: started)
        return String(format: "garlo-%@-%@-%04d-%02d-%02d", rule, slug, d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    init(candidate c: Candidate, at date: Date) {
        id = UUID()
        rule = c.rule
        key = c.key
        domain = c.domain
        subject = c.subject
        verdict = c.verdict
        cause = c.cause
        contributors = c.contributors
        evidence = c.evidence
        actions = c.actions
        severity = c.severity
        confidence = c.confirmedBy == nil ? .suspected : .confirmed
        confirmedBy = c.confirmedBy
        pending = c.pending
        tierHint = c.tierHint
        explainsDisks = c.explainsDisks
        started = date
        lastSeen = date
        ended = nil
        markedWrong = false
    }

    /// Merge a fresh candidate for the same key: text and numbers update,
    /// confidence only ratchets up, severity follows the rule.
    mutating func merge(_ c: Candidate, at date: Date) {
        verdict = c.verdict
        cause = c.cause
        contributors = c.contributors
        evidence = c.evidence
        actions = c.actions
        severity = c.severity
        pending = c.pending
        tierHint = c.tierHint
        explainsDisks = c.explainsDisks
        if let by = c.confirmedBy {
            confidence = .confirmed
            confirmedBy = by
        }
        lastSeen = date
    }
}

/// Something the engine reports upward when a finding changes state.
public enum FindingEvent: Sendable, Hashable {
    case opened(Finding)
    case confirmed(Finding)
    case updated(Finding)
    case resolved(Finding)
}

/// Opens, confirms, merges and resolves findings from per-tick candidates.
///
/// - opens as suspected after `openAfter` consecutive ticks with the key present
/// - confirmed the first tick a candidate carries `confirmedBy`
/// - resolved after `resolveAfter` consecutive ticks without the key
public struct FindingTracker: Sendable {
    public var openAfter: Int
    public var resolveAfter: Int
    public private(set) var open: [String: Finding] = [:]
    public private(set) var resolved: [Finding] = []
    private var pendingCounts: [String: Int] = [:]
    private var missingCounts: [String: Int] = [:]

    public init(openAfter: Int = 10, resolveAfter: Int = 30) {
        self.openAfter = openAfter
        self.resolveAfter = resolveAfter
    }

    public var openFindings: [Finding] {
        open.values.sorted { $0.started > $1.started }
    }

    @discardableResult
    public mutating func ingest(_ candidates: [Candidate], at date: Date) -> [FindingEvent] {
        var events: [FindingEvent] = []
        let present = Dictionary(candidates.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        for (key, c) in present {
            missingCounts[key] = 0
            if var f = open[key] {
                let wasConfirmed = f.confidence == .confirmed
                f.merge(c, at: date)
                open[key] = f
                if !wasConfirmed && f.confidence == .confirmed {
                    events.append(.confirmed(f))
                } else {
                    events.append(.updated(f))
                }
            } else {
                let n = (pendingCounts[key] ?? 0) + 1
                pendingCounts[key] = n
                if n >= openAfter {
                    let f = Finding(candidate: c, at: date)
                    open[key] = f
                    pendingCounts[key] = nil
                    events.append(.opened(f))
                    if f.confidence == .confirmed { events.append(.confirmed(f)) }
                }
            }
        }

        for key in Array(pendingCounts.keys) where present[key] == nil {
            pendingCounts[key] = nil
        }
        for key in Array(open.keys) where present[key] == nil {
            let n = (missingCounts[key] ?? 0) + 1
            missingCounts[key] = n
            if n >= resolveAfter, var f = open[key] {
                f.ended = date
                open[key] = nil
                missingCounts[key] = nil
                resolved.append(f)
                events.append(.resolved(f))
            }
        }
        return events
    }

    public mutating func markWrong(id: UUID) {
        for (k, var f) in open where f.id == id {
            f.markedWrong = true
            open[k] = f
        }
    }

    public mutating func restore(open: [Finding], resolved: [Finding]) {
        self.open = Dictionary(open.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        self.resolved = resolved
    }
}
