import SwiftUI
import GarloCore

/// The card is the product: verdict, cause, evidence in monospace, actions,
/// confidence. Compact for notices.
struct FindingCard: View {
    @Environment(AppStore.self) private var store
    let finding: Finding
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(finding.verdict)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                SeverityPill(text: pillText, severity: finding.severity)
            }
            Text(finding.cause)
                .font(.system(size: compact ? 12 : 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(compact ? .secondary : .primary)

            if !compact, !finding.contributors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(finding.contributors, id: \.self) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(c.name).font(.system(size: 12, weight: .semibold))
                            Text(c.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !finding.evidence.isEmpty {
                Text(finding.evidence.joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: 6))
            }

            if !compact || !finding.actions.isEmpty {
                ActionRow(finding: finding)
            }

            if !compact {
                Text(confidenceLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 14)
        .padding(.vertical, compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(finding.confidence == .suspected ? Color.hairlineStrong : finding.severity.color)
                .frame(width: 3)
                .padding(.vertical, 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 0.5))
    }

    private var pillText: String {
        finding.confidence == .suspected ? "Suspected" : "\(finding.severity.rawValue) · confirmed"
    }

    private var confidenceLine: String {
        var parts: [String] = []
        if let by = finding.confirmedBy { parts.append("Confirmed by \(by).") }
        else if let p = finding.pending { parts.append("Suspected: \(p).") }
        parts.append("Started \(Units.clock(finding.started)).")
        if let t = finding.tierHint { parts.append(t) }
        return parts.joined(separator: " ")
    }
}

struct ActionRow: View {
    @Environment(AppStore.self) private var store
    let finding: Finding

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(finding.actions.enumerated()), id: \.offset) { i, a in
                Button { store.perform(a, of: finding) } label: { Text(a.title) }
                    .buttonStyle(ChipButtonStyle(prominent: i == 0 && a.kind != .none))
                    .help(a.effect ?? a.title)
                    .disabled(a.kind == .none)
            }
            Button { store.markWrong(finding) } label: { Text("Wrong") }
                .buttonStyle(ChipButtonStyle(prominent: false))
                .help("Hide this finding and keep the samples as a fixture")
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : (enabled ? 1 : 0.8))
    }
}

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// "Show file layout": the extent walk result.
struct LayoutSheet: View {
    @Environment(AppStore.self) private var store
    let request: AppStore.LayoutRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File layout")
                .font(.system(size: 15, weight: .semibold))
            Text(request.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !request.done {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Walking the extent map…") }
                    .font(.system(size: 12))
            } else if let l = request.layout {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(Units.bytes(Double(l.sizeBytes))) }
                    GridRow { Text("Pieces").foregroundStyle(.secondary); Text(Units.count(l.pieces) + (l.truncated ? " or more" : "")) }
                    GridRow { Text("Median piece").foregroundStyle(.secondary); Text(Units.binaryBytes(Double(l.medianPieceBytes))) }
                    GridRow { Text("Physical span").foregroundStyle(.secondary); Text(Units.bytes(Double(l.physicalSpanBytes))) }
                    GridRow { Text("Per 8 MB").foregroundStyle(.secondary); Text(String(format: "%.2f pieces", l.piecesPer8MB)) }
                }
                .font(.system(size: 12, design: .monospaced))
                Text(l.isFragmented
                     ? "Reading this file sequentially is random I/O. Copying it once to a volume with free space in large runs makes the copy sequential."
                     : "This file is laid out sequentially; its layout is not the limit.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Garlo cannot read this file.").font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("Done") { store.layoutSheet = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
