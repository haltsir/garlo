import Foundation

// MARK: - Raw samples (cumulative counters read once per second)

/// Cumulative I/O counters of one physical disk, as reported by the
/// IOBlockStorageDriver `Statistics` dictionary. Rates are derived by
/// differencing two samples (see `DiskRate`).
public struct DiskSample: Codable, Sendable, Hashable {
    /// BSD name of the whole disk, e.g. "disk4". Stable while attached.
    public var id: String
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var opsRead: UInt64
    public var opsWritten: UInt64
    /// Sum of per-request durations, nanoseconds. Includes queueing time.
    public var timeReadNs: UInt64
    public var timeWriteNs: UInt64

    public init(id: String, bytesRead: UInt64, bytesWritten: UInt64, opsRead: UInt64, opsWritten: UInt64, timeReadNs: UInt64, timeWriteNs: UInt64) {
        self.id = id
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.opsRead = opsRead
        self.opsWritten = opsWritten
        self.timeReadNs = timeReadNs
        self.timeWriteNs = timeWriteNs
    }
}

/// Cumulative disk I/O, CPU time and memory footprint of one process
/// (own user only without the helper).
public struct ProcessSample: Codable, Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    /// User plus system CPU time, nanoseconds.
    public var cpuNs: UInt64
    public var footprintBytes: UInt64

    public init(pid: Int32, name: String, bundleID: String? = nil, bytesRead: UInt64, bytesWritten: UInt64, cpuNs: UInt64 = 0, footprintBytes: UInt64 = 0) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.cpuNs = cpuNs
        self.footprintBytes = footprintBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        name = try c.decode(String.self, forKey: .name)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        bytesRead = try c.decode(UInt64.self, forKey: .bytesRead)
        bytesWritten = try c.decode(UInt64.self, forKey: .bytesWritten)
        cpuNs = try c.decodeIfPresent(UInt64.self, forKey: .cpuNs) ?? 0
        footprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .footprintBytes) ?? 0
    }
}

/// A file a process holds open, resolved to the volume it lives on.
public struct OpenFile: Codable, Sendable, Hashable {
    public var path: String
    public var mountPoint: String
    public var sizeBytes: UInt64

    public init(path: String, mountPoint: String, sizeBytes: UInt64) {
        self.path = path
        self.mountPoint = mountPoint
        self.sizeBytes = sizeBytes
    }
}

/// Everything sampled in one tick. The M2 fields are optional so M1
/// fixtures still decode.
public struct Frame: Codable, Sendable {
    public var timestamp: Date
    public var disks: [DiskSample]
    public var processes: [ProcessSample]
    /// Open files per pid, only for processes that were doing I/O.
    /// Listed every few seconds, not every tick.
    public var openFiles: [Int32: [OpenFile]]
    public var network: [NetworkSample]?
    public var wifi: WiFiSample?
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var system: SystemSample?
    /// Per-process network bytes, refreshed every few seconds while busy.
    public var processNet: [ProcessNetSample]?
    /// Probes that completed during this tick.
    public var latency: [LatencySample]?
    /// Pid of the frontmost app, set by the app (the core has no AppKit).
    public var foregroundPID: Int32?
    /// Free bytes per mount point. A copy drains its destination at the
    /// copy's rate; background writes do not.
    public var volumeFree: [String: UInt64]?

    public init(timestamp: Date, disks: [DiskSample], processes: [ProcessSample], openFiles: [Int32: [OpenFile]] = [:],
                network: [NetworkSample]? = nil, wifi: WiFiSample? = nil, cpu: CPUSample? = nil, memory: MemorySample? = nil,
                system: SystemSample? = nil, processNet: [ProcessNetSample]? = nil, latency: [LatencySample]? = nil, foregroundPID: Int32? = nil,
                volumeFree: [String: UInt64]? = nil) {
        self.timestamp = timestamp
        self.disks = disks
        self.processes = processes
        self.openFiles = openFiles
        self.network = network
        self.wifi = wifi
        self.cpu = cpu
        self.memory = memory
        self.system = system
        self.processNet = processNet
        self.latency = latency
        self.foregroundPID = foregroundPID
        self.volumeFree = volumeFree
    }
}

