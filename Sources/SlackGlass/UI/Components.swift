import SwiftUI

struct Avatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 30
    var online: Bool? = nil

    private var color: Color {
        let palette: [Color] = [.orange, .blue, .purple, .pink, .green, .teal, .indigo, .red]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }

    var body: some View {
        RemoteImage(url: url) {
            ZStack {
                color.opacity(0.85)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .overlay(alignment: .bottomTrailing) {
            if let online {
                Circle()
                    .fill(online ? Color.green : Color.clear)
                    .overlay(Circle().strokeBorder(online ? Color.black.opacity(0.5) : Color.white.opacity(0.55), lineWidth: online ? 1.5 : 1.2))
                    .frame(width: max(7, size * 0.3), height: max(7, size * 0.3))
                    .offset(x: 2, y: 2)
                    .help(online ? "Active" : "Away")
            }
        }
    }
}

struct ReasonPill: View {
    let reason: InboxReason

    private var color: Color {
        switch reason {
        case .dm: .pink
        case .group: .orange
        case .mention: .blue
        case .thread: .purple
        case .keyword: .teal
        }
    }

    var body: some View {
        Text(reason.label)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.45)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
    }
}

/// Simple wrapping layout for reactions and attachments.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > bounds.width { y += rowH + spacing; x = 0; rowH = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

enum TimeFormat {
    static func relative(_ d: Date) -> String {
        let s = -d.timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d jj:mm")
        return f
    }()

    static func stamp(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? clock.string(from: d) : dayClock.string(from: d)
    }
}

/// A scroll view that is only as tall as its content (up to `maxHeight`), so short lists hug their card.
/// Measures once instead of ViewThatFits, which lays the whole list out twice on every redraw.
struct FitScroll<Content: View>: View {
    var maxHeight: CGFloat = .infinity
    /// Called whenever the content's height changes (images loading, messages arriving).
    var onHeightChange: ((CGFloat) -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 1

    var body: some View {
        ScrollView(showsIndicators: false) {
            content()
                .background(GeometryReader { g in Color.clear.preference(key: FitHeightKey.self, value: g.size.height) })
        }
        .frame(maxHeight: min(height, maxHeight))
        .onPreferenceChange(FitHeightKey.self) { h in
            if abs(h - height) > 0.5 {
                height = h
                onHeightChange?(h)
            }
        }
    }
}

private struct FitHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
