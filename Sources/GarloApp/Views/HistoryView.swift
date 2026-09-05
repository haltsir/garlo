import SwiftUI
import GarloCore

/// History: one lane per resource with a sparkline of its primary metric
/// and findings as bars; a device page with the learned baseline, the
/// trend across the range, and the findings on that device.
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var range: Range = .week
    @State private var selectedLane: String?
    @State private var selectedFinding: Finding?
    @State private var lanes: [Lane] = []
    @State private var loadedAt = Date.distantPast

    enum Range: String, CaseIterable, Identifiable {
        case day = "24 h", week = "7 days", month = "30 days", quarter = "90 days"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self { case .day: 86400; case .week: 7 * 86400; case .month: 30 * 86400; case .quarter: 90 * 86400 }
        }
    }

    struct Lane: Identifiable, Hashable {
        var id: String            // resource key
        var name: String
        var detail: String
        var rows: [RollupStore.Row]
        var findings: [Finding]
        var now: String
        var nowDetail: String
        var isDisk: Bool { id.hasPrefix("disk:") }
        /// The primary metric per row, normalised 0 to 1 for the sparkline.
        var points: [(Date, Double)] {
            let values = rows.map { r -> Double in
                if id.hasPrefix("disk:") || id.hasPrefix("net:") { return r.bytesPerSec }
                return r.busy
            }
            let top = max(values.max() ?? 1, 1e-9)
            return zip(rows.map(\.minute), values.map { $0 / top }).map { ($0, $1) }
        }
    }

    private var from: Date { Date().addingTimeInterval(-range.seconds) }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                axis
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        if lanes.isEmpty {
                            Text("No history yet. Garlo keeps one-minute rollups from the moment it runs.")
                                .foregroundStyle(.secondary)
                                .padding(24)
                        }
                        ForEach(lanes) { lane in
                            LaneRow(lane: lane, from: from, to: Date(), selected: selectedLane == lane.id) { f in
                                selectedLane = lane.id
                                selectedFinding = f
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedLane = lane.id; selectedFinding = nil }
                            Divider()
                        }
                    }
                }
            }
            .frame(minWidth: 560)

            detail
                .frame(minWidth: 320, idealWidth: 320)
                .background(Color.surface)
        }
        .frame(minWidth: 960, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .task(id: range) { reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                reload()
            }
        }
    }

    // MARK: Axis

    private var axis: some View {
        HStack(spacing: 12) {
            Text("RESOURCE").frame(width: 140, alignment: .leading)
            GeometryReader { geo in
                let labels = axisLabels()
                ZStack(alignment: .leading) {
                    ForEach(labels, id: \.0) { label in
                        Text(label.1).position(x: geo.size.width * label.0, y: geo.size.height / 2)
                    }
                }
            }
            Text("NOW").frame(width: 110, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 32)
    }

    private func axisLabels() -> [(Double, String)] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = range == .day ? "HH:mm" : "d MMM"
        let n = 4
        return (0...n).map { i in
            let x = Double(i) / Double(n)
            return (x == 0 ? 0.04 : (x == 1 ? 0.96 : x), f.string(from: from.addingTimeInterval(range.seconds * x)))
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let f = selectedFinding {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Back to \(lanes.first { $0.id == selectedLane }?.name ?? "device")") { selectedFinding = nil }
                        .buttonStyle(.link)
                    FindingCard(finding: f)
                }
                .padding(16)
            }
        } else if let lane = lanes.first(where: { $0.id == selectedLane }) {
            DevicePage(lane: lane, range: range) { f in selectedFinding = f }
        } else {
            Text("Select a resource to see its baseline and trend, or a bar to see the finding as it was at the time.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Data

    private func reload() {
        let to = Date()
        let engine = store.engine
        let topo = engine.topology
        let findings = store.openFindings + store.history
        var out: [Lane] = []
        let keys: [String] = {
            var k = topo.disks.map { "disk:\($0.id)" }
            if let p = engine.window.primaryInterface { k.append("net:\(p)") }
            k += ["cpu", "memory", "thermal"]
            if let s = engine.store { for r in s.resources(from: from, to: to) where !k.contains(r) { k.append(r) } }
            return k
        }()
        let rates = Dictionary(engine.latestRates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for key in keys {
            let rows = engine.store?.rows(resource: key, from: from, to: to) ?? []
            var name = key, detail = "", now = "", nowDetail = ""
            var mine: [Finding] = []
            if key.hasPrefix("disk:") {
                let id = String(key.dropFirst(5))
                name = topo.displayName(forDisk: id)
                if let d = topo.disk(id) {
                    detail = [d.name, d.usb.map { "USB \($0.speed.label)" } ?? d.interconnect, d.media == .unknown ? nil : d.media.rawValue].compactMap { $0 }.joined(separator: " · ")
                }
                if let r = rates[id] {
                    now = Units.rate(r.bytesPerSec)
                    nowDetail = r.isIdle ? "idle" : Units.ops(r.opsPerSec)
                }
                mine = findings.filter { $0.explainsDisks.contains(id) || ($0.domain == .storage && $0.subject == name) || ($0.domain == .bus && $0.subject == name) }
            } else if key.hasPrefix("net:") {
                let iface = String(key.dropFirst(4))
                name = engine.window.interfaceLabel(iface)
                if let w = engine.window.latestWiFi, w.interface == iface { detail = "\(iface) · \(Int(w.transmitRateMbps)) Mb/s · \(w.bandGHz) GHz" } else { detail = iface }
                if let r = engine.window.latestNetworkRates().first(where: { $0.name == iface }) {
                    now = Units.rate(r.bytesPerSec)
                    nowDetail = r.utilisation.map { "\(Int($0 * 100))% of link" } ?? ""
                }
                mine = findings.filter { $0.domain == .network }
            } else if key == "cpu" {
                name = "CPU"
                if let c = engine.window.latestFrame?.cpu { detail = "\(c.performanceCores)P + \(c.efficiencyCores)E" }
                if let c = engine.window.cpuRates(last: 1).last { now = "\(Int(c.performanceUtilisation * 100))%"; nowDetail = c.speedLimit < 100 ? "limit \(c.speedLimit)%" : "full speed" }
                mine = findings.filter { $0.domain == .cpu }
            } else if key == "memory" {
                name = "Memory"
                if let m = engine.window.latestMemory { detail = Units.bytes(Double(m.totalBytes)); now = m.pressure.rawValue; nowDetail = "swap \(Units.bytes(Double(m.swapUsedBytes)))" }
                mine = findings.filter { $0.domain == .memory }
            } else if key == "thermal" {
                name = "Thermal"
                if let s = engine.window.latestSystem { now = s.thermal.rawValue; nowDetail = s.gpuUtilization.map { "GPU \($0)%" } ?? "" }
                mine = findings.filter { $0.domain == .thermal }
            }
            mine = mine.filter { ($0.ended ?? to) >= from }
            if rows.isEmpty && mine.isEmpty && !(key.hasPrefix("disk:") || key == "cpu" || key == "memory") { continue }
            out.append(Lane(id: key, name: name, detail: detail, rows: rows, findings: mine, now: now, nowDetail: nowDetail))
        }
        lanes = out
        loadedAt = to
    }
}

// MARK: - Lane

struct LaneRow: View {
    let lane: HistoryView.Lane
    let from: Date
    let to: Date
    let selected: Bool
    let onFinding: (Finding) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(lane.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)

            ZStack(alignment: .topLeading) {
                Sparkline(points: lane.points, from: from, to: to)
                    .frame(height: 36)
                GeometryReader { geo in
                    ForEach(lane.findings) { f in
                        let x0 = max(0, f.started.timeIntervalSince(from) / to.timeIntervalSince(from))
                        let x1 = min(1, (f.ended ?? to).timeIntervalSince(from) / to.timeIntervalSince(from))
                        if x1 > x0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(f.confidence == .suspected ? Color.hairlineStrong : f.severity.color)
                                .opacity(f.isOpen ? 0.95 : 0.7)
                                .frame(width: max(3, geo.size.width * (x1 - x0)), height: 8)
                                .offset(x: geo.size.width * x0, y: 2)
                                .help(f.verdict)
                                .onTapGesture { onFinding(f) }
                        }
                    }
                }
            }
            .frame(height: 36)

            VStack(alignment: .trailing, spacing: 2) {
                Text(lane.now).font(.system(size: 12, design: .monospaced))
                Text(lane.nowDetail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(selected ? Color.accent.opacity(0.08) : Color.clear)
    }
}

struct Sparkline: View {
    let points: [(Date, Double)]
    let from: Date
    let to: Date

    var body: some View {
        GeometryReader { geo in
            let span = to.timeIntervalSince(from)
            Path { p in
                var started = false
                var lastX: CGFloat = -10
                for (date, v) in points {
                    let x = geo.size.width * CGFloat(date.timeIntervalSince(from) / span)
                    let y = geo.size.height - 2 - (geo.size.height - 6) * CGFloat(v)
                    // a gap longer than a few minutes breaks the line
                    if !started || x - lastX > geo.size.width * 0.02 { p.move(to: CGPoint(x: x, y: y)); started = true } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    lastX = x
                }
            }
            .stroke(Color.accent, lineWidth: 1.5)
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height - 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 2))
            }
            .stroke(Color.hairline, lineWidth: 0.5)
        }
    }
}

