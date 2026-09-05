import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import CoreWLAN
import SystemConfiguration

// MARK: - Network interfaces

/// Per-interface counters from `sysctl NET_RT_IFLIST2`. Tier 0.
public enum NetworkSampler {
    public static func sample() -> [NetworkSample] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [] }
        var out: [NetworkSample] = []
        var offset = 0
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                defer { offset += Int(hdr.ifm_msglen) }
                guard hdr.ifm_msglen > 0 else { break }
                guard Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len else { continue }
                let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let flags = Int32(m.ifm_flags)
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
                var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                guard if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil else { continue }
                let name = String(cString: nameBuf)
                // virtual and Apple-internal interfaces are noise
                if name.hasPrefix("anpi") || name.hasPrefix("ap") || name.hasPrefix("awdl") || name.hasPrefix("llw")
                    || name.hasPrefix("bridge") || name.hasPrefix("gif") || name.hasPrefix("stf") || name.hasPrefix("vmenet") { continue }
                let d = m.ifm_data
                out.append(NetworkSample(name: name, bytesIn: d.ifi_ibytes, bytesOut: d.ifi_obytes,
                                         packetsIn: d.ifi_ipackets, packetsOut: d.ifi_opackets,
                                         errorsIn: d.ifi_ierrors, errorsOut: d.ifi_oerrors, drops: d.ifi_iqdrops,
                                         baudrate: d.ifi_baudrate))
            }
        }
        return out
    }

    /// Name of the interface carrying the default route, and the gateway.
    public static func defaultRoute() -> (interface: String, gateway: String)? {
        guard let store = SCDynamicStoreCreate(nil, "Garlo" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let iface = dict["PrimaryInterface"] as? String else { return nil }
        return (iface, dict["Router"] as? String ?? "")
    }
}

// MARK: - Wi-Fi

public enum WiFiSampler {
    public static func sample() -> WiFiSample? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { return nil }
        let channel = iface.wlanChannel()
        let band: Double = {
            switch channel?.channelBand {
            case .band2GHz: return 2.4
            case .band5GHz: return 5
            case .band6GHz: return 6
            default: return 0
            }
        }()
        let width: Int = {
            switch channel?.channelWidth {
            case .width20MHz: return 20
            case .width40MHz: return 40
            case .width80MHz: return 80
            case .width160MHz: return 160
            default: return 0
            }
        }()
        return WiFiSample(interface: iface.interfaceName ?? "en0",
                          transmitRateMbps: iface.transmitRate(),
                          rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
                          channel: channel?.channelNumber ?? 0, bandGHz: band, widthMHz: width,
                          connected: iface.transmitRate() > 0)
    }
}

// MARK: - CPU

public enum CPUSampler {
    static let efficiencyCores: Int = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // perflevel1 is "Efficiency" on Apple silicon; absent on Intel
        guard sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0 else { return 0 }
        return Int(n)
    }()

    public static func sample() -> CPUSample? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var cores: [CPUSample.Core] = []
        let states = Int(CPU_STATE_MAX)
        for i in 0..<Int(count) {
            let base = i * states
            cores.append(CPUSample.Core(user: UInt64(info[base + Int(CPU_STATE_USER)]),
                                        system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                                        idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
                                        nice: UInt64(info[base + Int(CPU_STATE_NICE)])))
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return CPUSample(cores: cores, efficiencyCores: min(efficiencyCores, cores.count), loadAverage1: load[0], speedLimit: speedLimit())
    }

    /// Percent of full speed the CPU may run at (`pmset -g therm`).
    public static func speedLimit() -> Int {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyCPUPowerStatus(&dict) == kIOReturnSuccess, let d = dict?.takeRetainedValue() as? [String: Any] else { return 100 }
        return (d[kIOPMCPUPowerLimitProcessorSpeedKey] as? NSNumber)?.intValue ?? 100
    }
}

// MARK: - Memory

