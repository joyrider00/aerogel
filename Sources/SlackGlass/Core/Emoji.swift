import Foundation

/// Slack shortcode → unicode, for every standard emoji (see EmojiData.swift). Custom workspace emoji are
/// rendered as images where we can (reactions) and as :name: inline.
enum Emoji {
    static func unicode(_ name: String) -> String? {
        if let e = table[name] { return e }
        return table[name.components(separatedBy: "::").first ?? name]
    }

    /// Names for the picker: no skin-tone variants.
    static let pickerNames: [String] = table.keys.filter { !$0.contains("::") }.sorted()

    /// Shown first in the reaction picker.
    static let quick = ["+1", "white_check_mark", "eyes", "pray", "raised_hands", "joy", "heart", "tada", "fire", "100", "rocket", "thinking_face"]
}