// MARK: - Topology (refreshed rarely)

public enum USBSpeed: Int, Codable, Sendable, Hashable {
    case low = 0, full = 1, high = 2, superSpeed = 3, superSpeedPlus = 4, superSpeedPlusBy2 = 5

    /// Signalling rate in bits per second.
    public var bitsPerSecond: Double {
        switch self {
        case .low: return 1_500_000
        case .full: return 12_000_000
        case .high: return 480_000_000
        case .superSpeed: return 5_000_000_000
        case .superSpeedPlus: return 10_000_000_000
        case .superSpeedPlusBy2: return 20_000_000_000
        }
    }

    /// Practical payload ceiling in bytes per second, after protocol overhead.
    public var practicalBytesPerSecond: Double {
        switch self {
        case .low: return 150_000
        case .full: return 1_000_000
        case .high: return 42_000_000
        case .superSpeed: return 420_000_000
        case .superSpeedPlus: return 900_000_000
        case .superSpeedPlusBy2: return 1_800_000_000
        }
    }

    public var label: String {
        switch self {
        case .low: return "1.5 Mb/s"
        case .full: return "12 Mb/s"
        case .high: return "480 Mb/s"
        case .superSpeed: return "5 Gb/s"
        case .superSpeedPlus: return "10 Gb/s"
        case .superSpeedPlusBy2: return "20 Gb/s"
        }
    }
}

/// The USB link a disk sits behind.
public struct USBLink: Codable, Sendable, Hashable {
    public var productName: String
    public var speed: USBSpeed
    /// Highest USB version the device declares (bcdUSB), e.g. 0x0320.
    public var declaredVersion: Int?
    /// Hubs between the device and the host controller, nearest first.
    public var hubs: [String]
    /// IORegistry name of the host controller, shared by devices on one port group.
    public var controller: String

    public init(productName: String, speed: USBSpeed, declaredVersion: Int?, hubs: [String], controller: String) {
        self.productName = productName
        self.speed = speed
        self.declaredVersion = declaredVersion
        self.hubs = hubs
        self.controller = controller
    }

    /// The least the device supports, from bcdUSB. The spec version says
    /// "SuperSpeed or better", never which generation, so this is a floor:
    /// a USB 3 device negotiated at 480 Mb/s is linked below capability,
    /// a 5 Gb/s link on a 3.2 device is not judged.
    public var capableSpeed: USBSpeed? {
        guard let v = declaredVersion else { return nil }
        if v >= 0x0300 { return .superSpeed }
        if v >= 0x0200 { return .high }
        return .full
    }
}

public enum MediaKind: String, Codable, Sendable {
    case solidState, rotational, unknown
}

/// Static description of a physical disk.
public struct DiskDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: String              // BSD whole-disk name, "disk4"
    public var name: String            // "QNAP TR-004 DISK00"
    public var sizeBytes: UInt64
    public var interconnect: String    // "USB", "Apple Fabric", "PCI-Express"
    public var isInternal: Bool
    public var media: MediaKind
    public var usb: USBLink?

    public init(id: String, name: String, sizeBytes: UInt64, interconnect: String, isInternal: Bool, media: MediaKind, usb: USBLink?) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.interconnect = interconnect
        self.isInternal = isInternal
        self.media = media
        self.usb = usb
    }

    /// Payload ceiling of the link the disk sits behind, if known.
    public var linkCeilingBytesPerSecond: Double? { usb?.speed.practicalBytesPerSecond }

    /// Rotational media, or an external disk of unknown kind (treated as
    /// rotational for thresholds: that is where the trouble is).
    public var behavesRotational: Bool {
        switch media {
        case .rotational: return true
        case .solidState: return false
        case .unknown: return !isInternal
        }
    }
}