// MARK: - Device page

struct DevicePage: View {
    @Environment(AppStore.self) private var store
    let lane: HistoryView.Lane
    let range: HistoryView.Range
    let onFinding: (Finding) -> Void

    @State private var smart: SMARTReport?

    private var baseline: RollupStore.Baseline? {
        let b = store.engine.window.baselines[lane.id]
        return (b?.busySeconds ?? 0) > 0 ? b : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lane.name).font(.system(size: 15, weight: .semibold))
                    Text(lane.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let smart {
                        Text(smart.status.map { "SMART \($0)" } ?? smart.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(smart.status == "Verified" ? Color.ok : (smart.status == nil ? Color.secondary : Color.crit))
                    }
                }
                .task(id: lane.id) {
                    smart = nil
                    guard lane.isDisk, store.helper.isAvailable else { return }
                    smart = await store.helper.smart(diskID: String(lane.id.dropFirst(5)))
                }

                if lane.isDisk {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Learned baseline")
                        if let b = baseline {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                GridRow { Text("Service time").foregroundStyle(.secondary); Text("\(Units.ms(b.serviceMs)) per op").font(.system(size: 12, design: .monospaced)) }
                                GridRow { Text("Best minute").foregroundStyle(.secondary); Text(Units.rate(b.readBytesPerSec)).font(.system(size: 12, design: .monospaced)) }
                                if b.linkBitsPerSec > 0 { GridRow { Text("Link").foregroundStyle(.secondary); Text("\(Int(b.linkBitsPerSec / 1e9)) Gb/s").font(.system(size: 12, design: .monospaced)) } }
                                GridRow { Text("Learned").foregroundStyle(.secondary); Text("\(b.learnedAt.formatted(date: .abbreviated, time: .omitted)), \(b.busySeconds / 60) busy min") }
                            }
                            .font(.system(size: 12))
                            Button("Reset baseline") { store.engine.resetBaseline(lane.id) }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                        } else {
                            Text("Not learned yet. Garlo needs ten busy minutes on this device; the baseline is the median service time over the last week.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Trend, service time")
                        let trend = dailyService()
                        if trend.count >= 2 {
                            TrendChart(points: trend, baseline: baseline?.serviceMs)
                                .frame(height: 64)
                            HStack { Text(trend.first!.0.formatted(date: .abbreviated, time: .omitted)); Spacer(); Text("Today") }
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let sentence = weekOverWeek() {
                                Text(sentence).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("Not enough busy days in this range yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Findings here")
                    if lane.findings.isEmpty {
                        Text("None in this range.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(lane.findings.sorted { $0.started > $1.started }) { f in
                        Button { onFinding(f) } label: {
                            HStack(spacing: 8) {
                                Text(f.verdict).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(f.isOpen ? "open" : f.started.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(f.confidence == .suspected ? Color.hairlineStrong : f.severity.color).frame(width: 3).padding(.vertical, 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    /// Median service time of busy minutes per day in the range.
    private func dailyService() -> [(Date, Double)] {
        let busy = lane.rows.filter { $0.opsPerSec >= 20 && $0.busy >= 0.3 && $0.serviceMs > 0 }
        let groups = Dictionary(grouping: busy) { Calendar.current.startOfDay(for: $0.minute) }
        return groups.keys.sorted().compactMap { day in
            guard let rows = groups[day], rows.count >= 3 else { return nil }
            let s = rows.map(\.serviceMs).sorted()
            return (day, s[s.count / 2])
        }
    }

    private func weekOverWeek() -> String? {
        let now = Date()
        let busy = lane.rows.filter { $0.opsPerSec >= 20 && $0.busy >= 0.3 && $0.serviceMs > 0 }
        let thisWeek = busy.filter { $0.minute >= now.addingTimeInterval(-7 * 86400) }.map(\.serviceMs).sorted()
        let earlier = busy.filter { $0.minute < now.addingTimeInterval(-7 * 86400) }.map(\.serviceMs).sorted()
        guard thisWeek.count >= 10, earlier.count >= 10 else { return nil }
        let a = thisWeek[thisWeek.count / 2], b = earlier[earlier.count / 2]
        let change = (a - b) / b
        if abs(change) < 0.1 { return "Service time is steady: \(Units.ms(a)) per op this week against \(Units.ms(b)) before." }
        return "Requests are \(Units.percent(abs(change))) \(change > 0 ? "slower" : "faster") than before this week: \(Units.ms(a)) per op against \(Units.ms(b))."
    }
}

struct TrendChart: View {
    let points: [(Date, Double)]
    let baseline: Double?

    var body: some View {
        GeometryReader { geo in
            let top = max(points.map(\.1).max() ?? 1, baseline ?? 0, 1e-9) * 1.1
            let x0 = points.first!.0.timeIntervalSince1970
            let span = max(1, points.last!.0.timeIntervalSince1970 - x0)
            if let b = baseline {
                let y = geo.size.height - geo.size.height * CGFloat(b / top)
                Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                    .stroke(Color.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            Path { p in
                for (i, pt) in points.enumerated() {
                    let x = geo.size.width * CGFloat((pt.0.timeIntervalSince1970 - x0) / span)
                    let y = geo.size.height - geo.size.height * CGFloat(pt.1 / top)
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.warn, lineWidth: 2)
        }
    }
}
