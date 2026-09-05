import Foundation

/// Thresholds for the network, CPU, memory and thermal rules.
public enum SystemThresholds {
    public static let window = 15
    public static let longWindow = 30
    public static let hogUtilisation = 0.85
    public static let hogProcessShare = 0.6
    public static let wifiRateFraction = 0.3
    public static let wifiWeakRSSI = -75
    public static let wifiBusyFraction = 0.5
    public static let bufferbloatMs = 100.0
    public static let lossFraction = 0.005
    public static let dnsSlowMs = 300.0
    public static let cpuSaturation = 0.9
    public static let foregroundShare = 0.1
    public static let heavyCPU = 0.7
    public static let pageOutBytesPerSec = 5_000_000.0
    public static let runawayGrowthBytes: UInt64 = 500 * 1024 * 1024
    public static let gpuSaturation = 90
}

// MARK: - Helpers

extension Window {
    /// The interface the rules judge: the default route's, else the busiest.
    public var primaryRate: NetworkRate? {
        let all = latestNetworkRates()
        if let p = primaryInterface, let r = all.first(where: { $0.name == p }) { return r }
        return all.max { $0.bytesPerSec < $1.bytesPerSec }
    }

    public func interfaceLabel(_ name: String) -> String {
        if let w = latestWiFi, w.interface == name { return "Wi-Fi" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "VPN (\(name))" }
        return "Ethernet (\(name))"
    }

    /// Bundle id of a process the nettop listing named, via the rusage listing.
    func bundleID(pid: Int32) -> String? {
        latestFrame?.processes.first { $0.pid == pid }?.bundleID
    }

    var topCPUProcess: ProcessCPURate? { groupedCPURates(last: SystemThresholds.window).first }

    /// Per-process CPU with same-named processes (an app and its helpers,
    /// ten `yes` loops) merged, heaviest first.
    public func groupedCPURates(last seconds: Int) -> [ProcessCPURate] {
        var byName: [String: ProcessCPURate] = [:]
        var counts: [String: Int] = [:]
        for r in processCPURates(last: seconds) {
            counts[r.name, default: 0] += 1
            if var g = byName[r.name] {
                g.cores += r.cores
                g.footprintBytes += r.footprintBytes
                if g.bundleID == nil { g.bundleID = r.bundleID }
                byName[r.name] = g
            } else {
                byName[r.name] = r
            }
        }
        return byName.values.map { g in
            var r = g
            if let n = counts[g.name], n > 1 { r.name = "\(g.name) (\(n) processes)" }
            return r
        }.sorted { $0.cores > $1.cores }
    }

    func foregroundCPU(_ rates: [ProcessCPURate]) -> ProcessCPURate? {
        guard let pid = latestFrame?.foregroundPID,
              let name = latestFrame?.processes.first(where: { $0.pid == pid })?.name else { return nil }
        return rates.first { $0.pid == pid || $0.name == name || $0.name.hasPrefix(name + " (") }
    }

    /// The physical disk behind the boot volume.
    var bootDiskID: String? {
        topology.volumes.first { $0.mountPoint == "/System/Volumes/Data" || $0.mountPoint == "/" }?.diskID
    }
}

func showAction(_ name: String, bundleID: String?) -> Action {
    Action("Show \(name)", effect: "bring it forward to pause or quit it", kind: bundleID.map { .openApp(bundleID: $0) } ?? .none)
}

// MARK: - Network

