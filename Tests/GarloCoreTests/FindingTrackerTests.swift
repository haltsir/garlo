import Testing
import Foundation
@testable import GarloCore

@Suite struct FindingTrackerTests {
    func candidate(_ confirmed: Bool = false) -> Candidate {
        Candidate(rule: "r", subject: "s", domain: .storage, verdict: "v", cause: "c", severity: .slow,
                  confirmedBy: confirmed ? "x" : nil)
    }

    @Test func opensAfterConsecutiveTicks() {
        var t = FindingTracker(openAfter: 3, resolveAfter: 2)
        let d = Date()
        #expect(t.ingest([candidate()], at: d).isEmpty)
        #expect(t.ingest([candidate()], at: d).isEmpty)
        let e = t.ingest([candidate()], at: d)
        #expect(e.count == 1)
        if case .opened(let f) = e[0] { #expect(f.confidence == .suspected) } else { Issue.record("expected opened") }
    }

    @Test func gapResetsTheCount() {
        var t = FindingTracker(openAfter: 3, resolveAfter: 2)
        let d = Date()
        _ = t.ingest([candidate()], at: d)
        _ = t.ingest([candidate()], at: d)
        _ = t.ingest([], at: d)
        _ = t.ingest([candidate()], at: d)
        #expect(t.ingest([candidate()], at: d).isEmpty)
        #expect(t.ingest([candidate()], at: d).count == 1)
    }

    @Test func confirmsOnceAndResolvesAfterAbsence() {
        var t = FindingTracker(openAfter: 1, resolveAfter: 2)
        let d = Date()
        _ = t.ingest([candidate()], at: d)
        let e = t.ingest([candidate(true)], at: d)
        #expect(e.contains { if case .confirmed = $0 { true } else { false } })
        // confidence never drops back
        _ = t.ingest([candidate(false)], at: d)
        #expect(t.openFindings.first?.confidence == .confirmed)
        _ = t.ingest([], at: d)
        let r = t.ingest([], at: d)
        #expect(r.contains { if case .resolved = $0 { true } else { false } })
        #expect(t.openFindings.isEmpty)
        #expect(t.resolved.count == 1)
    }
}
