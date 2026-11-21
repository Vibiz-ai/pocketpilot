import PocketPilotCore
import SwiftUI

extension ComponentHealth {
    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .pending: return .orange
        case .ok: return .green
        case .failed: return .red
        }
    }
    var symbol: String {
        switch self {
        case .unknown: return "circle"
        case .pending: return "clock"
        case .ok: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

extension Component {
    var symbol: String {
        switch self {
        case .usb: return "cable.connector"
        case .screen: return "iphone"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .assistiveTouch: return "circle.circle"
        case .calibration: return "scope"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Small capsule: component name + health colour; full detail in the tooltip.
struct StatusPill: View {
    let component: Component
    let status: ComponentStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.health.color).frame(width: 7, height: 7)
            Image(systemName: component.symbol).imageScale(.small).foregroundStyle(.secondary)
            Text(component.title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(status.health.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(status.health.color.opacity(0.3), lineWidth: 0.5))
        .help("\(component.title): \(status.detail)" + (status.error.map { "\n\($0.why)\nFix: \($0.fix)" } ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(component.title) \(status.health.rawValue): \(status.detail)")
    }
}

struct StatusPillRow: View {
    let snapshot: StatusSnapshot
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Component.allCases, id: \.self) { c in StatusPill(component: c, status: snapshot[c]) }
        }
    }
}

/// What failed / why / how to fix, with an optional Retry.
struct ErrorCard: View {
    let error: PocketPilotError
    var retryTitle = "Retry"
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.what).font(.headline)
                Text(error.why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                    Text(error.fix).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                if let retry {
                    Button(retryTitle, action: retry).controlSize(.regular).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.25)))
        .textSelection(.enabled)
    }
}

/// A live status line: spinner / check / warning + text.
struct LiveStatusLine: View {
    enum Kind { case waiting, ok, warning }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .waiting: ProgressView().controlSize(.small)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            Text(text).foregroundStyle(kind == .ok ? .primary : .secondary)
        }
        .font(.callout)
    }
}

/// Numbered instructions.
struct InstructionList: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                    Text(.init(item)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Monospaced command with a copy button.
struct CopyField: View {
    let text: String
    var onCopy: (() -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let onCopy { onCopy() } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Simple wrapping layout for pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Recent log lines, newest at the bottom, auto-scrolling.
struct LogView: View {
    let entries: [LogEntry]
    var minimumLevel: LogLevel = .info

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        let shown = entries.filter { $0.level >= minimumLevel }.suffix(200)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(shown) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.time.string(from: e.date)).foregroundStyle(.tertiary)
                            Text(e.category).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(e.message).foregroundStyle(e.level.color).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .id(e.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .onChange(of: shown.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .overlay {
            if shown.isEmpty { Text("Nothing logged yet").font(.callout).foregroundStyle(.secondary) }
        }
    }
}