/// One process is taking the whole link.
public struct NetworkHogRule: Rule {
    public let id = "nethog"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        guard let latest = w.primaryRate, let avg = w.networkAverage(interface: latest.name, last: T.window),
              let util = avg.utilisation, util >= T.hogUtilisation, w.networkRates(interface: latest.name, last: T.window).count >= 5 else { return [] }
        let label = w.interfaceLabel(latest.name)
        let procs = w.processNetRates(last: T.window)
        let total = procs.map(\.bytesPerSec).reduce(0, +)
        let top = procs.first
        let share = (top != nil && total > 0) ? top!.bytesPerSec / total : 0
        guard let top, share >= T.hogProcessShare else {
            return [Candidate(rule: id, subject: label, domain: .network,
                              verdict: "\(label) is saturated",
                              cause: "\(label) is carrying \(Units.rate(avg.bytesPerSec)) on a \(avg.baudrate / 1_000_000) Mb/s link.",
                              evidence: [pad(label) + "in \(Units.rate(avg.inBytesPerSec)) · out \(Units.rate(avg.outBytesPerSec)) · \(Units.percent(util)) of \(avg.baudrate / 1_000_000) Mb/s"],
                              severity: .notice, pending: "waiting for per-process bytes to name the process")]
        }
        let gw = w.latencies(.gateway).compactMap(\.milliseconds)
        let idle = gw.min() ?? 0
        let underLoad = gw.last ?? 0
        let inflated = gw.count >= 2 && underLoad >= idle * 2 && underLoad >= idle + 20
        let direction = top.outBytesPerSec >= top.inBytesPerSec ? "uploading" : "downloading"
        let bundle = w.bundleID(pid: top.pid)
        return [Candidate(
            rule: id, subject: label, domain: .network,
            verdict: "\(label) is saturated by \(top.name)",
            cause: "\(top.name) is \(direction) \(Units.rate(top.bytesPerSec)), \(Units.percent(share)) of everything on the link. Everything else waits behind it.",
            contributors: procs.prefix(3).map { Contributor(name: $0.name, detail: "\(Units.rate($0.bytesPerSec)), \(Units.percent(total > 0 ? $0.bytesPerSec / total : 0))", bundleID: w.bundleID(pid: $0.pid)) },
            evidence: [pad(label) + "in \(Units.rate(avg.inBytesPerSec)) · out \(Units.rate(avg.outBytesPerSec)) · \(Units.percent(util)) of \(avg.baudrate / 1_000_000) Mb/s",
                       pad("Gateway") + (gw.isEmpty ? "no probe yet" : "\(Units.ms(underLoad)) under load · \(Units.ms(idle)) idle")],
            actions: [Action("Pause \(top.name)", effect: "frees the link for everything else", kind: bundle.map { .openApp(bundleID: $0) } ?? .none)],
            severity: .slow,
            confirmedBy: inflated ? "gateway latency rising under load" : nil,
            pending: inflated ? nil : "waiting for gateway latency to rise under load"
        )]
    }
}

/// The air, not the link, is the limit.
public struct WiFiLimitedRule: Rule {
    public let id = "wifi"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        guard let wifi = w.latestWiFi, wifi.connected, wifi.transmitRateMbps > 0,
              let avg = w.networkAverage(interface: wifi.interface, last: T.longWindow),
              let util = avg.utilisation, util >= T.wifiBusyFraction else { return [] }
        let ticks = w.networkRates(interface: wifi.interface, last: T.longWindow).count
        let rateLow = wifi.transmitRateMbps < wifi.channelCeilingMbps * T.wifiRateFraction
        let signalWeak = wifi.rssi < T.wifiWeakRSSI
        guard rateLow || signalWeak else { return [] }
        let weak = signalWeak ? "Signal is weak (RSSI \(wifi.rssi) dBm)" : "Signal is fine (RSSI \(wifi.rssi) dBm)"
        let band = wifi.bandGHz < 3 ? " on the 2.4 GHz band" : ""
        var actions: [Action] = []
        if wifi.bandGHz < 3 { actions.append(Action("Switch to 5 GHz or move closer", effect: "the 2.4 GHz band tops out low and is crowded")) }
        else { actions.append(Action("Move closer to the access point", effect: "a stronger signal negotiates a faster rate")) }
        let sustained = ticks >= T.longWindow && rateLow && signalWeak
        return [Candidate(
            rule: id, subject: "Wi-Fi", domain: .network,
            verdict: "Wi-Fi is the limit",
            cause: "Transmit rate is \(Int(wifi.transmitRateMbps)) Mb/s on a channel that can carry \(Int(wifi.channelCeilingMbps)) Mb/s. \(weak)\(band).",
            evidence: [pad(wifi.interface) + "\(Units.rate(avg.bytesPerSec)) · \(Units.percent(util)) of air rate · \(Units.percent(avg.packetsPerSec > 0 ? avg.dropsPerSec / avg.packetsPerSec : 0)) drops",
                       pad("Air") + "\(Int(wifi.transmitRateMbps)) Mb/s · RSSI \(wifi.rssi) dBm · noise \(wifi.noise) · \(wifi.bandGHz) GHz \(wifi.widthMHz) MHz ch \(wifi.channel)"],
            actions: actions,
            severity: .slow,
            confirmedBy: sustained ? "rate and RSSI both low for \(T.longWindow) s" : (ticks >= T.longWindow ? (rateLow ? "rate low for \(T.longWindow) s" : "signal weak for \(T.longWindow) s") : nil),
            pending: ticks >= T.longWindow ? nil : "waiting \(T.longWindow - ticks) s for the rate and signal to hold"
        )]
    }
}

