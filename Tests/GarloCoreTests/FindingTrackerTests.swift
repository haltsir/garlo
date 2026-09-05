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

@Suite struct AlertIDTests {
    @Test func alertIDIsStableAcrossReopensWithinADay() {
        let started = Date(timeIntervalSince1970: 1_788_000_000) // 2026-08-29 10:40 UTC
        let utc = TimeZone(identifier: "UTC")!
        let c = Candidate(rule: "deviceslow", subject: "Storage", domain: .storage, verdict: "Storage is slower than it used to be",
                          cause: "", severity: .slow, confirmedBy: "sustained 30 s")
        let first = Finding(candidate: c, at: started)
        let again = Finding(candidate: c, at: started.addingTimeInterval(20 * 60))
        #expect(first.id != again.id)
        #expect(first.alertID(timeZone: utc) == again.alertID(timeZone: utc))
        #expect(first.alertID(timeZone: utc) == "garlo-deviceslow-storage-2026-08-29")
        // the next day is a new event; a subject with spaces and punctuation slugs cleanly
        let tomorrow = Finding(candidate: c, at: started.addingTimeInterval(86_400))
        #expect(tomorrow.alertID(timeZone: utc) == "garlo-deviceslow-storage-2026-08-30")
        let copy = Finding(candidate: Candidate(rule: "transfer", subject: "WD Elements 2620 to Boot disk", domain: .storage,
                                                verdict: "", cause: "", severity: .stalled, confirmedBy: "x"), at: started)
        #expect(copy.alertID(timeZone: utc) == "garlo-transfer-wd-elements-2620-to-boot-disk-2026-08-29")
    }
}