/// A mounted volume and the physical disk it lives on.
public struct Volume: Codable, Sendable, Hashable, Identifiable {
    public var id: String { mountPoint }
    public var mountPoint: String
    public var name: String
    public var bsdName: String         // "disk5s1"
    public var diskID: String?         // physical whole disk, "disk4"
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var fileSystem: String
    public var defragmentEnabled: Bool?
    public var isReadOnly: Bool

    public init(mountPoint: String, name: String, bsdName: String, diskID: String?, totalBytes: UInt64, freeBytes: UInt64, fileSystem: String, defragmentEnabled: Bool? = nil, isReadOnly: Bool = false) {
        self.mountPoint = mountPoint
        self.name = name
        self.bsdName = bsdName
        self.diskID = diskID
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.fileSystem = fileSystem
        self.defragmentEnabled = defragmentEnabled
        self.isReadOnly = isReadOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mountPoint = try c.decode(String.self, forKey: .mountPoint)
        name = try c.decode(String.self, forKey: .name)
        bsdName = try c.decode(String.self, forKey: .bsdName)
        diskID = try c.decodeIfPresent(String.self, forKey: .diskID)
        totalBytes = try c.decode(UInt64.self, forKey: .totalBytes)
        freeBytes = try c.decode(UInt64.self, forKey: .freeBytes)
        fileSystem = try c.decode(String.self, forKey: .fileSystem)
        defragmentEnabled = try c.decodeIfPresent(Bool.self, forKey: .defragmentEnabled)
        isReadOnly = try c.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - min(freeBytes, totalBytes)) / Double(totalBytes)
    }
}

public struct Topology: Codable, Sendable, Hashable {
    public var disks: [DiskDevice]
    public var volumes: [Volume]

    public init(disks: [DiskDevice] = [], volumes: [Volume] = []) {
        self.disks = disks
        self.volumes = volumes
    }

    public func disk(_ id: String) -> DiskDevice? { disks.first { $0.id == id } }
    public func volumes(on diskID: String) -> [Volume] { volumes.filter { $0.diskID == diskID } }
    /// The volume a path lives on. Anything not under another mount point
    /// is on the boot volume, which the Data volume represents (files under
    /// /Users or /private never carry the /System/Volumes/Data prefix).
    public func volume(containing path: String) -> Volume? {
        let match = volumes
            .filter { path == $0.mountPoint || path.hasPrefix($0.mountPoint == "/" ? "/" : $0.mountPoint + "/") }
            .max { $0.mountPoint.count < $1.mountPoint.count }
        if let match { return match }
        guard path.hasPrefix("/"), !path.hasPrefix("/Volumes/") else { return nil }
        return volumes.first { $0.mountPoint == "/System/Volumes/Data" } ?? volumes.first { $0.mountPoint == "/" }
    }
    /// Display name of a disk: its main volume when it has a real name,
    /// else the device name. A Windows "Local Disk" label says nothing.
    public func displayName(forDisk id: String) -> String {
        let generic: Set<String> = ["local disk", "untitled", "no name", "efi", "new volume", "volume"]
        let vols = volumes(on: id).filter { !$0.name.isEmpty && $0.mountPoint != "/System/Volumes/VM" }
        if let main = vols.max(by: { $0.totalBytes < $1.totalBytes }) {
            if main.mountPoint == "/" || main.mountPoint == "/System/Volumes/Data" { return "Boot disk" }
            if !generic.contains(main.name.lowercased()) { return main.name }
        }
        return disk(id)?.name ?? id
    }
}

// MARK: - Derived rates

/// Per-second rates of one disk between two frames.
public struct DiskRate: Sendable, Hashable {
    public var id: String
    public var interval: TimeInterval
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double
    public var readOpsPerSec: Double
    public var writeOpsPerSec: Double
    /// Average time per completed request, including queueing, in ms.
    public var readMsPerOp: Double
    public var writeMsPerOp: Double
    /// Average number of requests in flight (Little's law).
    public var queueDepth: Double

