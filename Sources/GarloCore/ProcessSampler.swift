import Foundation
import Darwin

/// Per-process disk I/O from `proc_pid_rusage` and open files from
/// `proc_pidinfo`. Without the helper this covers the user's own processes;
/// root processes (Finder's copy helper among them) answer with EPERM and
/// are skipped silently.
public struct ProcessSampler: Sendable {
    public init() {}

    static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Cumulative disk bytes for every process we may inspect.
    public func sample() -> [ProcessSample] {
        let pids = allPIDs()
        var out: [ProcessSample] = []
        out.reserveCapacity(pids.count)
        for pid in pids where pid > 0 {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard rc == 0 else { continue }
            let identity = ProcessIdentity.shared.identity(of: pid)
            let cpuNs = (info.ri_user_time + info.ri_system_time) * UInt64(Self.timebase.numer) / UInt64(max(1, Self.timebase.denom))
            out.append(ProcessSample(pid: pid, name: identity.name, bundleID: identity.bundleID,
                                     bytesRead: info.ri_diskio_bytesread, bytesWritten: info.ri_diskio_byteswritten,
                                     cpuNs: cpuNs, footprintBytes: info.ri_phys_footprint))
        }
        return out
    }

    /// Regular files a process holds open, resolved to volumes.
    public func openFiles(of pid: Int32, topology: Topology) -> [OpenFile] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard got > 0 else { return [] }
        var out: [OpenFile] = []
        var seen = Set<String>()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard n == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
            guard (vi.pvip.vip_vi.vi_stat.vst_mode & S_IFMT) == S_IFREG else { continue }
            let path = withUnsafePointer(to: &vi.pvip.vip_path) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            guard let vol = topology.volume(containing: path) else { continue }
            out.append(OpenFile(path: path, mountPoint: vol.mountPoint, sizeBytes: UInt64(max(0, vi.pvip.vip_vi.vi_stat.vst_size))))
        }
        return out
    }

    private func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        return Array(pids.prefix(Int(max(0, got))))
    }
}

/// Process name and bundle identifier, cached per pid (pids recycle, so the
/// cache also remembers the start time it saw).
final class ProcessIdentity: @unchecked Sendable {
    static let shared = ProcessIdentity()
    struct Identity { var name: String; var bundleID: String? }
    private let lock = NSLock()
    private var cache: [Int32: Identity] = [:]

    func identity(of pid: Int32) -> Identity {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[pid] { return hit }
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : ""
        var nameBuf = [CChar](repeating: 0, count: 256)
        let procName = proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 ? String(cString: nameBuf) : ""
        var name = procName.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : procName
        var bundleID: String?
        if let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            if let bundle = Bundle(path: bundlePath) {
                bundleID = bundle.bundleIdentifier
                if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !display.isEmpty {
                    // helpers inside an app bundle report under the app's name
                    if path.contains("/Contents/MacOS/") && !path.contains("/Contents/Frameworks/") && !path.contains("/Contents/PlugIns/") {
                        name = display
                    }
                }
            }
        }
        if name.isEmpty { name = "pid \(pid)" }
        let id = Identity(name: name, bundleID: bundleID)
        if cache.count > 4096 { cache.removeAll() }
        cache[pid] = id
        return id
    }
}