/// Latency inflating under load: packets queue in a buffer before the link.
public struct BufferbloatRule: Rule {
    public let id = "bufferbloat"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        guard let latest = w.primaryRate, let util = latest.utilisation, util >= 0.5 else { return [] }
        let gw = w.latencies(.gateway).compactMap(\.milliseconds)
        guard gw.count >= 3, let idle = gw.min(), let now = gw.last, now >= idle + T.bufferbloatMs else { return [] }
        let twice = gw.suffix(2).allSatisfy { $0 >= idle + T.bufferbloatMs }
        let label = w.interfaceLabel(latest.name)
        let top = w.processNetRates(last: T.window).first
        var actions: [Action] = []
        if let top { actions.append(Action("Pause \(top.name)", kind: w.bundleID(pid: top.pid).map { .openApp(bundleID: $0) } ?? .none)) }
        actions.append(Action("Enable smart queue management on the router", effect: "keeps latency flat under load"))
        return [Candidate(
            rule: id, subject: label, domain: .network,
            verdict: "\(label) is queueing under load",
            cause: "Round trip to the gateway is \(Units.ms(now)) under load against \(Units.ms(idle)) idle. Packets wait in a buffer before the link, so everything interactive feels slow while \(top?.name ?? "a transfer") runs.",
            evidence: [pad("Gateway") + "\(Units.ms(now)) under load · \(Units.ms(idle)) idle",
                       pad(label) + "\(Units.rate(latest.bytesPerSec)) · \(Units.percent(util)) of \(latest.baudrate / 1_000_000) Mb/s"],
            actions: actions,
            severity: .slow,
            confirmedBy: twice ? "two consecutive probes" : nil,
            pending: twice ? nil : "waiting for a second inflated probe"
        )]
    }
}

/// A single transfer crawling on an idle link with normal latency: the
/// remote end or the path is the limit, not this Mac. Confirmed by the
/// opt-in throughput test reaching the link rate.
public struct PathOrRemoteRule: Rule {
    public let id = "remote"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        guard let latest = w.primaryRate, let avg = w.networkAverage(interface: latest.name, last: T.longWindow),
              let util = avg.utilisation, util < 0.3, util >= 0.01,
              w.networkRates(interface: latest.name, last: T.longWindow).count >= T.longWindow else { return [] }
        let gw = w.latencies(.gateway).compactMap(\.milliseconds)
        guard let idle = gw.min(), let now = gw.last, now < idle + 50 else { return [] }
        let procs = w.processNetRates(last: T.longWindow)
        let total = procs.map(\.bytesPerSec).reduce(0, +)
        guard let top = procs.first, total > 0, top.bytesPerSec / total >= 0.8, top.bytesPerSec >= 200_000 else { return [] }
        let label = w.interfaceLabel(latest.name)
        let test = w.throughputTest
        let recent = test.map { Date().timeIntervalSince($0.at) < 600 } ?? false
        let confirmed = recent && test!.bytesPerSec >= Double(avg.baudrate) / 8 * 0.5 && test!.bytesPerSec >= top.bytesPerSec * 3
        return [Candidate(
            rule: id, subject: top.name, domain: .network,
            verdict: "The remote end is the limit for \(top.name)",
            cause: "\(top.name) is moving \(Units.rate(top.bytesPerSec)) while \(label) sits at \(Units.percent(util)) and latency is normal. Nothing on this Mac is holding it back."
                + (confirmed ? " A throughput test just reached \(Units.rate(test!.bytesPerSec))." : ""),
            contributors: [Contributor(name: top.name, detail: Units.rate(top.bytesPerSec), bundleID: w.bundleID(pid: top.pid))],
            evidence: [pad(label) + "\(Units.rate(avg.bytesPerSec)) · \(Units.percent(util)) of \(avg.baudrate / 1_000_000) Mb/s",
                       pad("Gateway") + "\(Units.ms(now)) · idle \(Units.ms(idle))",
                       pad("Test") + (test.map { "\(Units.rate($0.bytesPerSec)) at \(Units.clock($0.at))" } ?? "not run")],
            actions: [Action("Run a throughput test", effect: "5 s download against your chosen endpoint", kind: .throughputTest)],
            severity: .notice,
            confirmedBy: confirmed ? "throughput test reached the link" : nil,
            pending: confirmed ? nil : "run the throughput test to confirm the link itself is fine"
        )]
    }
}