    public var bytesPerSec: Double { readBytesPerSec + writeBytesPerSec }
    public var opsPerSec: Double { readOpsPerSec + writeOpsPerSec }
    /// Fraction of the interval the disk had at least one request in flight (capped at 1).
    public var busy: Double { min(1, queueDepth) }
    public var isIdle: Bool { opsPerSec < 1 }
    public var averageRequestBytes: Double { opsPerSec > 0 ? bytesPerSec / opsPerSec : 0 }
    /// Time per request once it is being served, with queueing taken out.
    public var serviceMsPerOp: Double {
        let latency = opsPerSec > 0 ? (readMsPerOp * readOpsPerSec + writeMsPerOp * writeOpsPerSec) / opsPerSec : 0
        return latency / max(1, queueDepth)
    }

    public static func between(_ a: DiskSample, _ b: DiskSample, interval: TimeInterval) -> DiskRate? {
        guard a.id == b.id, interval > 0 else { return nil }
        func d(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) : 0 }
        let rOps = d(a.opsRead, b.opsRead), wOps = d(a.opsWritten, b.opsWritten)
        let rNs = d(a.timeReadNs, b.timeReadNs), wNs = d(a.timeWriteNs, b.timeWriteNs)
        return DiskRate(
            id: a.id,
            interval: interval,
            readBytesPerSec: d(a.bytesRead, b.bytesRead) / interval,
            writeBytesPerSec: d(a.bytesWritten, b.bytesWritten) / interval,
            readOpsPerSec: rOps / interval,
            writeOpsPerSec: wOps / interval,
            readMsPerOp: rOps > 0 ? rNs / rOps / 1_000_000 : 0,
            writeMsPerOp: wOps > 0 ? wNs / wOps / 1_000_000 : 0,
            queueDepth: (rNs + wNs) / 1_000_000_000 / interval
        )
    }
}

/// Per-second I/O of one process between two frames.
public struct ProcessRate: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double
    public var bytesPerSec: Double { readBytesPerSec + writeBytesPerSec }

    public static func between(_ a: ProcessSample, _ b: ProcessSample, interval: TimeInterval) -> ProcessRate? {
        guard a.pid == b.pid, interval > 0 else { return nil }
        func d(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) : 0 }
        return ProcessRate(pid: a.pid, name: b.name, bundleID: b.bundleID,
                           readBytesPerSec: d(a.bytesRead, b.bytesRead) / interval,
                           writeBytesPerSec: d(a.bytesWritten, b.bytesWritten) / interval)
    }
}

// MARK: - M2: network, CPU, memory, thermal

/// Cumulative counters of one network interface (`NET_RT_IFLIST2`).
public struct NetworkSample: Codable, Sendable, Hashable {
    public var name: String            // "en1"
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    public var errorsIn: UInt64
    public var errorsOut: UInt64
    public var drops: UInt64
    /// Link rate in bits per second as the driver reports it; 0 when unknown.
    public var baudrate: UInt64

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64, packetsIn: UInt64, packetsOut: UInt64, errorsIn: UInt64, errorsOut: UInt64, drops: UInt64, baudrate: UInt64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.errorsIn = errorsIn
        self.errorsOut = errorsOut
        self.drops = drops
        self.baudrate = baudrate
    }
}

/// Air-side state of the Wi-Fi interface (CoreWLAN).
public struct WiFiSample: Codable, Sendable, Hashable {
    public var interface: String
    public var transmitRateMbps: Double
    public var rssi: Int
    public var noise: Int
    public var channel: Int
    public var bandGHz: Double         // 2.4, 5, 6
    public var widthMHz: Int
    public var connected: Bool

