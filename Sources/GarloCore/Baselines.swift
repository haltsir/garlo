import Foundation

/// Learned per-device behaviour, so a slow enclosure is judged against
/// itself rather than a global constant.
public enum BaselineLearner {
    /// Busy minutes needed before a baseline exists: ten minutes of activity.
    public static let minimumBusyMinutes = 10
    public static let lookback: TimeInterval = 7 * 86400

    /// Recompute every disk's baseline from the last week of rollups.
    /// A reset marker (busySeconds == -1) restricts learning to rows after it.
    public static func relearn(store: RollupStore, topology: Topology, now: Date = Date()) -> [RollupStore.Baseline] {
        var learned: [RollupStore.Baseline] = []
        for disk in topology.disks {
            let key = "disk:\(disk.id)"
            let existing = store.baseline(key)
            let since = existing?.busySeconds == -1 ? existing!.learnedAt : now.addingTimeInterval(-lookback)
            let rows = store.rows(resource: key, from: since, to: now).filter { $0.opsPerSec >= 20 && $0.busy >= 0.3 && $0.serviceMs > 0 }
            guard rows.count >= minimumBusyMinutes else { continue }
            let services = rows.map(\.serviceMs).sorted()
            let all = store.rows(resource: key, from: since, to: now)
            let b = RollupStore.Baseline(
                resource: key,
                serviceMs: services[services.count / 2],
                readBytesPerSec: all.map(\.peakBytesPerSec).max() ?? 0,
                writeBytesPerSec: all.map(\.bytesPerSec).max() ?? 0,
                linkBitsPerSec: disk.usb?.speed.bitsPerSecond ?? 0,
                learnedAt: now,
                busySeconds: rows.count * 60)
            store.save(b)
            learned.append(b)
        }
        return learned
    }

    /// Forget a device's baseline; learning restarts from now.
    public static func reset(store: RollupStore, resource: String, now: Date = Date()) {
        store.save(RollupStore.Baseline(resource: resource, serviceMs: 0, readBytesPerSec: 0, writeBytesPerSec: 0, linkBitsPerSec: 0, learnedAt: now, busySeconds: -1))
    }
}

/// A device whose service time has risen well above its own baseline.
public struct DeviceSlowRule: Rule {
    public let id = "deviceslow"
    public static let factor = 3.0
    public static let window = 30
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        var out: [Candidate] = []
        for id in w.diskIDs {
            guard let b = w.baselines["disk:\(id)"], b.busySeconds > 0, b.serviceMs > 0 else { continue }
            let rates = w.rates(disk: id, last: Self.window)
            let busy = rates.filter { $0.opsPerSec >= 20 }
            guard rates.count >= 10, busy.count >= rates.count * 2 / 3 else { continue }
            let s = DiskSummary(rates: busy)
            guard s.serviceMsPerOp >= max(5, b.serviceMs * Self.factor) else { continue }
            let name = w.topology.displayName(forDisk: id)
            let sustained = busy.count >= Self.window * 2 / 3
            out.append(Candidate(
                rule: self.id, subject: name, domain: .storage,
                verdict: "\(name) is slower than it used to be",
                cause: "Requests take \(Units.ms(s.serviceMsPerOp)) each once queueing is taken out, against the \(Units.ms(b.serviceMs)) this device usually needs. The device, not the load, has changed.",
                evidence: [pad(name) + "\(Units.ms(s.serviceMsPerOp)) service · \(Units.ops(s.opsPerSec)) · depth \(String(format: "%.1f", s.queueDepth)) · \(busy.count) of \(rates.count) s",
                           pad("Baseline") + "\(Units.ms(b.serviceMs)) service · learned \(Units.clock(b.learnedAt)) from \(b.busySeconds / 60) busy min"],
                actions: [Action("Check the enclosure's health and cables", effect: "SMART arrives with the helper"),
                          Action("Reset baseline", effect: "if this is the new normal", kind: .resetBaseline(resource: "disk:\(id)"))],
                severity: .slow,
                confirmedBy: sustained ? "sustained \(Self.window) s against the learned baseline" : nil,
                pending: sustained ? nil : "waiting to see it persist for \(Self.window) s",
                tierHint: "Unified log flush stalls would corroborate this; that needs an admin account (tier 1)."
            ))
        }
        return out
    }
}
