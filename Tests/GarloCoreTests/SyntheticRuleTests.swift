import Testing
import Foundation
@testable import GarloCore

/// Hand-built frames for the rules whose incidents cannot be reproduced on
/// demand (weak Wi-Fi, bufferbloat, memory pressure, throttling).
enum Synthetic {
    static let boot = DiskDevice(id: "disk0", name: "APPLE SSD", sizeBytes: 500_000_000_000, interconnect: "Apple Fabric", isInternal: true, media: .solidState, usb: nil)
    static let topology = Topology(disks: [boot], volumes: [Volume(mountPoint: "/System/Volumes/Data", name: "Macintosh HD", bsdName: "disk3s5", diskID: "disk0", totalBytes: 500_000_000_000, freeBytes: 200_000_000_000, fileSystem: "apfs")])

    struct Tick {
        var cpuBusy: Double = 0.1          // fraction of every core
        var speedLimit = 100
        var thermal: ThermalState = .nominal
        var pressure: PressureLevel = .normal
        var pageOutsPerSec: UInt64 = 0     // pages
        var netIn: UInt64 = 0, netOut: UInt64 = 0   // bytes per tick
        var baudrate: UInt64 = 1_000_000_000
        var wifi: WiFiSample? = nil
        var latency: [LatencySample]? = nil
        var processNet: [ProcessNetSample]? = nil
        var processes: [ProcessSample] = []
        var bootWriteBytes: UInt64 = 0
    }

    /// Frames from a list of ticks, one second apart, counters accumulated.
    static func frames(_ ticks: [Tick]) -> [Frame] {
        var out: [Frame] = []
        var cores = [CPUSample.Core](repeating: CPUSample.Core(user: 0, system: 0, idle: 0, nice: 0), count: 12)
        var pageOuts: UInt64 = 0
        var netIn: UInt64 = 0, netOut: UInt64 = 0
        var disk = DiskSample(id: "disk0", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, t) in ticks.enumerated() {
            // 100 ticks per second per core
            for c in cores.indices {
                cores[c].user += UInt64(t.cpuBusy * 100)
                cores[c].idle += UInt64((1 - t.cpuBusy) * 100)
            }
            pageOuts += t.pageOutsPerSec
            netIn += t.netIn
            netOut += t.netOut
            disk.bytesWritten += t.bootWriteBytes
            disk.opsWritten += t.bootWriteBytes / 65536
            disk.timeWriteNs += (t.bootWriteBytes / 65536) * 200_000
            out.append(Frame(
                timestamp: t0.addingTimeInterval(Double(i)),
                disks: [disk],
                processes: t.processes,
                network: [NetworkSample(name: "en1", bytesIn: netIn, bytesOut: netOut, packetsIn: netIn / 1400, packetsOut: netOut / 1400, errorsIn: 0, errorsOut: 0, drops: 0, baudrate: t.baudrate)],
                wifi: t.wifi,
                cpu: CPUSample(cores: cores, efficiencyCores: 4, loadAverage1: t.cpuBusy * 12, speedLimit: t.speedLimit),
                memory: MemorySample(totalBytes: 32_000_000_000, pressure: t.pressure, compressorBytes: 8_000_000_000, swapUsedBytes: 6_000_000_000, pageIns: 0, pageOuts: pageOuts, swapIns: 0, swapOuts: 0, pageSize: 16384),
                system: SystemSample(thermal: t.thermal, lowPowerMode: false, onBattery: false, charging: true, batteryCurrentMilliamps: nil, adapterWatts: nil, gpuUtilization: 10),
                processNet: t.processNet,
                latency: t.latency,
                foregroundPID: 100
            ))
        }
        return out
    }

    @MainActor
    static func run(_ ticks: [Tick], rules: [any Rule] = AllRules.all) -> Engine {
        let engine = Engine(rules: rules, topology: topology, openAfter: 3, resolveAfter: 5)
        engine.setPrimaryInterface("en1")
        for f in frames(ticks) { engine.evaluate(f) }
        return engine
    }
}