/// Errors and drops on the interface.
public struct PacketLossRule: Rule {
    public let id = "loss"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        return w.interfaceNames.compactMap { name in
            guard let avg = w.networkAverage(interface: name, last: T.window), avg.packetsPerSec >= 100 else { return nil }
            let bad = avg.errorsPerSec + avg.dropsPerSec
            guard bad / avg.packetsPerSec >= T.lossFraction else { return nil }
            let label = w.interfaceLabel(name)
            return Candidate(
                rule: id, subject: label, domain: .network,
                verdict: "\(label) is dropping packets",
                cause: "\(Units.percent(bad / avg.packetsPerSec)) of packets are errors or drops. Every loss costs a retransmit and a stall.",
                evidence: [pad(label) + "\(String(format: "%.0f", avg.packetsPerSec)) packets/s · \(String(format: "%.1f", avg.errorsPerSec)) errors/s · \(String(format: "%.1f", avg.dropsPerSec)) drops/s"],
                actions: [Action(name.hasPrefix("en") && w.latestWiFi?.interface != name ? "Check the cable and switch port" : "Move closer or change the channel")],
                severity: .slow,
                confirmedBy: "interface counters over \(T.window) s"
            )
        }
    }
}

/// Name lookups taking too long.
public struct SlowDNSRule: Rule {
    public let id = "dns"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        let samples = w.latencies(.dns)
        guard samples.count >= 2 else { return [] }
        let last = samples.suffix(2)
        let slow = last.allSatisfy { ($0.milliseconds ?? .infinity) >= T.dnsSlowMs }
        guard slow else { return [] }
        let text = last.map { $0.milliseconds.map { Units.ms($0) } ?? "failed" }.joined(separator: ", ")
        return [Candidate(
            rule: id, subject: "DNS", domain: .network,
            verdict: "DNS is slow",
            cause: "Resolving a name takes \(text). Every new connection pays that before it starts.",
            evidence: [pad("Resolve") + text],
            actions: [Action("Use a different resolver", effect: "for example 1.1.1.1 or 9.9.9.9", kind: .openURL("x-apple.systempreferences:com.apple.Network-Settings.extension"))],
            severity: .notice,
            confirmedBy: "two consecutive lookups"
        )]
    }
}

// MARK: - CPU

