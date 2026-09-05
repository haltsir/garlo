import Foundation

// MARK: - Types shared by the app, the engine and the privileged helper

/// What the helper can see that the app cannot: every process's I/O counters
/// and open files, root ones included (Finder's copy helper, ddrescue).
public struct HelperSnapshot: Codable, Sendable {
    public var takenAt: Date
    public var processes: [ProcessSample]
    public var openFiles: [Int32: [OpenFile]]
    public init(takenAt: Date, processes: [ProcessSample], openFiles: [Int32: [OpenFile]]) {
        self.takenAt = takenAt
        self.processes = processes
        self.openFiles = openFiles
    }
}

/// Bytes moved per process per file over a sampling window (the fs_usage
/// view, from kdebug through the helper).
public struct FileIOSample: Codable, Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var path: String
    public var readBytes: UInt64
    public var writeBytes: UInt64
    public var reads: Int
    public var writes: Int
    public init(pid: Int32, name: String, path: String, readBytes: UInt64, writeBytes: UInt64, reads: Int, writes: Int) {
        self.pid = pid; self.name = name; self.path = path
        self.readBytes = readBytes; self.writeBytes = writeBytes; self.reads = reads; self.writes = writes
    }
}

public struct FileIOReport: Codable, Sendable {
    public var seconds: Double
    public var samples: [FileIOSample]
    /// Non-nil when the tool's output could not be read; the app says so.
    public var problem: String?
    public init(seconds: Double, samples: [FileIOSample], problem: String? = nil) {
        self.seconds = seconds; self.samples = samples; self.problem = problem
    }
}

public struct SMARTReport: Codable, Sendable, Hashable {
    public var diskID: String
    /// "Verified", "Failing", or nil when the bridge does not pass SMART through.
    public var status: String?
    public var detail: String
    public init(diskID: String, status: String?, detail: String) {
        self.diskID = diskID; self.status = status; self.detail = detail
    }
}

/// The app's view of the helper. The engine only needs these three calls.
public protocol PrivilegedSource: Sendable {
    var isAvailable: Bool { get }
    func snapshot() async -> HelperSnapshot?
    func fileIO(seconds: Int) async -> FileIOReport?
    func smart(diskID: String) async -> SMARTReport?
}

/// The Mach service name and the launchd plist the daemon registers under.
public enum HelperIdentity {
    public static let machService = "com.strahil.garlo.helper"
    public static let plistName = "com.strahil.garlo.helper.plist"
    public static let protocolVersion = 1
    /// Only the signed app may talk to the daemon.
    public static let clientRequirement = "identifier \"com.strahil.garlo\" and certificate leaf[subject.CN] = \"Garlo Signing\""
}

// MARK: - Work the helper does (root-only samplers, reused by tests)

public enum HelperWork {
    /// The processes the client cannot inspect itself (other users' and
    /// root's) that have moved data, with the open files of those moving
    /// now. Everything the client can see is left out: it is already sampled
    /// there, and shipping the whole process table every few seconds is what
    /// the budget cannot afford.
    public static func snapshot(topology: Topology, previous: [Int32: ProcessSample], interval: TimeInterval, clientUID: uid_t) -> HelperSnapshot {
        let sampler = ProcessSampler()
        let procs = sampler.sample().filter { p in
            guard let uid = ProcessSampler.uid(of: p.pid), uid != clientUID else { return false }
            return p.bytesRead + p.bytesWritten > 0
        }
        var files: [Int32: [OpenFile]] = [:]
        for p in procs {
            let moving: Bool = {
                guard let e = previous[p.pid], interval > 0 else { return p.bytesRead + p.bytesWritten > 0 && previous.isEmpty }
                return ProcessRate.between(e, p, interval: interval).map { $0.bytesPerSec >= 500_000 } ?? false
            }()
            guard moving else { continue }
            let list = sampler.openFiles(of: p.pid, topology: topology)
            if !list.isEmpty { files[p.pid] = list }
        }
        return HelperSnapshot(takenAt: Date(), processes: procs, openFiles: files)
    }

    /// Run fs_usage for a few seconds and fold its file-system events into
    /// per-process per-file byte counts. The output format is not a contract;
    /// anything unparseable is skipped, and a failed run says so.
    public static func fileIO(seconds: Int) -> FileIOReport {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/fs_usage")
        p.arguments = ["-w", "-f", "filesys", "-t", String(max(1, min(seconds, 60)))]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return FileIOReport(seconds: 0, samples: [], problem: "fs_usage did not start: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return FileIOReport(seconds: Double(seconds), samples: [], problem: "fs_usage output unreadable") }
        return FileIOReport(seconds: Double(seconds), samples: parseFSUsage(text), problem: p.terminationStatus == 0 ? nil : "fs_usage exited with \(p.terminationStatus)")
    }

    /// Lines look like:
    ///   18:05:01.123456  RdData[A]   D=0x01c5f2e0  B=0x20000  /dev/disk4s2  /Volumes/X/file.mkv  0.000123 W  cp.85879
    ///   18:05:01.123456  read  F=5  B=0x1000  0.000010  Folx.64026
    /// Bytes come from `B=0x…`, the path is the first absolute path that is
    /// not a device node, the process is the last `name.pid` token.
    public static func parseFSUsage(_ text: String) -> [FileIOSample] {
        struct Key: Hashable { var pid: Int32; var path: String }
        var acc: [Key: FileIOSample] = [:]
        for line in text.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 4, let last = tokens.last, let dot = last.lastIndex(of: "."), let pid = Int32(last[last.index(after: dot)...]) else { continue }
            let name = String(last[..<dot])
            let call = tokens[1]
            let isRead = call.hasPrefix("RdData") || call.hasPrefix("RdMeta") || call == "read" || call == "pread" || call.hasPrefix("readv")
            let isWrite = call.hasPrefix("WrData") || call.hasPrefix("WrMeta") || call == "write" || call == "pwrite" || call.hasPrefix("writev")
            guard isRead || isWrite else { continue }
            var bytes: UInt64 = 0
            var path: String?
            for t in tokens {
                if t.hasPrefix("B=0x"), let n = UInt64(t.dropFirst(4), radix: 16) { bytes = n }
                if path == nil, t.hasPrefix("/"), !t.hasPrefix("/dev/") { path = t }
            }
            guard let path else { continue }
            let key = Key(pid: pid, path: path)
            var s = acc[key] ?? FileIOSample(pid: pid, name: name, path: path, readBytes: 0, writeBytes: 0, reads: 0, writes: 0)
            if isRead { s.readBytes += bytes; s.reads += 1 } else { s.writeBytes += bytes; s.writes += 1 }
            acc[key] = s
        }
        return acc.values.sorted { $0.readBytes + $0.writeBytes > $1.readBytes + $1.writeBytes }
    }

    /// SMART status as diskutil reports it. USB bridges rarely pass it through.
    public static func smart(diskID: String) -> SMARTReport {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", diskID]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return SMARTReport(diskID: diskID, status: nil, detail: "diskutil did not start") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return SMARTReport(diskID: diskID, status: nil, detail: "no answer from diskutil")
        }
        let status = plist["SMARTStatus"] as? String
        if status == nil || status == "Not Supported" {
            return SMARTReport(diskID: diskID, status: nil, detail: "SMART is not passed through by this bridge")
        }
        return SMARTReport(diskID: diskID, status: status, detail: "SMART \(status!)")
    }
}