@Suite struct SyntheticRuleTests {
    @Test @MainActor func weakWiFiIsTheLimit() {
        let wifi = WiFiSample(interface: "en1", transmitRateMbps: 65, rssi: -79, noise: -92, channel: 6, bandGHz: 2.4, widthMHz: 20, connected: true)
        var tick = Synthetic.Tick(netIn: 6_000_000, baudrate: 65_000_000, wifi: wifi)
        tick.processNet = nil
        let engine = Synthetic.run(Array(repeating: tick, count: 40))
        let f = engine.findings.first { $0.rule == "wifi" }
        #expect(f?.verdict == "Wi-Fi is the limit")
        #expect(f?.confidence == .confirmed)
        #expect(f?.actions.first?.title == "Switch to 5 GHz or move closer")
    }

    @Test @MainActor func quietWiFiSaysNothing() {
        let wifi = WiFiSample(interface: "en1", transmitRateMbps: 866, rssi: -50, noise: -90, channel: 44, bandGHz: 5, widthMHz: 80, connected: true)
        let engine = Synthetic.run(Array(repeating: Synthetic.Tick(netIn: 200_000, baudrate: 866_000_000, wifi: wifi), count: 40))
        #expect(engine.findings.isEmpty)
    }

    @Test @MainActor func bufferbloatNeedsTwoInflatedProbes() {
        var ticks: [Synthetic.Tick] = []
        for i in 0..<30 {
            var t = Synthetic.Tick(netIn: 110_000_000, baudrate: 1_000_000_000)
            t.latency = i % 5 == 0 ? [LatencySample(target: .gateway, milliseconds: i < 10 ? 4 : 180)] : nil
            ticks.append(t)
        }
        let engine = Synthetic.run(ticks)
        let f = engine.findings.first { $0.rule == "bufferbloat" }
        #expect(f?.verdict == "Wi-Fi is queueing under load" || f?.verdict == "Ethernet (en1) is queueing under load")
        #expect(f?.confidence == .confirmed)
    }

    @Test @MainActor func hogNamesTheProcess() {
        var ticks: [Synthetic.Tick] = []
        for i in 0..<30 {
            var t = Synthetic.Tick(netOut: 115_000_000, baudrate: 1_000_000_000)
            t.processNet = [ProcessNetSample(pid: 500, name: "Torrent", bytesIn: 0, bytesOut: UInt64(i) * 100_000_000),
                            ProcessNetSample(pid: 501, name: "Safari", bytesIn: UInt64(i) * 1_000_000, bytesOut: 0)]
            t.latency = i % 5 == 0 ? [LatencySample(target: .gateway, milliseconds: i < 10 ? 3 : 60)] : nil
            t.processes = [ProcessSample(pid: 500, name: "Torrent", bundleID: "com.example.torrent", bytesRead: 0, bytesWritten: 0)]
            ticks.append(t)
        }
        let engine = Synthetic.run(ticks)
        let f = engine.findings.first { $0.rule == "nethog" }
        #expect(f?.verdict.hasSuffix("is saturated by Torrent") == true)
        #expect(f?.actions.first?.title == "Pause Torrent")
        #expect(f?.actions.first?.kind == .openApp(bundleID: "com.example.torrent"))
        #expect(f?.confidence == .confirmed)
    }

    @Test @MainActor func swappingIsStalledAndConfirmedByBootDiskWrites() {
        var t = Synthetic.Tick(pressure: .critical, pageOutsPerSec: 3000, bootWriteBytes: 48_000_000)
        t.processes = [ProcessSample(pid: 100, name: "Final Cut Pro", bundleID: "com.apple.FinalCut", bytesRead: 0, bytesWritten: 0, cpuNs: 0, footprintBytes: 21_000_000_000),
                       ProcessSample(pid: 101, name: "Safari", bundleID: "com.apple.Safari", bytesRead: 0, bytesWritten: 0, cpuNs: 0, footprintBytes: 2_000_000_000)]
        let engine = Synthetic.run(Array(repeating: t, count: 20))
        let f = engine.findings.first { $0.rule == "memory" }
        #expect(f?.verdict == "Mac is swapping")
        #expect(f?.severity == .stalled)
        #expect(f?.confidence == .confirmed)
        #expect(f?.contributors.first?.name == "Final Cut Pro")
        #expect(f?.actions.first?.title == "Quit Final Cut Pro")
        // the boot disk's swap traffic is explained, not a second card
        #expect(!engine.findings.contains { $0.rule == "iops" || $0.rule == "contention" })
    }