/// Performance cores saturated, and who is doing it.
public struct CPUSaturatedRule: Rule {
    public let id = "cpu"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        let rates = w.cpuRates(last: T.window)
        guard rates.count >= 5 else { return [] }
        let p = rates.map(\.performanceUtilisation).reduce(0, +) / Double(rates.count)
        let e = rates.map(\.efficiencyUtilisation).reduce(0, +) / Double(rates.count)
        guard p >= T.cpuSaturation, let last = rates.last else { return [] }
        let procs = w.groupedCPURates(last: T.window)
        guard let top = procs.first else { return [] }
        let busyCores = procs.map(\.cores).reduce(0, +)
        let front = w.foregroundCPU(procs)
        let starved = front != nil && front!.name != top.name && busyCores > 0 && front!.cores / busyCores < T.foregroundShare
        let coreCount = last.perCore.count
        let pCores = Double(coreCount - last.efficiencyCores)
        // the per-process accounting agrees with the core counters, or the run queue overflows
        let overloaded = last.loadAverage1 > Double(coreCount) || busyCores >= pCores * 0.9
        let verdict = starved ? "\(front!.name) is starved by \(top.name)" : "\(top.name) is using all performance cores"
        let cause = starved
            ? "\(top.name) is taking \(String(format: "%.1f", top.cores)) cores while \(front!.name), the app in front, gets \(String(format: "%.1f", front!.cores)). Foreground work waits behind background work."
            : "\(top.name) is taking \(String(format: "%.1f", top.cores)) of \(last.perCore.count - last.efficiencyCores) performance cores. Anything else that needs the CPU now will wait."
        return [Candidate(
            rule: id, subject: "CPU", domain: .cpu,
            verdict: verdict, cause: cause,
            contributors: procs.prefix(3).map { Contributor(name: $0.name, detail: "\(String(format: "%.1f", $0.cores)) cores", bundleID: $0.bundleID) },
            evidence: [pad("CPU") + "P \(Units.percent(p)) · E \(Units.percent(e)) · kernel \(Units.percent(last.systemFraction)) · load \(String(format: "%.1f", last.loadAverage1)) on \(coreCount) cores",
                       pad(top.name) + "\(String(format: "%.1f", top.cores)) cores"],
            actions: [showAction(top.name, bundleID: top.bundleID)],
            severity: starved ? .slow : .notice,
            confirmedBy: overloaded ? (last.loadAverage1 > Double(coreCount) ? "load average above the core count" : "per-process CPU time adds up to the cores") : nil,
            pending: overloaded ? nil : "waiting for per-process CPU time to account for the load"
        )]
    }
}

/// The machine is slowing itself down on purpose.
public struct ThrottledRule: Rule {
    public let id = "throttle"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        let frames = w.frames.suffix(T.longWindow)
        let hits = frames.filter { ($0.cpu?.speedLimit ?? 100) < 100 || ($0.system?.thermal ?? .nominal) >= .serious }
        guard let last = frames.last, hits.count >= 3, hits.contains(where: { $0.timestamp == last.timestamp }) else { return [] }
        let limit = last.cpu?.speedLimit ?? 100
        let thermal = last.system?.thermal ?? .nominal
        let top = w.topCPUProcess
        let verdict = limit < 100 ? "CPU is throttled to \(limit) percent" : "Mac is thermally limited"
        var cause = limit < 100
            ? "The system has capped the CPU at \(limit) percent of full speed. Thermal state is \(thermal.rawValue)."
            : "Thermal state is \(thermal.rawValue); the system is trading speed for temperature."
        if let top { cause += " \(top.name) is producing most of the heat at \(String(format: "%.1f", top.cores)) cores." }
        let sustained = hits.count >= T.longWindow
        return [Candidate(
            rule: id, subject: "CPU", domain: .thermal,
            verdict: verdict, cause: cause,
            contributors: top.map { [Contributor(name: $0.name, detail: "\(String(format: "%.1f", $0.cores)) cores", bundleID: $0.bundleID)] } ?? [],
            evidence: [pad("Speed") + "limit \(limit)% · thermal \(thermal.rawValue) · \(hits.count) of \(frames.count) s"],
            actions: top.map { [showAction($0.name, bundleID: $0.bundleID)] } ?? [],
            severity: .slow,
            confirmedBy: sustained ? "persisting for \(T.longWindow) s" : nil,
            pending: sustained ? nil : "waiting to see it persist for \(T.longWindow) s"
        )]
    }
}

/// The app in front is pinned to one core; the wait is real and unfixable.
public struct SingleThreadedRule: Rule {
    public let id = "singlethread"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        let rates = w.cpuRates(last: T.longWindow)
        guard rates.count >= T.longWindow else { return [] }
        let procs = w.groupedCPURates(last: T.longWindow)
        guard let front = w.foregroundCPU(procs), front.cores >= 0.9, front.cores <= 1.15 else { return [] }
        let p = rates.map(\.performanceUtilisation).reduce(0, +) / Double(rates.count)
        let cores = rates.last?.perCore.count ?? 0
        guard cores > 2, p < 0.5 else { return [] }
        return [Candidate(
            rule: id, subject: front.name, domain: .cpu,
            verdict: "\(front.name) is limited to one core",
            cause: "\(front.name) has been using exactly one core for \(T.longWindow) s while the others idle. The task is single-threaded; nothing else on the Mac is slowing it.",
            evidence: [pad(front.name) + "\(String(format: "%.2f", front.cores)) cores · P cores \(Units.percent(p)) overall"],
            severity: .notice,
            confirmedBy: "sustained \(T.longWindow) s"
        )]
    }
}

