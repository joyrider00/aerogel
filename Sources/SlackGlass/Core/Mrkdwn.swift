import SwiftUI

/// Renders Slack mrkdwn (not Markdown) to an AttributedString:
/// *bold* _italic_ ~strike~ `code` ```blocks``` <links|labels> <@U…> <#C…> <!here> :emoji: and > quotes.
enum Mrkdwn {
    struct Context {
        var userName: (String) -> String
        var channelName: (String) -> String
    }

    static let mentionColor = Color(red: 0.62, green: 0.80, blue: 1.0)
    static let linkColor = Color(red: 0.55, green: 0.78, blue: 1.0)

    private static let regex = try! NSRegularExpression(pattern: [
        #"```([\s\S]*?)```"#,                          // 1 code block
        #"`([^`\n]+)`"#,                                // 2 inline code
        #"<([^<>\n]+)>"#,                               // 3 entity
        #"(?<![\w*])\*(?!\s)([^*\n]+?)\*(?![\w*])"#,    // 4 bold
        #"(?<![\w_])_(?!\s)([^_\n]+?)_(?![\w_])"#,      // 5 italic
        #"(?<![\w~])~(?!\s)([^~\n]+?)~(?![\w~])"#,      // 6 strike
        #":([a-zA-Z0-9_+\-']+(?:::skin-tone-\d)?):"#,   // 7 emoji
    ].joined(separator: "|"))

    private static let quoteRegex = try! NSRegularExpression(pattern: #"(?m)^&gt;\s?"#)

    static func render(_ raw: String, _ ctx: Context) -> AttributedString {
        var src = raw
        if !src.contains("```") {
            src = quoteRegex.stringByReplacingMatches(
                in: src, range: NSRange(location: 0, length: (src as NSString).length), withTemplate: "┃ ")
        }
        let ns = src as NSString
        var out = AttributedString()
        var cursor = 0

        for m in regex.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += plain(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            cursor = m.range.location + m.range.length
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }

            if let code = g(1) {
                var a = plain(code.trimmingCharacters(in: .newlines))
                a.inlinePresentationIntent = .code
                a.backgroundColor = Color.black.opacity(0.28)
                out += AttributedString("\n") + a + AttributedString("\n")
            } else if let code = g(2) {
                var a = plain(code)
                a.inlinePresentationIntent = .code
                a.backgroundColor = Color.black.opacity(0.28)
                out += a
            } else if let ent = g(3) {
                out += entity(ent, ctx)
            } else if let s = g(4) {
                var a = plain(s); a.inlinePresentationIntent = .stronglyEmphasized; out += a
            } else if let s = g(5) {
                var a = plain(s); a.inlinePresentationIntent = .emphasized; out += a
            } else if let s = g(6) {
                var a = plain(s); a.inlinePresentationIntent = .strikethrough; out += a
            } else if let e = g(7) {
                out += AttributedString(Emoji.unicode(e) ?? ":\(e):")
            }
        }
        if cursor < ns.length {
            out += plain(ns.substring(from: cursor))
        }
        return out
    }

    static func plainText(_ raw: String, _ ctx: Context) -> String {
        String(render(raw, ctx).characters)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func entity(_ s: String, _ ctx: Context) -> AttributedString {
        let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
        let target = parts[0]
        let label = parts.count > 1 ? parts[1] : nil

        func styled(_ text: String) -> AttributedString {
            var a = AttributedString(text)
            a.foregroundColor = mentionColor
            a.inlinePresentationIntent = .stronglyEmphasized
            return a
        }

        if target.hasPrefix("@") {
            let name = label.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 } ?? ctx.userName(String(target.dropFirst()))
            return styled("@" + name)
        }
        if target.hasPrefix("#") {
            return styled("#" + (label ?? ctx.channelName(String(target.dropFirst()))))
        }
        if target.hasPrefix("!subteam^") { return styled(label ?? "@group") }
        if target.hasPrefix("!date^") { return AttributedString(decode(label ?? "")) }
        if target.hasPrefix("!") { return styled("@" + (label ?? String(target.dropFirst()))) }

        let shown = label ?? target.replacingOccurrences(of: "mailto:", with: "")
        var a = AttributedString(decode(shown))
        if let u = URL(string: target) {
            a.link = u
            a.foregroundColor = linkColor
        }
        return a
    }

    private static func plain(_ s: String) -> AttributedString { AttributedString(decode(s)) }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