    @Test @MainActor func throttlingConfirmsAfterThirtySeconds() {
        var ticks = Array(repeating: Synthetic.Tick(cpuBusy: 0.95, speedLimit: 60, thermal: .serious), count: 40)
        for i in ticks.indices {
            var n = UInt64(i) * 7_600_000_000
            ticks[i].processes = [ProcessSample(pid: 200, name: "HandBrake", bundleID: "fr.handbrake.HandBrake", bytesRead: 0, bytesWritten: 0, cpuNs: n, footprintBytes: 1_000_000_000)]
            n += 1
        }
        let engine = Synthetic.run(ticks)
        let f = engine.findings.first { $0.rule == "throttle" }
        #expect(f?.verdict == "CPU is throttled to 60 percent")
        #expect(f?.confidence == .confirmed)
        #expect(f?.contributors.first?.name == "HandBrake")
        let cpu = engine.findings.first { $0.rule == "cpu" }
        #expect(cpu?.verdict == "HandBrake is using all performance cores")
    }

    @Test @MainActor func idleMachineHasNoFindings() {
        let engine = Synthetic.run(Array(repeating: Synthetic.Tick(), count: 60))
        #expect(engine.findings.isEmpty)
    }
}

@Suite struct TransferCorrelationTests {
    static let storage = DiskDevice(id: "disk4", name: "RAID Enclosure", sizeBytes: 12_000_000_000_000, interconnect: "USB", isInternal: false, media: .unknown,
                                    usb: USBLink(productName: "RAID Enclosure", speed: .superSpeed, declaredVersion: 0x0320, hubs: [], controller: "xhci"))
    static let topology = Topology(disks: [Synthetic.boot, storage], volumes: Synthetic.topology.volumes + [
        Volume(mountPoint: "/Volumes/Archive", name: "Archive", bsdName: "disk5s1", diskID: "disk4", totalBytes: 12_000_000_000_000, freeBytes: 1_600_000_000_000, fileSystem: "apfs")])