public enum MemorySampler {
    static let totalBytes: UInt64 = {
        var n: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &n, &size, nil, 0)
        return n
    }()

    static let pageSize: UInt64 = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.pagesize", &n, &size, nil, 0)
        return n > 0 ? UInt64(n) : 16384
    }()

    public static func sample() -> MemorySample? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let page = pageSize
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        let pressure: PressureLevel = level >= 4 ? .critical : (level >= 2 ? .warning : .normal)
        return MemorySample(totalBytes: totalBytes, pressure: pressure,
                            compressorBytes: UInt64(stats.compressor_page_count) * page,
                            swapUsedBytes: swap.xsu_used,
                            pageIns: stats.pageins, pageOuts: stats.pageouts,
                            swapIns: stats.swapins, swapOuts: stats.swapouts, pageSize: page)
    }
}

// MARK: - Thermal, power, GPU

public enum SystemSampler {
    public static func sample() -> SystemSample {
        let thermal: ThermalState = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return .nominal
            case .fair: return .fair
            case .serious: return .serious
            case .critical: return .critical
            @unknown default: return .nominal
            }
        }()
        var onBattery = false, charging = false
        var current: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
                if let state = desc[kIOPSPowerSourceStateKey] as? String { onBattery = state == kIOPSBatteryPowerValue }
                charging = desc[kIOPSIsChargingKey] as? Bool ?? false
                current = (desc[kIOPSCurrentKey] as? NSNumber)?.intValue
            }
        }
        var watts: Int?
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            watts = (adapter[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
        }
        return SystemSample(thermal: thermal,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                            onBattery: onBattery, charging: charging,
                            batteryCurrentMilliamps: current, adapterWatts: watts,
                            gpuUtilization: gpuUtilization())
    }

    static func gpuUtilization() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let stats = IORegistry.property(entry, "PerformanceStatistics") as? [String: Any],
               let util = (stats["Device Utilization %"] as? NSNumber)?.intValue {
                best = max(best ?? 0, util)
            }
        }
        return best
    }
}

// MARK: - Per-process network (nettop)

/// There is no public API for per-process network bytes; `nettop` prints
/// the same data. Run every few seconds while an interface is busy, and
/// degrade to nothing when its output changes shape.
public enum NetProcessSampler {
    public static func sample() -> [ProcessNetSample] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [ProcessNetSample] = []
        for line in text.split(separator: "\n") {
            // name.pid,bytes_in,bytes_out,
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, let dot = parts[0].lastIndex(of: "."),
                  let pid = Int32(parts[0][parts[0].index(after: dot)...]),
                  let bin = UInt64(parts[1]), let bout = UInt64(parts[2]) else { continue }
            let name = String(parts[0][..<dot])
            out.append(ProcessNetSample(pid: pid, name: name, bytesIn: bin, bytesOut: bout))
        }
        return out
    }
}

// MARK: - Latency and DNS probes

/// TCP connect timing. A refused connection still measures the round trip;
/// only a timeout counts as failure.
public enum LatencyProbe {
    public static func connectTime(host: String, port: UInt16, timeoutMs: Int = 2000) -> Double? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let started = DispatchTime.now()
        let rc = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc != 0 && errno != EINPROGRESS { return errno == ECONNREFUSED ? elapsed(since: started) : nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeoutMs))
        guard ready > 0 else { return nil }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 || err == ECONNREFUSED else { return nil }
        return elapsed(since: started)
    }

    /// Time to resolve a name, in ms; nil when it fails.
    public static func resolveTime(host: String) -> Double? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let started = DispatchTime.now()
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return nil }
        freeaddrinfo(res)
        return elapsed(since: started)
    }

    private static func elapsed(since t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
    }

    /// Names rotated for DNS timing so the resolver cache does not answer.
    public static let dnsNames = ["www.apple.com", "www.wikipedia.org", "www.cloudflare.com", "www.github.com", "www.mozilla.org"]
}
