import Foundation
import GarloCore

// garlo: command-line front end over GarloCore.
//
//   garlo sample [seconds]  print live disk rates and findings once per second
//   garlo topology          print disks, links and volumes
//   garlo layout <file>     walk a file's extent map
//   garlo record <out.json> [seconds]   capture a fixture from the live machine
//   garlo replay <fixture.json>         run a fixture through the rules

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("usage: garlo sample [seconds] | system [seconds] | topology | layout <file> | record <out.json> [seconds] | replay <fixture.json>")
    exit(2)
}

func printFinding(_ f: Finding, prefix: String) {
    print("\(prefix) [\(f.severity.rawValue) · \(f.confidence.rawValue)] \(f.verdict)")
    print("    \(f.cause)")
    for c in f.contributors { print("    + \(c.name): \(c.detail)") }
    for e in f.evidence { print("    | \(e)") }
    for a in f.actions { print("    > \(a.title)\(a.effect.map { " (\($0))" } ?? "")") }
    if let p = f.pending { print("    ? \(p)") }
    if let by = f.confirmedBy { print("    confirmed by \(by)") }
    if let t = f.tierHint { print("    \(t)") }
}

@MainActor
func runSample(seconds: Int?, record: URL?) async {
    let engine = Engine()
    engine.onEvent = { event in
        switch event {
        case .opened(let f): printFinding(f, prefix: "OPEN     ")
        case .confirmed(let f): printFinding(f, prefix: "CONFIRMED")
        case .resolved(let f): print("RESOLVED  \(f.verdict) (\(Units.clock(f.started)) to \(Units.clock(f.ended ?? Date())))")
        case .updated: break
        }
    }
    engine.setTopology(TopologySampler.sample())
    if record != nil { engine.recording = Recording(note: "captured by garlo record", topology: engine.topology) }
    var n = 0
    while seconds == nil || n < seconds! {
        await engine.tick()
        n += 1
        let busy = engine.latestRates.filter { !$0.isIdle }
        let line = busy.map { r in
            "\(engine.topology.displayName(forDisk: r.id)) r \(Units.rate(r.readBytesPerSec)) w \(Units.rate(r.writeBytesPerSec)) \(Units.ops(r.opsPerSec)) \(Units.ms(r.serviceMsPerOp))/op depth \(String(format: "%.1f", r.queueDepth))"
        }.joined(separator: "  |  ")
        print("\(Units.clock(Date())) \(line.isEmpty ? "idle" : line)  (sample \(String(format: "%.1f", engine.lastSampleCost * 1000)) ms)")
        try? await Task.sleep(for: .seconds(1))
    }
    if let record, var rec = engine.recording {
        rec.topology = engine.topology
        do {
            try rec.save(record)
            print("wrote \(rec.frames.count) frames to \(record.path)")
        } catch {
            print("could not write \(record.path): \(error)")
            exit(1)
        }
    }
}

guard let command = args.first else { usage() }

