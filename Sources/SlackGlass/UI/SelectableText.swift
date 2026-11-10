import AppKit
import SwiftUI

/// Message text you can highlight and copy, with links you can click. SwiftUI's own selectable
/// Text swallows link clicks on macOS, so this is a real (read-only) NSTextView.
struct SelectableText: NSViewRepresentable {
    let text: AttributedString
    var size: CGFloat = 13
    var color: NSColor = .labelColor
    var lineSpacing: CGFloat = 2
    var maxLines: Int = 0
    /// Appended in small secondary text, e.g. "(edited)".
    var suffix: String? = nil
    let onLink: (URL) -> Void

    func makeNSView(context: Context) -> LinkTextView {
        let v = LinkTextView()
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.isRichText = true
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.delegate = context.coordinator
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateNSView(_ v: LinkTextView, context: Context) {
        context.coordinator.onLink = onLink
        v.linkTextAttributes = [.foregroundColor: NSColor(Mrkdwn.linkColor), .cursor: NSCursor.pointingHand]
        v.textContainer?.maximumNumberOfLines = maxLines
        v.textContainer?.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        let s = Self.convert(text, size: size, color: color, lineSpacing: lineSpacing, suffix: suffix)
        if v.textStorage?.isEqual(to: s) != true {
            v.textStorage?.setAttributedString(s)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: LinkTextView, context: Context) -> CGSize? {
        let width = proposal.width.map { max($0, 1) } ?? 400
        guard let lm = v.layoutManager, let tc = v.textContainer else { return nil }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return CGSize(width: width, height: ceil(used.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: (URL) -> Void
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let u = link as? URL { onLink(u) } else if let s = link as? String, let u = URL(string: s) { onLink(u) }
            return true
        }
    }

    /// SwiftUI attributes (Font/Color/intents) → AppKit attributes the text view understands.
    static func convert(_ a: AttributedString, size: CGFloat, color: NSColor, lineSpacing: CGFloat,
                        suffix: String?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        let base = NSFont.systemFont(ofSize: size)
        for run in a.runs {
            let str = String(a[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = base
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: size * 0.92, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            } else if intent.contains(.stronglyEmphasized) {
                font = .systemFont(ofSize: size, weight: .semibold)
            }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
                                                        .foregroundColor: run.foregroundColor.map { NSColor($0) } ?? color]
            if let bg = run.backgroundColor { attrs[.backgroundColor] = NSColor(bg) }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: str, attributes: attrs))
        }
        if let suffix {
            out.append(NSAttributedString(string: "  " + suffix, attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        }
        return out
    }
}

final class LinkTextView: NSTextView {
    /// Right-click with nothing highlighted shows the message's own menu (react, reply, mark unread…);
    /// with text highlighted, the usual Copy / Look Up menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        selectedRange().length > 0 ? super.menu(for: event) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if selectedRange().length > 0 { super.rightMouseDown(with: event) } else { nextResponder?.rightMouseDown(with: event) }
    }

    /// Scrolling over a message scrolls the conversation.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    /// Clicking elsewhere clears the highlight, like any text on a Mac.
    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        return super.resignFirstResponder()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
