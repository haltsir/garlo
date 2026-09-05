import Foundation
import SQLite3

/// One-minute rollups of every resource's primary metrics, kept for the
/// configured number of days, plus the learned per-device baselines.
/// SQLite, one file, no dependencies.
public final class RollupStore: @unchecked Sendable {
    public struct Row: Sendable, Hashable, Codable {
        public var minute: Date
        public var resource: String       // "disk:disk4", "net:en1", "cpu", "memory", "thermal"
        public var bytesPerSec: Double    // disks: read+write; net: in+out
        public var opsPerSec: Double
        public var serviceMs: Double      // disks: service time; net: gateway latency; cpu: speed limit
        public var busy: Double           // 0 to 1: disk busy, link utilisation, P-core utilisation, memory pressure level
        public var peakBytesPerSec: Double
        public var samples: Int
    }

    public struct Baseline: Sendable, Hashable, Codable {
        public var resource: String
        public var serviceMs: Double       // median service time when busy
        public var readBytesPerSec: Double // best sustained minute
        public var writeBytesPerSec: Double
        public var linkBitsPerSec: Double
        public var learnedAt: Date
        public var busySeconds: Int
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure.open(String(cString: sqlite3_errmsg(db))) }
        try exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS rollups (
            minute INTEGER NOT NULL, resource TEXT NOT NULL,
            bytes REAL, ops REAL, service REAL, busy REAL, peak REAL, samples INTEGER,
            PRIMARY KEY (minute, resource));
        CREATE TABLE IF NOT EXISTS baselines (
            resource TEXT PRIMARY KEY, service REAL, rbytes REAL, wbytes REAL, link REAL, learned INTEGER, busy INTEGER);
        """)
    }

    deinit { sqlite3_close(db) }

    public enum Failure: Error { case open(String), sql(String) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw Failure.sql(msg)
        }
    }

    // MARK: Rollups

    public func upsert(_ rows: [Row]) {
        guard !rows.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO rollups (minute, resource, bytes, ops, service, busy, peak, samples) VALUES (?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for r in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, Int64(r.minute.timeIntervalSince1970))
            sqlite3_bind_text(stmt, 2, r.resource, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 3, r.bytesPerSec)
            sqlite3_bind_double(stmt, 4, r.opsPerSec)
            sqlite3_bind_double(stmt, 5, r.serviceMs)
            sqlite3_bind_double(stmt, 6, r.busy)
            sqlite3_bind_double(stmt, 7, r.peakBytesPerSec)
            sqlite3_bind_int(stmt, 8, Int32(r.samples))
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Rows for one resource between two dates, oldest first.
    public func rows(resource: String, from: Date, to: Date) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "SELECT minute, bytes, ops, service, busy, peak, samples FROM rollups WHERE resource = ? AND minute >= ? AND minute <= ? ORDER BY minute"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, resource, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 3, Int64(to.timeIntervalSince1970))
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Row(minute: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))), resource: resource,
                           bytesPerSec: sqlite3_column_double(stmt, 1), opsPerSec: sqlite3_column_double(stmt, 2),
                           serviceMs: sqlite3_column_double(stmt, 3), busy: sqlite3_column_double(stmt, 4),
                           peakBytesPerSec: sqlite3_column_double(stmt, 5), samples: Int(sqlite3_column_int(stmt, 6))))
        }
        return out
    }

    /// Every resource that has rows in the range.
    public func resources(from: Date, to: Date) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT resource FROM rollups WHERE minute >= ? AND minute <= ? ORDER BY resource", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    public func prune(olderThan date: Date) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM rollups WHERE minute < ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSince1970))
        sqlite3_step(stmt)
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        try? exec("DELETE FROM rollups; DELETE FROM baselines;")
    }

    // MARK: Baselines

    public func baseline(_ resource: String) -> Baseline? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT service, rbytes, wbytes, link, learned, busy FROM baselines WHERE resource = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, resource, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Baseline(resource: resource, serviceMs: sqlite3_column_double(stmt, 0),
                        readBytesPerSec: sqlite3_column_double(stmt, 1), writeBytesPerSec: sqlite3_column_double(stmt, 2),
                        linkBitsPerSec: sqlite3_column_double(stmt, 3),
                        learnedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4))),
                        busySeconds: Int(sqlite3_column_int(stmt, 5)))
    }

    public func allBaselines() -> [Baseline] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT resource, service, rbytes, wbytes, link, learned, busy FROM baselines", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Baseline] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            out.append(Baseline(resource: String(cString: c), serviceMs: sqlite3_column_double(stmt, 1),
                                readBytesPerSec: sqlite3_column_double(stmt, 2), writeBytesPerSec: sqlite3_column_double(stmt, 3),
                                linkBitsPerSec: sqlite3_column_double(stmt, 4),
                                learnedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5))),
                                busySeconds: Int(sqlite3_column_int(stmt, 6))))
        }
        return out
    }

    public func save(_ b: Baseline) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO baselines (resource, service, rbytes, wbytes, link, learned, busy) VALUES (?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, b.resource, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, b.serviceMs)
        sqlite3_bind_double(stmt, 3, b.readBytesPerSec)
        sqlite3_bind_double(stmt, 4, b.writeBytesPerSec)
        sqlite3_bind_double(stmt, 5, b.linkBitsPerSec)
        sqlite3_bind_int64(stmt, 6, Int64(b.learnedAt.timeIntervalSince1970))
        sqlite3_bind_int(stmt, 7, Int32(b.busySeconds))
        sqlite3_step(stmt)
    }

    public func deleteBaseline(_ resource: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM baselines WHERE resource = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, resource, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }
}

// MARK: - Accumulating a minute

/// Folds per-second rates into the current minute's rows.
public struct RollupAccumulator: Sendable {
    private struct Acc { var bytes = 0.0, ops = 0.0, service = 0.0, busy = 0.0, peak = 0.0, n = 0 }
    private var minute: Date?
    private var acc: [String: Acc] = [:]

    public init() {}

    /// Add one tick. Returns completed rows when the minute rolls over.
    public mutating func add(_ w: Window, at date: Date) -> [RollupStore.Row] {
        let m = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
        var done: [RollupStore.Row] = []
        if let current = minute, current != m {
            done = flush(current)
            acc = [:]
        }
        minute = m
        for r in w.latestRates() {
            var a = acc["disk:\(r.id)", default: Acc()]
            a.bytes += r.bytesPerSec; a.ops += r.opsPerSec; a.service += r.serviceMsPerOp * r.opsPerSec; a.busy += r.busy
            a.peak = max(a.peak, r.bytesPerSec); a.n += 1
            acc["disk:\(r.id)"] = a
        }
        for r in w.latestNetworkRates() where r.bytesPerSec > 0 || r.name == w.primaryInterface {
            var a = acc["net:\(r.name)", default: Acc()]
            a.bytes += r.bytesPerSec; a.ops += r.packetsPerSec; a.busy += r.utilisation ?? 0
            a.service += w.latencies(.gateway).last?.milliseconds ?? 0
            a.peak = max(a.peak, r.bytesPerSec); a.n += 1
            acc["net:\(r.name)"] = a
        }
        if let c = w.cpuRates(last: 1).last {
            var a = acc["cpu", default: Acc()]
            a.busy += c.performanceUtilisation; a.ops += c.efficiencyUtilisation; a.service += Double(c.speedLimit); a.n += 1
            acc["cpu"] = a
        }
        if let m = w.latestMemory {
            var a = acc["memory", default: Acc()]
            a.busy += m.pressure == .critical ? 1 : (m.pressure == .warning ? 0.5 : 0)
            a.bytes += w.pageOutRate(last: 1); a.ops += Double(m.compressorBytes); a.n += 1
            acc["memory"] = a
        }
        if let s = w.latestSystem {
            var a = acc["thermal", default: Acc()]
            a.busy += s.thermal == .nominal ? 0 : (s.thermal == .fair ? 0.33 : (s.thermal == .serious ? 0.66 : 1))
            a.ops += Double(s.gpuUtilization ?? 0); a.n += 1
            acc["thermal"] = a
        }
        return done
    }

    private func flush(_ minute: Date) -> [RollupStore.Row] {
        acc.compactMap { key, a in
            guard a.n > 0 else { return nil }
            let n = Double(a.n)
            // service time is ops-weighted for disks, a plain mean elsewhere
            let service = key.hasPrefix("disk:") ? (a.ops > 0 ? a.service / a.ops : 0) : a.service / n
            return RollupStore.Row(minute: minute, resource: key, bytesPerSec: a.bytes / n, opsPerSec: a.ops / n,
                                   serviceMs: service, busy: a.busy / n, peakBytesPerSec: a.peak, samples: a.n)
        }
    }
}
