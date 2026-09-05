import Testing
import Foundation
@testable import GarloCore

/// Every rule ships with a fixture recorded from a real machine. These
/// tests replay them and check the verdict, not the numbers.
@Suite struct FixtureTests {
    func fixture(_ name: String) throws -> Recording {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Recording.load(url)
    }

    @Test @MainActor func copyFromFragmentedStorageIsReadBound() throws {
        let rec = try fixture("copy-archive-to-boot")
        let (engine, events) = rec.replay()
        let opened = events.compactMap { if case .opened(let f) = $0 { f } else { nil } }
        let transfer = try #require(opened.first { $0.rule == "transfer" })
        #expect(transfer.verdict == "Copy is read-bound")
        #expect(transfer.severity == .slow)
        #expect(transfer.subject == "Archive to Boot disk")
        #expect(transfer.contributors.contains { $0.name == "Torrent" })
        #expect(transfer.actions.contains { $0.title == "Pause Torrent" })
        // the source file is cp's, not the largest thing Torrent has open
        if case .showLayout(let path)? = transfer.actions.first(where: { if case .showLayout = $0.kind { true } else { false } })?.kind {
            // the fixture is anonymised: the copied file keeps its volume and extension
            #expect(path.hasSuffix(".mkv"))
            #expect(path.hasPrefix("/Volumes/Archive/"))
        } else {
            Issue.record("expected a Show file layout action")
        }
        // confirmed by the second signal before the recording ends
        let final = try #require(engine.findings.first { $0.rule == "transfer" })
        #expect(final.confidence == .confirmed)
        // the standalone rules stay quiet about disks the transfer already explains
        #expect(!engine.findings.contains { $0.rule == "iops" || $0.rule == "contention" })
    }

    @Test @MainActor func nearlyFullVolumeIsANotice() throws {
        let rec = try fixture("copy-archive-to-boot")
        let (engine, _) = rec.replay()
        let full = try #require(engine.findings.first { $0.rule == "full" })
        #expect(full.severity == .notice)
        #expect(full.subject == "Archive")
    }
}

@Suite struct CPUFixtureTests {
    @Test @MainActor func tenBusyLoopsSaturateThePerformanceCores() throws {
        let url = try #require(Bundle.module.url(forResource: "cpu-saturated", withExtension: "json", subdirectory: "Fixtures"))
        let rec = try Recording.load(url)
        let (engine, events) = rec.replay()
        let opened = events.compactMap { if case .opened(let f) = $0 { f } else { nil } }
        let cpu = try #require(opened.first { $0.rule == "cpu" })
        #expect(cpu.verdict == "yes (10 processes) is using all performance cores")
        #expect(cpu.contributors.first?.name == "yes (10 processes)")
        let final = try #require(engine.findings.first { $0.rule == "cpu" })
        #expect(final.confidence == .confirmed)
        // nothing else about the CPU
        #expect(!engine.findings.contains { $0.rule == "throttle" || $0.rule == "singlethread" })
    }
}
