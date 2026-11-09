import AppKit
import SwiftUI

/// The frosted-glass look. On macOS 26 (when built with the macOS 26 SDK) this is Apple's
/// real Liquid Glass. Everywhere else it's a behind-window blur with a specular rim,
/// a soft top-left highlight and an inner glow — light, cold and see-through.
struct GlassBackground: View {
    var radius: CGFloat
    @AppStorage(PrefKey.glassTint) private var tint = 0.0

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.black.opacity(tint * 0.6)
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            legacy
        }
        #else
        legacy
        #endif
    }

    private var legacy: some View {
        ZStack {
            // Partially transparent blur: the desktop reads through, like frosted glass.
            VisualEffectBlur(material: .hudWindow, blending: .behindWindow).opacity(0.82)
            Color.black.opacity(0.08 + tint)
            LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.04), .white.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Color(red: 0.6, green: 0.75, blue: 1).opacity(0.10), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 320)
        }
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 22

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(GlassBackground(radius: radius))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10), .white.opacity(0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
    }
}

extension View {
    func glassCard(radius: CGFloat = 22) -> some View { modifier(GlassCard(radius: radius)) }

    /// A lighter glass "chip" for buttons, pills and inputs inside a card.
    func glassChip(radius: CGFloat = 10, opacity: Double = 0.12) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(opacity)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active // stay glassy even when our panel isn't key
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}
