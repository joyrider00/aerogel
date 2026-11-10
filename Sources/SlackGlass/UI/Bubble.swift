import AppKit
import Combine
import SwiftUI

/// A small glass bubble that floats on the screen edge. Click it to open the HUD;
/// drag it anywhere and it remembers where it was left.
@MainActor
final class BubbleController {
    static let size: CGFloat = 36 // includes room for the shadow
    private let panel = HUDPanel(allowsKey: false)
    private var bag = Set<AnyCancellable>()
    private var hudVisible = false
    var onClick: (() -> Void)?

    init(model: AppModel) {
        let host = NSHostingView(rootView: BubbleView().environmentObject(model))
        let container = DragClickView(host: host)
        container.onClick = { [weak self] in self?.onClick?() }
        container.onMoved = { [weak self] origin in
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: PrefKey.bubbleOrigin)
            self?.refresh()
        }
        panel.contentView = container
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) // above the HUD
        panel.setFrame(NSRect(origin: Self.savedOrigin(), size: NSSize(width: Self.size, height: Self.size)), display: true)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        refresh()
    }

    func hudVisibilityChanged(_ visible: Bool) {
        hudVisible = visible
        refresh()
    }

    /// Where the bubble is on screen right now, so the HUD and toasts can open below it instead of under it.
    static var screenFrame: NSRect?

    /// The bubble never hides: it sits above the HUD and toggles it. (Hiding it while the HUD was open made it
    /// look like it vanished whenever Esc closed a thread but left the HUD up.)
    private func refresh() {
        guard Prefs.showBubble else {
            panel.orderOut(nil)
            Self.screenFrame = nil
            return
        }
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        Self.screenFrame = panel.frame
    }

    private static func savedOrigin() -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: PrefKey.bubbleOrigin) {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -10, dy: -10).contains(p) }) { return p }
        }
        // Top-right corner, directly under the menu bar clock.
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - size - 6, y: vf.maxY - size - 2)
    }
}

/// Routes all mouse events to itself so the bubble can be both clicked and dragged.
private final class DragClickView: NSView {
    var onClick: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    private var downPoint: NSPoint = .zero
    private var originAtDown: NSPoint = .zero
    private var dragged = false

    init(host: NSView) {
        super.init(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        downPoint = NSEvent.mouseLocation
        originAtDown = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        if !dragged, hypot(dx, dy) < 3 { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: originAtDown.x + dx, y: originAtDown.y + dy))
    }

    override func mouseUp(with e: NSEvent) {
        if dragged {
            if let o = window?.frame.origin { onMoved?(o) }
        } else {
            onClick?()
        }
    }
}

private struct BubbleView: View {
    @EnvironmentObject var model: AppModel
    @State private var bump = false
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                GlassBackground(radius: 22)
                LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)

            if model.unseenCount > 0 {
                Text("\(min(model.unseenCount, 99))")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5).frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(Color.newBadge))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.5)))
                    .offset(x: 3, y: -3)
            }
            if model.markedUnreadCount > 0 {
                // Blue: things you marked unread to come back to (red is new messages).
                Text("\(min(model.markedUnreadCount, 99))")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5).frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(Color.blue))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.5)))
                    .offset(x: 3, y: 15)   // bottom-right of the 26 pt circle
            }
        }
        .scaleEffect(bump ? 1.15 : (hover ? 1.06 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: bump)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .frame(width: BubbleController.size, height: BubbleController.size)
        .environment(\.colorScheme, .dark)
        .help("Slack Glass: click to open, drag to move")
        .onChange(of: model.unseenCount) { n in
            guard n > 0 else { return }
            bump = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { bump = false }
        }
    }
}