// MARK: - Memory

/// Paging, compressing or swapping instead of computing.
public struct MemoryPressureRule: Rule {
    public let id = "memory"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        guard let m = w.latestMemory else { return [] }
        let pageOuts = w.pageOutRate(last: T.window)
        guard m.pressure >= .warning || pageOuts >= T.pageOutBytesPerSec else { return [] }
        let procs = w.processCPURates(last: 1).sorted { $0.footprintBytes > $1.footprintBytes }
        let top = procs.first
        let swapping = m.pressure == .critical || pageOuts >= T.pageOutBytesPerSec
        var bootWrite = 0.0
        if let boot = w.bootDiskID { bootWrite = DiskSummary(rates: w.rates(disk: boot, last: T.window)).writeBytesPerSec }
        let confirmed = pageOuts > 0 && bootWrite >= pageOuts * 0.5
        var cause = swapping ? "Memory pressure is \(m.pressure.rawValue) and the Mac is paging out \(Units.rate(pageOuts)) to the boot disk." : "Memory pressure is \(m.pressure.rawValue); the compressor holds \(Units.bytes(Double(m.compressorBytes)))."
        if let top { cause += " \(top.name) holds \(Units.bytes(Double(top.footprintBytes))), the most of any app." }
        var actions: [Action] = []
        if let top { actions.append(Action("Quit \(top.name)", effect: "frees \(Units.bytes(Double(top.footprintBytes)))", kind: top.bundleID.map { .openApp(bundleID: $0) } ?? .none)) }
        actions.append(Action("Open Activity Monitor", kind: .openApp(bundleID: "com.apple.ActivityMonitor")))
        return [Candidate(
            rule: id, subject: "Memory", domain: .memory,
            verdict: swapping ? "Mac is swapping" : "Memory is under pressure",
            cause: cause,
            contributors: procs.prefix(3).map { Contributor(name: $0.name, detail: Units.bytes(Double($0.footprintBytes)), bundleID: $0.bundleID) },
            evidence: [pad("Pressure") + "\(m.pressure.rawValue) · compressor \(Units.bytes(Double(m.compressorBytes))) · swap \(Units.bytes(Double(m.swapUsedBytes))) of \(Units.bytes(Double(m.totalBytes))) RAM",
                       pad("Page-outs") + "\(Units.rate(pageOuts)) · boot disk writes \(Units.rate(bootWrite))"],
            actions: actions,
            severity: m.pressure == .critical ? .stalled : .slow,
            confirmedBy: confirmed ? "boot disk swap traffic" : nil,
            pending: confirmed ? nil : "waiting for swap traffic on the boot disk",
            explainsDisks: w.bootDiskID.map { [$0] } ?? []
        )]
    }
}

/// A process growing without bound.
public struct RunawayGrowthRule: Rule {
    public let id = "runaway"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        w.footprints.runaways(minGrowth: SystemThresholds.runawayGrowthBytes).prefix(2).map { r in
            let bundle = w.latestFrame?.processes.first { $0.pid == r.pid }?.bundleID
            return Candidate(
                rule: id, subject: r.name, domain: .memory,
                verdict: "\(r.name) is growing without bound",
                cause: "\(r.name) grew by \(Units.bytes(Double(r.growth))) over \(Units.duration(r.span)) without ever shrinking. That is what a leak looks like.",
                evidence: [pad(r.name) + "+\(Units.bytes(Double(r.growth))) in \(Units.duration(r.span))"],
                actions: [Action("Restart \(r.name)", effect: "returns the memory", kind: bundle.map { .openApp(bundleID: $0) } ?? .none)],
                severity: .notice,
                confirmedBy: "monotonic over \(Units.duration(r.span))"
            )
        }
    }
}

// MARK: - Power and GPU

