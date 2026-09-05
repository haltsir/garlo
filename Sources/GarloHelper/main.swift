import Foundation
import GarloCore

// GarloHelper: the privileged daemon, registered by the app through
// SMAppService and started by launchd as root on demand. It answers over
// XPC to the signed Garlo app only, and exposes exactly three operations:
// a process snapshot (counters and open files of every process), a
// per-file I/O sample, and SMART status for a disk.

@objc protocol GarloHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    func snapshot(reply: @escaping (Data?) -> Void)
    func fileIO(seconds: Int, reply: @escaping (Data?) -> Void)
    func smart(diskID: String, reply: @escaping (Data?) -> Void)
}

final class HelperService: NSObject, GarloHelperProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [Int32: ProcessSample] = [:]
    private var previousAt = Date.distantPast
    private var topology = Topology()
    private var topologyAt = Date.distantPast

    private func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    func version(reply: @escaping (Int) -> Void) {
        reply(HelperIdentity.protocolVersion)
    }

    func snapshot(reply: @escaping (Data?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        IdleExit.touch()
        let clientUID = NSXPCConnection.current()?.effectiveUserIdentifier ?? 0
        let now = Date()
        if now.timeIntervalSince(topologyAt) > 60 {
            topology = TopologySampler.sample(defragStatus: false)
            topologyAt = now
        }
        let snap = HelperWork.snapshot(topology: topology, previous: previous, interval: now.timeIntervalSince(previousAt), clientUID: clientUID)
        previous = Dictionary(snap.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        previousAt = now
        reply(encode(snap))
    }

    func fileIO(seconds: Int, reply: @escaping (Data?) -> Void) {
        IdleExit.touch()
        reply(encode(HelperWork.fileIO(seconds: seconds)))
    }

    func smart(diskID: String, reply: @escaping (Data?) -> Void) {
        IdleExit.touch()
        // only a BSD disk name, never a path or an option
        guard diskID.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else { reply(nil); return }
        reply(encode(HelperWork.smart(diskID: diskID)))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the signed Garlo app may talk to this daemon.
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: GarloHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

/// launchd starts the daemon on demand; it leaves again after two minutes
/// without a request, so nothing runs as root while Garlo has no question.
enum IdleExit {
    nonisolated(unsafe) static var last = Date()
    static func touch() { last = Date() }
    static func arm() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            if Date().timeIntervalSince(last) > 120 { exit(0) }
        }
    }
}

let delegate = ListenerDelegate()
IdleExit.arm()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