    public init(interface: String, transmitRateMbps: Double, rssi: Int, noise: Int, channel: Int, bandGHz: Double, widthMHz: Int, connected: Bool) {
        self.interface = interface
        self.transmitRateMbps = transmitRateMbps
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.bandGHz = bandGHz
        self.widthMHz = widthMHz
        self.connected = connected
    }

    /// The best PHY rate this channel width can carry with two streams.
    public var channelCeilingMbps: Double {
        switch widthMHz {
        case ..<40: return bandGHz < 3 ? 144 : 173
        case 40..<80: return 400
        case 80..<160: return 866
        default: return 1733
        }
    }
}

/// Per-core CPU ticks (cumulative) plus the P/E split.
public struct CPUSample: Codable, Sendable, Hashable {
    public struct Core: Codable, Sendable, Hashable {
        public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user; self.system = system; self.idle = idle; self.nice = nice
        }
        public var total: UInt64 { user + system + idle + nice }
    }
    public var cores: [Core]
    /// Number of efficiency cores; they are the first `efficiencyCores` entries.
    public var efficiencyCores: Int
    public var loadAverage1: Double
    /// Percent of full speed the CPU is allowed, 100 when unthrottled.
    public var speedLimit: Int

    public init(cores: [Core], efficiencyCores: Int, loadAverage1: Double, speedLimit: Int) {
        self.cores = cores
        self.efficiencyCores = efficiencyCores
        self.loadAverage1 = loadAverage1
        self.speedLimit = speedLimit
    }
    public var performanceCores: Int { cores.count - efficiencyCores }
}

public enum PressureLevel: String, Codable, Sendable, Comparable {
    case normal, warning, critical
    private var rank: Int { switch self { case .normal: 0; case .warning: 1; case .critical: 2 } }
    public static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rank < b.rank }
}

public struct MemorySample: Codable, Sendable, Hashable {
    public var totalBytes: UInt64
    public var pressure: PressureLevel
    public var compressorBytes: UInt64
    public var swapUsedBytes: UInt64
    /// Cumulative page counts.
    public var pageIns: UInt64
    public var pageOuts: UInt64
    public var swapIns: UInt64
    public var swapOuts: UInt64
    public var pageSize: UInt64

    public init(totalBytes: UInt64, pressure: PressureLevel, compressorBytes: UInt64, swapUsedBytes: UInt64, pageIns: UInt64, pageOuts: UInt64, swapIns: UInt64, swapOuts: UInt64, pageSize: UInt64) {
        self.totalBytes = totalBytes
        self.pressure = pressure
        self.compressorBytes = compressorBytes
        self.swapUsedBytes = swapUsedBytes
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.pageSize = pageSize
    }
}

public enum ThermalState: String, Codable, Sendable, Comparable {
    case nominal, fair, serious, critical
    private var rank: Int { switch self { case .nominal: 0; case .fair: 1; case .serious: 2; case .critical: 3 } }
    public static func < (a: ThermalState, b: ThermalState) -> Bool { a.rank < b.rank }
}

/// Thermal, power and GPU state.
public struct SystemSample: Codable, Sendable, Hashable {
    public var thermal: ThermalState
    public var lowPowerMode: Bool
    public var onBattery: Bool
    public var charging: Bool
    /// Battery drain in mA while on external power means the adapter is too weak.
    public var batteryCurrentMilliamps: Int?
    public var adapterWatts: Int?
    /// 0 to 100, nil when no accelerator reports it.
    public var gpuUtilization: Int?

    public init(thermal: ThermalState, lowPowerMode: Bool, onBattery: Bool, charging: Bool, batteryCurrentMilliamps: Int?, adapterWatts: Int?, gpuUtilization: Int?) {
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.charging = charging
        self.batteryCurrentMilliamps = batteryCurrentMilliamps
        self.adapterWatts = adapterWatts
        self.gpuUtilization = gpuUtilization
    }
}

/// Cumulative network bytes of one process (same data as `nettop`).
public struct ProcessNetSample: Codable, Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public init(pid: Int32, name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid; self.name = name; self.bytesIn = bytesIn; self.bytesOut = bytesOut
    }
}