    /// Storage read continuously (a seeder), boot disk written in bursts (logs),
    /// with or without the boot volume draining.
    @MainActor
    static func run(draining: Bool, copier: Bool) -> Engine {
        let engine = Engine(rules: AllRules.all, topology: topology, openAfter: 3, resolveAfter: 5)
        var storage = DiskSample(id: "disk4", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        var boot = DiskSample(id: "disk0", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        var free: UInt64 = 200_000_000_000
        var folx = ProcessSample(pid: 300, name: "Torrent", bundleID: "com.example.torrent", bytesRead: 0, bytesWritten: 0)
        var cp = ProcessSample(pid: 301, name: "cp", bytesRead: 0, bytesWritten: 0)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<40 {
            storage.bytesRead += 8_000_000; storage.opsRead += 250; storage.timeReadNs += 250 * 120_000_000
            if i % 5 == 0 { boot.bytesWritten += 20_000_000; boot.opsWritten += 300; boot.timeWriteNs += 300 * 100_000 }
            if draining { free -= 4_000_000 }
            folx.bytesRead += 4_000_000
            cp.bytesRead += 4_000_000; cp.bytesWritten += 4_000_000
            var open: [Int32: [OpenFile]] = [300: (0..<30).map { OpenFile(path: "/Volumes/Archive/Downloads/file\($0).mkv", mountPoint: "/Volumes/Archive", sizeBytes: 3_000_000_000) }]
            if copier {
                open[301] = [OpenFile(path: "/Volumes/Archive/Downloads/movie.mkv", mountPoint: "/Volumes/Archive", sizeBytes: 2_500_000_000),
                             OpenFile(path: "/Users/user/movie.mkv", mountPoint: "/System/Volumes/Data", sizeBytes: 500_000_000)]
            }
            engine.evaluate(Frame(timestamp: t0.addingTimeInterval(Double(i)), disks: [storage, boot],
                                  processes: copier ? [folx, cp] : [folx], openFiles: open,
                                  volumeFree: ["/System/Volumes/Data": free, "/Volumes/Archive": 1_600_000_000_000]))
        }
        return engine
    }

    @Test @MainActor func seedingPlusBackgroundWritesIsNotATransfer() {
        let engine = Self.run(draining: false, copier: false)
        #expect(!engine.findings.contains { $0.rule == "transfer" })
    }

    @Test @MainActor func finderCopyIsSeenByTheDrain() {
        let engine = Self.run(draining: true, copier: false)
        let f = engine.findings.first { $0.rule == "transfer" }
        #expect(f?.verdict == "Copy is read-bound")
        #expect(f?.contributors.first?.name == "Torrent")
        // no file is known, so the layout is offered by hand, never guessed from Torrent's files
        #expect(f?.actions.contains { $0.title == "Pick the file" } == true)
        #expect(f?.actions.contains { $0.title == "Show file layout" } == false)
        #expect(f?.cause.contains("22") == false)
    }

    @Test @MainActor func copierProcessIsEnough() {
        let engine = Self.run(draining: false, copier: true)
        let f = engine.findings.first { $0.rule == "transfer" }
        #expect(f?.verdict == "Copy is read-bound")
        #expect(f?.actions.contains { if case .showLayout(let p) = $0.kind { p.hasSuffix("movie.mkv") } else { false } } == true)
    }
}

@Suite struct TransferSourceMatchingTests {
    /// A seeder reads Storage while a root rescue reads a WD disk into
    /// Warehouse: only the WD disk is the source of the drain.
    @Test @MainActor func drainPicksTheSourceWhoseReadsMatchTheWrites() {
        let wd = DiskDevice(id: "disk10", name: "External Disk", sizeBytes: 4e12.asUInt64, interconnect: "USB", isInternal: false, media: .unknown,
                            usb: USBLink(productName: "Elements", speed: .high, declaredVersion: 0x0210, hubs: ["USB 2.0 Hub"], controller: "xhci"))
        let warehouse = DiskDevice(id: "disk8", name: "RAID Enclosure", sizeBytes: 30e12.asUInt64, interconnect: "USB", isInternal: false, media: .unknown,
                                   usb: USBLink(productName: "RAID Enclosure", speed: .superSpeed, declaredVersion: 0x0320, hubs: [], controller: "asmedia"))
        let topo = Topology(disks: [TransferCorrelationTests.storage, wd, warehouse], volumes: [
            Volume(mountPoint: "/Volumes/Archive", name: "Archive", bsdName: "disk5s1", diskID: "disk4", totalBytes: 12e12.asUInt64, freeBytes: 1.6e12.asUInt64, fileSystem: "apfs"),
            Volume(mountPoint: "/Volumes/Local Disk", name: "Local Disk", bsdName: "disk10s1", diskID: "disk10", totalBytes: 4e12.asUInt64, freeBytes: 0, fileSystem: "ntfs", isReadOnly: true),
            Volume(mountPoint: "/Volumes/Backup", name: "Warehouse", bsdName: "disk9s1", diskID: "disk8", totalBytes: 30e12.asUInt64, freeBytes: 7e12.asUInt64, fileSystem: "apfs")])
        let engine = Engine(rules: AllRules.all, topology: topo, openAfter: 3, resolveAfter: 5)
        var storage = DiskSample(id: "disk4", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        var wdS = DiskSample(id: "disk10", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        var whS = DiskSample(id: "disk8", bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0, timeReadNs: 0, timeWriteNs: 0)
        var free: UInt64 = 7e12.asUInt64
        var folx = ProcessSample(pid: 300, name: "Torrent", bundleID: "com.example.torrent", bytesRead: 0, bytesWritten: 0)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<40 {
            storage.bytesRead += 6_000_000; storage.opsRead += 300; storage.timeReadNs += 300 * 60_000_000
            wdS.bytesRead += 40_000_000; wdS.opsRead += 38; wdS.timeReadNs += 38 * 22_000_000
            whS.bytesWritten += 40_000_000; whS.opsWritten += 45; whS.timeWriteNs += 45 * 19_000_000
            free -= 40_000_000
            folx.bytesRead += 6_000_000
            engine.evaluate(Frame(timestamp: t0.addingTimeInterval(Double(i)), disks: [storage, wdS, whS], processes: [folx],
                                  openFiles: [300: [OpenFile(path: "/Volumes/Archive/Downloads/a.mkv", mountPoint: "/Volumes/Archive", sizeBytes: 3_000_000_000)]],
                                  volumeFree: ["/Volumes/Backup": free, "/Volumes/Archive": 1.6e12.asUInt64]))
        }
        let transfers = engine.findings.filter { $0.rule == "transfer" }
        #expect(transfers.count == 1)
        #expect(transfers.first?.subject == "External Disk to Warehouse")
        #expect(transfers.first?.confidence == .confirmed)
        // and the USB 2 hub is called out for the busy WD disk
        let link = engine.findings.first { $0.rule == "link" }
        #expect(link?.verdict == "External Disk is at its link ceiling")
        #expect(link?.severity == .slow)
        #expect(link?.actions.first?.title == "Connect it directly or through a USB 3 hub")
    }
}

extension Double {
    var asUInt64: UInt64 { UInt64(self) }
}

@Suite struct HelperParsingTests {
    @Test func fsUsageLinesFoldIntoPerProcessPerFileBytes() {
        let text = """
        18:05:01.123456  RdData[A]   D=0x01c5f2e0  B=0x20000  /dev/disk4s2  /Volumes/Archive/movie.mkv  0.000123 W  cp.85879
        18:05:01.223456  RdData[A]   D=0x01c5f2f0  B=0x20000  /dev/disk4s2  /Volumes/Archive/movie.mkv  0.000100 W  cp.85879
        18:05:01.323456  WrData[A]   D=0x00000010  B=0x100000  /dev/disk3s5  /Users/user/movie.mkv  0.000300 W  cp.85879
        18:05:01.423456  RdData[A]   D=0x00abc000  B=0x4000  /dev/disk4s2  /Volumes/Archive/seed1.mkv  0.010000 W  Torrent.64026
        18:05:01.523456  fstat64     F=5  0.000001  Torrent.64026
        garbage line without the shape
        """
        let samples = HelperWork.parseFSUsage(text)
        #expect(samples.count == 3)
        let cp = samples.first { $0.name == "cp" && $0.path.hasPrefix("/Volumes/Archive") }
        #expect(cp?.readBytes == 0x40000)
        #expect(cp?.reads == 2)
        let dst = samples.first { $0.path == "/Users/user/movie.mkv" }
        #expect(dst?.writeBytes == 0x100000)
        let seed = samples.first { $0.name == "Torrent" }
        #expect(seed?.readBytes == 0x4000)
    }
}

@Suite struct HelperMergeTests {
    @Test @MainActor func rootProcessesJoinTheFrameAndTheAppsOwnListingWins() {
        var procs = [ProcessSample(pid: 10, name: "cp", bytesRead: 5, bytesWritten: 5)]
        var files: [Int32: [OpenFile]] = [10: [OpenFile(path: "/Volumes/Archive/a.mkv", mountPoint: "/Volumes/Archive", sizeBytes: 1)]]
        let snap = HelperSnapshot(takenAt: Date(), processes: [
            ProcessSample(pid: 10, name: "cp", bytesRead: 1, bytesWritten: 1),           // already seen: ignored
            ProcessSample(pid: 1, name: "ddrescue", bytesRead: 900, bytesWritten: 900),   // root: added
            ProcessSample(pid: 99, name: "Garlo", bytesRead: 1, bytesWritten: 1),         // the app itself: never
        ], openFiles: [
            10: [OpenFile(path: "/Volumes/Archive/other.mkv", mountPoint: "/Volumes/Archive", sizeBytes: 1)],
            1: [OpenFile(path: "/Volumes/Backup/image.img", mountPoint: "/Volumes/Backup", sizeBytes: 4_000_000_000)],
        ])
        Engine.merge(snap, into: &procs, openFiles: &files, ownPID: 99)
        #expect(procs.map(\.name) == ["cp", "ddrescue"])
        #expect(procs.first { $0.pid == 10 }?.bytesRead == 5)
        #expect(files[10]?.first?.path == "/Volumes/Archive/a.mkv")
        #expect(files[1]?.first?.path == "/Volumes/Backup/image.img")
    }
}
