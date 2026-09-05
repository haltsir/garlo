import Foundation
import ServiceManagement
import Observation
import GarloCore

/// The same protocol the daemon implements (kept in step with
/// Sources/GarloHelper/main.swift).
@objc protocol GarloHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    func snapshot(reply: @escaping (Data?) -> Void)
    func fileIO(seconds: Int, reply: @escaping (Data?) -> Void)
    func smart(diskID: String, reply: @escaping (Data?) -> Void)
}

/// Registers the privileged helper with SMAppService and talks to it over
/// XPC. Installed only when the user asks; removable in one click.
@Observable @MainActor
final class HelperClient: PrivilegedSource {
    enum State: Equatable {
        case notInstalled, needsApproval, installed, notFound, failed(String)
        var label: String {
            switch self {
            case .notInstalled: return "Not installed"
            case .needsApproval: return "Waiting for approval in System Settings > Login Items"
            case .installed: return "Installed"
            case .notFound: return "Not available in this build"
            case .failed(let why): return "Could not register: \(why)"
            }
        }
    }

    private(set) var state: State = .notInstalled
    private(set) var reachable = false
    private(set) var lastError: String?
    nonisolated(unsafe) private var connection: NSXPCConnection?
    private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)

    nonisolated var isAvailable: Bool {
        MainActor.assumeIsolated { state == .installed && reachable }
    }

    init() { refresh() }

    func refresh() {
        switch service.status {
        case .notRegistered: state = .notInstalled
        case .enabled: state = .installed
        case .requiresApproval: state = .needsApproval
        // a daemon that was never registered reports notFound, not notRegistered
        case .notFound: state = .notInstalled
        @unknown default: state = .notInstalled
        }
        if state == .installed { Task { await ping() } } else { reachable = false }
    }

    func install() {
        do {
            try service.register()
            refresh()
            if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            state = .failed(error.localizedDescription)
            // registration can leave it waiting for approval
            if service.status == .requiresApproval {
                state = .needsApproval
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    func remove() {
        connection?.invalidate()
        connection = nil
        do { try service.unregister() } catch { lastError = error.localizedDescription }
        refresh()
    }

    /// After the app replaced itself, launchd still holds the old build's
    /// launch constraint and kills the new daemon at start. Unregistering,
    /// letting launchd drop the job, and registering again fixes it and
    /// keeps the user's approval.
    func reregisterAfterUpdate() {
        guard state == .installed else { return }
        connection?.invalidate()
        connection = nil
        try? service.unregister()
        Task { [weak self] in
            // launchd gives the old daemon a few seconds to exit; registering
            // before the job is gone reuses its record and the stale constraint
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if service.status != .enabled { break }
            }
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            do { try service.register() } catch { lastError = error.localizedDescription }
            refresh()
        }
    }

    // MARK: XPC

    nonisolated private func proxy() -> (any GarloHelperProtocol)? {
        let conn: NSXPCConnection
        if let existing = connection {
            conn = existing
        } else {
            conn = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: GarloHelperProtocol.self)
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil; self?.reachable = false }
            }
            conn.resume()
            connection = conn
        }
        return conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription; self?.reachable = false }
        } as? any GarloHelperProtocol
    }

    private func ping() async {
        guard let p = proxy() else { reachable = false; return }
        let v: Int? = await withCheckedContinuation { c in
            var done = false
            p.version { v in if !done { done = true; c.resume(returning: v) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if !done { done = true; c.resume(returning: nil) } }
        }
        reachable = v == HelperIdentity.protocolVersion
        if v != nil, v != HelperIdentity.protocolVersion { lastError = "Helper protocol \(v!) does not match the app's \(HelperIdentity.protocolVersion)." }
    }

    nonisolated private func call<T: Decodable>(_ type: T.Type, timeout: Double = 10, _ body: @escaping (any GarloHelperProtocol, @escaping (Data?) -> Void) -> Void) async -> T? {
        guard let p = proxy() else { return nil }
        let data: Data? = await withCheckedContinuation { c in
            let lock = NSLock()
            var done = false
            func finish(_ d: Data?) { lock.lock(); defer { lock.unlock() }; if !done { done = true; c.resume(returning: d) } }
            body(p) { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    nonisolated func snapshot() async -> HelperSnapshot? {
        await call(HelperSnapshot.self) { p, reply in p.snapshot(reply: reply) }
    }

    nonisolated func fileIO(seconds: Int) async -> FileIOReport? {
        await call(FileIOReport.self, timeout: Double(seconds) + 10) { p, reply in p.fileIO(seconds: seconds, reply: reply) }
    }

    nonisolated func smart(diskID: String) async -> SMARTReport? {
        await call(SMARTReport.self) { p, reply in p.smart(diskID: diskID, reply: reply) }
    }
}