switch command {
case "sample":
    await runSample(seconds: args.count > 1 ? Int(args[1]) : nil, record: nil)

case "system":
    let n = args.count > 1 ? Int(args[1]) ?? 5 : 5
    let engine = Engine()
    engine.setTopology(TopologySampler.sample())
    for _ in 0..<n {
        await engine.tick()
        let w = engine.window
        var parts: [String] = []
        if let c = w.cpuRates(last: 1).last {
            parts.append("CPU P \(Int(c.performanceUtilisation * 100))% E \(Int(c.efficiencyUtilisation * 100))% sys \(Int(c.systemFraction * 100))% load \(String(format: "%.1f", c.loadAverage1)) limit \(c.speedLimit)%")
        }
        if let m = w.latestMemory {
            parts.append("mem \(m.pressure.rawValue) comp \(Units.bytes(Double(m.compressorBytes))) swap \(Units.bytes(Double(m.swapUsedBytes))) pageouts \(Units.rate(w.pageOutRate(last: 5)))")
        }
        if let sys = w.latestSystem {
            parts.append("thermal \(sys.thermal.rawValue)\(sys.lowPowerMode ? " lowpower" : "") gpu \(sys.gpuUtilization.map { "\($0)%" } ?? "?")")
        }
        for r in w.latestNetworkRates() where r.bytesPerSec > 10_000 || r.name == w.primaryInterface {
            parts.append("\(r.name) in \(Units.rate(r.inBytesPerSec)) out \(Units.rate(r.outBytesPerSec))\(r.utilisation.map { " \(Int($0 * 100))% of \(r.baudrate / 1_000_000) Mb/s" } ?? "")")
        }
        if let wifi = w.latestWiFi {
            parts.append("wifi \(wifi.interface) \(Int(wifi.transmitRateMbps)) Mb/s rssi \(wifi.rssi) noise \(wifi.noise) ch \(wifi.channel) \(wifi.bandGHz) GHz \(wifi.widthMHz) MHz")
        }
        for l in w.latestFrame?.latency ?? [] {
            parts.append("\(l.target.rawValue) \(l.milliseconds.map { Units.ms($0) } ?? "timeout")")
        }
        let top = w.processCPURates(last: 1).prefix(2).map { "\($0.name) \(String(format: "%.1f", $0.cores)) cores" }.joined(separator: ", ")
        if !top.isEmpty { parts.append("top " + top) }
        let netTop = w.processNetRates(last: 5).prefix(2).map { "\($0.name) \(Units.rate($0.bytesPerSec))" }.joined(separator: ", ")
        if !netTop.isEmpty { parts.append("net " + netTop) }
        print(parts.joined(separator: "\n  "))
        print("  (sample \(String(format: "%.1f", engine.lastSampleCost * 1000)) ms)")
        try? await Task.sleep(for: .seconds(1))
    }

case "candidates":
    // debugging: what every rule proposes on each tick, before the lifecycle
    let n = args.count > 1 ? Int(args[1]) ?? 20 : 20
    let engine = Engine()
    engine.setTopology(TopologySampler.sample())
    for _ in 0..<n {
        await engine.tick()
        let w = engine.window
        var explained = Set<String>()
        var lines: [String] = []
        for rule in AllRules.all {
            var ww = w
            ww.explainedDisks = explained
            for c in rule.evaluate(ww) {
                lines.append("\(c.rule): \(c.verdict) [\(c.severity.rawValue)\(c.confirmedBy.map { ", confirmed by \($0)" } ?? "")]")
                explained.formUnion(c.explainsDisks)
            }
        }
        let drains = w.diskIDs.compactMap { id -> String? in
            guard let d = w.freeSpaceDrain(disk: id, last: 15), d > 100_000 else { return nil }
            return "\(w.topology.displayName(forDisk: id)) drains \(Units.rate(d))"
        }
        print("\(Units.clock(Date())) \(lines.isEmpty ? "no candidates" : lines.joined(separator: " | "))\(drains.isEmpty ? "" : "  {\(drains.joined(separator: ", "))}")")
        try? await Task.sleep(for: .seconds(1))
    }

case "probe":
    let host = args.count > 1 ? args[1] : "one.one.one.one"
    let gw = NetworkSampler.defaultRoute()
    print("default route: \(gw.map { "\($0.interface) via \($0.gateway)" } ?? "none")")
    if let gw, !gw.gateway.isEmpty {
        for _ in 0..<3 { print("gateway \(LatencyProbe.connectTime(host: gw.gateway, port: 80, timeoutMs: 1500).map { Units.ms($0) } ?? "timeout")") }
    }
    for _ in 0..<3 { print("\(host) \(LatencyProbe.connectTime(host: host, port: 443).map { Units.ms($0) } ?? "timeout")") }
    for name in LatencyProbe.dnsNames.prefix(3) { print("dns \(name) \(LatencyProbe.resolveTime(host: name).map { Units.ms($0) } ?? "failed")") }

case "topology":
    let topo = TopologySampler.sample()
    for d in topo.disks {
        var line = "\(d.id)  \(d.name)  \(Units.bytes(Double(d.sizeBytes)))  \(d.interconnect)\(d.isInternal ? " internal" : " external")  \(d.media.rawValue)"
        if let u = d.usb {
            line += "  USB \(u.speed.label)"
            if let cap = u.capableSpeed, cap.rawValue > u.speed.rawValue { line += " (supports \(cap.label))" }
            if !u.hubs.isEmpty { line += " via \(u.hubs.joined(separator: " > "))" }
            line += " on \(u.controller)"
        }
        print(line)
        for v in topo.volumes(on: d.id) {
            print("    \(v.bsdName)  \(v.mountPoint)  \(Units.percent(v.usedFraction)) used, \(Units.bytes(Double(v.freeBytes))) free  \(v.fileSystem)" + (v.defragmentEnabled.map { "  defrag \($0 ? "on" : "off")" } ?? ""))
        }
    }
    for v in topo.volumes where v.diskID == nil {
        print("?  \(v.bsdName)  \(v.mountPoint)  (no physical disk found)")
    }

case "layout":
    guard args.count > 1 else { usage() }
    let started = Date()
    guard let l = FileLayout.probe(path: args[1]) else { print("cannot read \(args[1])"); exit(1) }
    print(l.path)
    print("  size \(Units.bytes(Double(l.sizeBytes)))  pieces \(Units.count(l.pieces))\(l.truncated ? "+" : "")  median \(Units.binaryBytes(Double(l.medianPieceBytes)))  span \(Units.bytes(Double(l.physicalSpanBytes)))  \(String(format: "%.2f", l.piecesPer8MB)) pieces per 8 MB  \(l.isFragmented ? "fragmented" : "sequential")")
    print("  walked in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")

case "record":
    guard args.count > 1 else { usage() }
    let seconds = args.count > 2 ? Int(args[2]) ?? 60 : 60
    await runSample(seconds: seconds, record: URL(fileURLWithPath: args[1]))

case "replay":
    guard args.count > 1 else { usage() }
    do {
        let rec = try Recording.load(URL(fileURLWithPath: args[1]))
        print("\(rec.frames.count) frames, \(rec.topology.disks.count) disks, \(rec.layouts.count) layouts. \(rec.note)")
        let (engine, events) = await rec.replay()
        for e in events {
            switch e {
            case .opened(let f): printFinding(f, prefix: "OPEN      \(Units.clock(f.started))")
            case .confirmed(let f): print("CONFIRMED \(Units.clock(f.lastSeen)) \(f.verdict) by \(f.confirmedBy ?? "?")")
            case .resolved(let f): print("RESOLVED  \(Units.clock(f.ended ?? f.lastSeen)) \(f.verdict)")
            case .updated: break
            }
        }
        print("--- open at end")
        for f in engine.findings { printFinding(f, prefix: "") }
    } catch {
        print("cannot load \(args[1]): \(error)")
        exit(1)
    }

default:
    usage()
}
