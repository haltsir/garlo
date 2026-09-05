import SwiftUI
import GarloCore

/// The popover: Now (busy resources), Findings (open cards), History link.
struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            Divider()
            // The popover sizes to its content up to a limit, then scrolls.
            // A menu-bar window proposes no height, so the content is measured.
            ScrollView {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 60), 560))
            Divider()
            footer
        }
        .frame(width: 440)
        .onAppear { store.popoverOpen = true }
        .onDisappear { store.popoverOpen = false }
        .sheet(item: $store.layoutSheet) { req in
            LayoutSheet(request: req)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.nowItems.isEmpty && store.problems.isEmpty {
                idle
            } else {
                if !store.nowItems.isEmpty { nowSection }
                findingsSection
            }
            if !store.notices.isEmpty { noticesSection }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.image(for: .rest))
                .renderingMode(.template)
                .foregroundStyle(Color.accent)
            Text("Garlo")
                .font(.system(size: 16, weight: .semibold))
            if let worst = store.problems.filter({ $0.confidence == .confirmed }).map(\.severity).max() {
                let count = store.problems.filter { $0.confidence == .confirmed }.count
                SeverityPill(text: "\(count) \(worst.rawValue)", severity: worst)
            }
            Spacer()
            HeaderButton(icon: "clock.arrow.circlepath", help: "History") { open("history") }
            HeaderButton(icon: "gearshape", help: "Settings") { open("settings") }
            HeaderButton(icon: "power", help: "Quit Garlo") { store.quit() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Sections

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(Color.ok).frame(width: 8, height: 8)
                Text("Nothing is busy and nothing is open.")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))

            if let last = store.lastResolved {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Last resolved")
                    ResolvedCard(finding: last)
                }
            }
        }
    }

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Now")
            VStack(spacing: 0) {
                ForEach(Array(store.nowItems.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.leading, 12) }
                    NowRow(item: item)
                }
            }
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
        }
    }

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Findings")
                Spacer()
                Text(store.problems.isEmpty ? "none open" : "\(store.problems.count) open")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if store.problems.isEmpty {
                Text(store.nowItems.isEmpty ? "" : "Busy, but nothing is slower than it should be.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
            ForEach(store.problems) { f in
                FindingCard(finding: f)
            }
        }
    }

    private var noticesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Notices")
            ForEach(store.notices) { f in
                FindingCard(finding: f, compact: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open History") { open("history") }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            let o = store.engine.overhead
            Text("Sampling · \(String(format: "%.1f", o.cpuFraction * 100))% CPU · \(Units.bytes(Double(o.memoryBytes)))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Pieces

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }
}

struct SeverityPill: View {
    let text: String
    let severity: Severity
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(severity.color.opacity(0.14), in: Capsule())
            .foregroundStyle(severity.color)
    }
}

struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct NowRow: View {
    let item: AppStore.NowItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.figure)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text(item.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.hot ? Color.warn : .secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(item.hot ? Color.warn : Color.accent)
                            .frame(width: max(2, geo.size.width * min(1, item.fraction)))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

struct ResolvedCard: View {
    let finding: Finding
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(finding.verdict)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Units.clock(finding.started)) to \(Units.clock(finding.ended ?? finding.lastSeen))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(finding.cause)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.leading, 13)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Color.hairlineStrong).frame(width: 3).padding(.vertical, 1) }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .notice: return Color.hairlineStrong
        case .slow: return Color.warn
        case .stalled: return Color.crit
        }
    }
}

extension Color {
    static let accent = Color(light: Color(red: 0.12, green: 0.44, blue: 0.47), dark: Color(red: 0.34, green: 0.72, blue: 0.75))
    static let warn = Color(light: Color(red: 0.66, green: 0.39, blue: 0.04), dark: Color(red: 0.89, green: 0.65, blue: 0.24))
    static let crit = Color(light: Color(red: 0.70, green: 0.15, blue: 0.12), dark: Color(red: 0.95, green: 0.46, blue: 0.43))
    static let ok = Color(light: Color(red: 0.18, green: 0.49, blue: 0.31), dark: Color(red: 0.38, green: 0.76, blue: 0.54))
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let codeBackground = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.12)
    static let hairlineStrong = Color(light: Color(red: 0.73, green: 0.76, blue: 0.80), dark: Color(red: 0.23, green: 0.29, blue: 0.33))

    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}