/// One round-trip measurement.
public struct LatencySample: Codable, Sendable, Hashable {
    public enum Target: String, Codable, Sendable { case gateway, anchor, dns }
    public var target: Target
    public var milliseconds: Double?   // nil: timed out or failed
    public init(target: Target, milliseconds: Double?) {
        self.target = target; self.milliseconds = milliseconds
    }
}

/// Per-second network rate of one interface.
public struct NetworkRate: Sendable, Hashable {
    public var name: String
    public var interval: TimeInterval
    public var inBytesPerSec: Double
    public var outBytesPerSec: Double
    public var packetsPerSec: Double
    public var errorsPerSec: Double
    public var dropsPerSec: Double
    public var baudrate: UInt64
    public var bytesPerSec: Double { inBytesPerSec + outBytesPerSec }
    /// Utilisation of the link in the busier direction, 0 to 1; nil without a link rate.
    public var utilisation: Double? {
        guard baudrate > 0 else { return nil }
        return min(1, max(inBytesPerSec, outBytesPerSec) * 8 / Double(baudrate))
    }

    /// The driver's baudrate is stale for Wi-Fi; use the air rate there.
    public func withLinkRate(wifi: WiFiSample?) -> NetworkRate {
        guard let wifi, wifi.interface == name, wifi.transmitRateMbps > 0 else { return self }
        var r = self
        r.baudrate = UInt64(wifi.transmitRateMbps * 1_000_000)
        return r
    }

    public static func between(_ a: NetworkSample, _ b: NetworkSample, interval: TimeInterval) -> NetworkRate? {
        guard a.name == b.name, interval > 0 else { return nil }
        func d(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) : 0 }
        return NetworkRate(name: a.name, interval: interval,
                           inBytesPerSec: d(a.bytesIn, b.bytesIn) / interval,
                           outBytesPerSec: d(a.bytesOut, b.bytesOut) / interval,
                           packetsPerSec: (d(a.packetsIn, b.packetsIn) + d(a.packetsOut, b.packetsOut)) / interval,
                           errorsPerSec: (d(a.errorsIn, b.errorsIn) + d(a.errorsOut, b.errorsOut)) / interval,
                           dropsPerSec: d(a.drops, b.drops) / interval,
                           baudrate: b.baudrate)
    }
}

/// CPU utilisation between two samples, per core and split by core type.
public struct CPURate: Sendable, Hashable {
    public var perCore: [Double]       // 0 to 1
    public var efficiencyCores: Int
    public var systemFraction: Double  // kernel + interrupt share of all busy time
    public var loadAverage1: Double
    public var speedLimit: Int

    public var performanceUtilisation: Double {
        let p = perCore.dropFirst(efficiencyCores)
        return p.isEmpty ? 0 : p.reduce(0, +) / Double(p.count)
    }
    public var efficiencyUtilisation: Double {
        let e = perCore.prefix(efficiencyCores)
        return e.isEmpty ? 0 : e.reduce(0, +) / Double(e.count)
    }
    public var total: Double { perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count) }

    public static func between(_ a: CPUSample, _ b: CPUSample) -> CPURate? {
        guard a.cores.count == b.cores.count, !b.cores.isEmpty else { return nil }
        var per: [Double] = []
        var busy = 0.0, sys = 0.0
        for (x, y) in zip(a.cores, b.cores) {
            let total = Double(y.total &- x.total)
            let idle = Double(y.idle &- x.idle)
            let s = Double(y.system &- x.system)
            per.append(total > 0 ? max(0, min(1, 1 - idle / total)) : 0)
            busy += max(0, total - idle)
            sys += s
        }
        return CPURate(perCore: per, efficiencyCores: b.efficiencyCores, systemFraction: busy > 0 ? sys / busy : 0,
                       loadAverage1: b.loadAverage1, speedLimit: b.speedLimit)
    }
}
