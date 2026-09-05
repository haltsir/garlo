import Testing
import Foundation
@testable import GarloCore

@Suite struct BaselineTests {
    func tempStore() throws -> RollupStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("garlo-tests-\(UUID().uuidString)")
        return try RollupStore(url: dir.appendingPathComponent("history.sqlite"))
    }

    @Test func rollupsRoundTripAndPrune() throws {
        let store = try tempStore()
        let now = Date()
        let rows = (0..<5).map { i in
            RollupStore.Row(minute: now.addingTimeInterval(Double(-i) * 60), resource: "disk:disk4", bytesPerSec: 1000 * Double(i), opsPerSec: 10, serviceMs: 9, busy: 0.5, peakBytesPerSec: 2000, samples: 60)
        }
        store.upsert(rows)
        #expect(store.rows(resource: "disk:disk4", from: now.addingTimeInterval(-3600), to: now).count == 5)
        #expect(store.resources(from: now.addingTimeInterval(-3600), to: now) == ["disk:disk4"])
        store.prune(olderThan: now.addingTimeInterval(-150))
        #expect(store.rows(resource: "disk:disk4", from: now.addingTimeInterval(-3600), to: now).count == 3)
    }

    @Test func baselineNeedsTenBusyMinutesAndUsesTheMedian() throws {
        let store = try tempStore()
        let disk = TransferCorrelationTests.storage
        let topo = Topology(disks: [disk], volumes: [])
        let now = Date()
        var rows: [RollupStore.Row] = []
        for i in 0..<9 {
            rows.append(RollupStore.Row(minute: now.addingTimeInterval(Double(-i - 1) * 60), resource: "disk:disk4", bytesPerSec: 50e6, opsPerSec: 100, serviceMs: Double(8 + i), busy: 0.9, peakBytesPerSec: 120e6, samples: 60))
        }
        store.upsert(rows)
        #expect(BaselineLearner.relearn(store: store, topology: topo, now: now).isEmpty)
        // a tenth busy minute, plus an outlier the median ignores
        store.upsert([RollupStore.Row(minute: now.addingTimeInterval(-600), resource: "disk:disk4", bytesPerSec: 50e6, opsPerSec: 100, serviceMs: 400, busy: 0.9, peakBytesPerSec: 120e6, samples: 60)])
        let learned = BaselineLearner.relearn(store: store, topology: topo, now: now)
        #expect(learned.count == 1)
        #expect(learned.first?.serviceMs == 13)
        #expect(learned.first?.readBytesPerSec == 120e6)
        #expect(store.baseline("disk:disk4")?.busySeconds == 600)
        // reset: nothing learned from the old rows any more
        BaselineLearner.reset(store: store, resource: "disk:disk4", now: now)
        #expect(BaselineLearner.relearn(store: store, topology: topo, now: now).isEmpty)
        #expect(store.baseline("disk:disk4")?.busySeconds == -1)
    }

    @Test @MainActor func deviceThreeTimesSlowerThanItsBaselineIsAFinding() {
        let disk = TransferCorrelationTests.storage
        let engine = Engine(rules: [DeviceSlowRule()], topology: Topology(disks: [disk], volumes: []), openAfter: 3, resolveAfter: 5)
        let baseline = RollupStore.Baseline(resource: "disk:disk4", serviceMs: 9, readBytesPerSec: 120e6, writeBytesPerSec: 100e6, linkBitsPerSec: 5e9, learnedAt: Date(), busySeconds: 1200)
        engine.setBaselines([baseline])
        var sample = DiskSample(id: "disk4", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<45 {
            // 30 writes per second, 30 ms each, about one at a time (no queueing to blame)
            sample.bytesWritten += 30 * 65536; sample.opsWritten += 30; sample.timeWriteNs += 30 * 30_000_000
            engine.evaluate(Frame(timestamp: t0.addingTimeInterval(Double(i)), disks: [sample], processes: []))
        }
        let f = engine.findings.first
        #expect(f?.verdict == "RAID Enclosure is slower than it used to be")
        #expect(f?.confidence == .confirmed)
        #expect(f?.actions.contains { $0.title == "Reset baseline" } == true)
    }

    @Test @MainActor func queueingDoesNotLookLikeASlowDevice() {
        let disk = TransferCorrelationTests.storage
        let engine = Engine(rules: [DeviceSlowRule()], topology: Topology(disks: [disk], volumes: []), openAfter: 3, resolveAfter: 5)
        engine.setBaselines([RollupStore.Baseline(resource: "disk:disk4", serviceMs: 9, readBytesPerSec: 120e6, writeBytesPerSec: 100e6, linkBitsPerSec: 5e9, learnedAt: Date(), busySeconds: 1200)])
        var sample = DiskSample(id: "disk4", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<45 {
            // 32-op bursts: 119 ms latency per write, but 32 in flight
            sample.bytesWritten += 100 * 65536; sample.opsWritten += 100; sample.timeWriteNs += 100 * 119_000_000
            engine.evaluate(Frame(timestamp: t0.addingTimeInterval(Double(i)), disks: [sample], processes: []))
        }
        #expect(engine.findings.isEmpty)
    }
}