public struct LowPowerModeRule: Rule {
    public let id = "lowpower"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        guard w.latestSystem?.lowPowerMode == true else { return [] }
        let rates = w.cpuRates(last: T.window)
        guard rates.count >= 5 else { return [] }
        let total = rates.map(\.total).reduce(0, +) / Double(rates.count)
        guard total >= T.heavyCPU else { return [] }
        let top = w.topCPUProcess
        return [Candidate(
            rule: id, subject: "Low Power Mode", domain: .thermal,
            verdict: "Low Power Mode is on during a heavy task",
            cause: "The CPU is \(Units.percent(total)) busy\(top.map { " with \($0.name)" } ?? "") while Low Power Mode caps its speed.",
            evidence: [pad("CPU") + "\(Units.percent(total)) busy · Low Power Mode on"],
            actions: [Action("Turn off Low Power Mode", kind: .openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension"))],
            severity: .notice,
            confirmedBy: "system setting"
        )]
    }
}

public struct ChargerRule: Rule {
    public let id = "charger"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        let frames = w.frames.suffix(T.longWindow)
        let draining = frames.filter { f in
            guard let s = f.system, !s.onBattery, !s.charging, let c = s.batteryCurrentMilliamps else { return false }
            return c < -100
        }
        guard let last = frames.last?.system, draining.count >= 5, draining.contains(where: { $0.timestamp == frames.last?.timestamp }) else { return [] }
        let watts = last.adapterWatts.map { "\($0) W" } ?? "unknown wattage"
        return [Candidate(
            rule: id, subject: "Charger", domain: .thermal,
            verdict: "The charger cannot sustain the load",
            cause: "The Mac is plugged in but the battery is draining at \(-(last.batteryCurrentMilliamps ?? 0)) mA. The \(watts) adapter delivers less than the machine draws.",
            evidence: [pad("Power") + "adapter \(watts) · battery \(last.batteryCurrentMilliamps ?? 0) mA · \(draining.count) of \(frames.count) s"],
            actions: [Action("Use a higher-wattage charger")],
            severity: .slow,
            confirmedBy: draining.count >= T.longWindow ? "sustained \(T.longWindow) s" : nil,
            pending: draining.count >= T.longWindow ? nil : "waiting to see it persist"
        )]
    }
}

public struct GPUBoundRule: Rule {
    public let id = "gpu"
    public init() {}

    public func evaluate(_ w: Window) -> [Candidate] {
        let T = SystemThresholds.self
        let frames = w.frames.suffix(T.window)
        let gpu = frames.compactMap { $0.system?.gpuUtilization }
        guard gpu.count >= 5, gpu.reduce(0, +) / gpu.count >= T.gpuSaturation else { return [] }
        let rates = w.cpuRates(last: T.window)
        let p = rates.isEmpty ? 0 : rates.map(\.performanceUtilisation).reduce(0, +) / Double(rates.count)
        guard p < 0.5 else { return [] }
        let procs = w.groupedCPURates(last: T.window)
        let front = w.foregroundCPU(procs)
        return [Candidate(
            rule: id, subject: "GPU", domain: .cpu,
            verdict: "The GPU is the limit",
            cause: "The GPU is \(gpu.reduce(0, +) / gpu.count) percent busy while the CPU has room. \(front.map { "\($0.name) is in front; renderer-bound work such as export or a heavy page waits on the GPU." } ?? "Renderer-bound work waits on the GPU.")",
            evidence: [pad("GPU") + "\(gpu.reduce(0, +) / gpu.count)% · P cores \(Units.percent(p))"],
            severity: .notice,
            confirmedBy: "sustained \(gpu.count) s"
        )]
    }
}

public enum SystemRules {
    public static var all: [any Rule] {
        [NetworkHogRule(), WiFiLimitedRule(), BufferbloatRule(), PathOrRemoteRule(), PacketLossRule(), SlowDNSRule(),
         CPUSaturatedRule(), ThrottledRule(), SingleThreadedRule(),
         MemoryPressureRule(), RunawayGrowthRule(),
         LowPowerModeRule(), ChargerRule(), GPUBoundRule()]
    }
}

public enum AllRules {
    /// Order matters: composite rules first so standalone ones can stay quiet.
    public static var all: [any Rule] {
        [TransferRule(), MemoryPressureRule(), IOPSSaturationRule(), ContentionRule(), LinkCeilingRule(), VolumeFullRule(), DeviceSlowRule()]
            + SystemRules.all.filter { $0.id != "memory" }
    }
}
