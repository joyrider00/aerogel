import Foundation

/// Slack shortcode → unicode for the common set. Custom workspace emoji are
/// rendered as images where we can (reactions) and as :name: inline.
enum Emoji {
    static func unicode(_ name: String) -> String? {
        let base = name.components(separatedBy: "::").first ?? name
        return table[base]
    }

    /// Shown first in the reaction picker.
    static let quick = ["+1", "white_check_mark", "eyes", "pray", "raised_hands", "joy", "heart", "tada", "fire", "100", "rocket", "thinking_face"]

    static let table: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "ballot_box_with_check": "☑️", "x": "❌",
        "eyes": "👀", "eye": "👁️", "pray": "🙏", "raised_hands": "🙌", "clap": "👏", "wave": "👋",
        "ok_hand": "👌", "muscle": "💪", "point_up": "☝️", "point_right": "👉", "point_left": "👈",
        "point_down": "👇", "v": "✌️", "crossed_fingers": "🤞", "handshake": "🤝", "raised_hand": "✋",
        "hand": "✋", "open_hands": "👐", "palms_up_together": "🤲", "writing_hand": "✍️", "fist": "✊",
        "punch": "👊", "facepunch": "👊", "call_me_hand": "🤙", "metal": "🤘", "saluting_face": "🫡",
        "joy": "😂", "rolling_on_the_floor_laughing": "🤣", "smile": "😄", "smiley": "😃", "grinning": "😀",
        "grin": "😁", "laughing": "😆", "satisfied": "😆", "sweat_smile": "😅", "slightly_smiling_face": "🙂",
        "upside_down_face": "🙃", "wink": "😉", "blush": "😊", "innocent": "😇", "heart_eyes": "😍",
        "star-struck": "🤩", "kissing_heart": "😘", "yum": "😋", "stuck_out_tongue": "😛",
        "stuck_out_tongue_winking_eye": "😜", "zany_face": "🤪", "money_mouth_face": "🤑", "hugging_face": "🤗",
        "shushing_face": "🤫", "thinking_face": "🤔", "zipper_mouth_face": "🤐", "neutral_face": "😐",
        "expressionless": "😑", "no_mouth": "😶", "smirk": "😏", "face_with_rolling_eyes": "🙄",
        "grimacing": "😬", "relieved": "😌", "pensive": "😔", "sleeping": "😴", "mask": "😷",
        "nerd_face": "🤓", "sunglasses": "😎", "partying_face": "🥳", "confused": "😕", "worried": "😟",
        "slightly_frowning_face": "🙁", "white_frowning_face": "☹️", "open_mouth": "😮", "hushed": "😯",
        "astonished": "😲", "flushed": "😳", "pleading_face": "🥺", "cry": "😢", "sob": "😭",
        "scream": "😱", "persevere": "😣", "disappointed": "😞", "sweat": "😓", "weary": "😩",
        "tired_face": "😫", "yawning_face": "🥱", "triumph": "😤", "rage": "😡", "angry": "😠",
        "exploding_head": "🤯", "melting_face": "🫠", "face_with_monocle": "🧐", "skull": "💀",
        "ghost": "👻", "alien": "👽", "robot_face": "🤖", "hankey": "💩", "poop": "💩", "clown_face": "🤡",
        "see_no_evil": "🙈", "hear_no_evil": "🙉", "speak_no_evil": "🙊", "face_palm": "🤦",
        "facepalm": "🤦", "man-facepalming": "🤦‍♂️", "woman-facepalming": "🤦‍♀️", "shrug": "🤷",
        "man-shrugging": "🤷‍♂️", "woman-shrugging": "🤷‍♀️", "dancer": "💃", "man_dancing": "🕺",
        "running": "🏃", "brain": "🧠",
        "heart": "❤️", "orange_heart": "🧡", "yellow_heart": "💛", "green_heart": "💚", "blue_heart": "💙",
        "purple_heart": "💜", "black_heart": "🖤", "white_heart": "🤍", "broken_heart": "💔",
        "sparkling_heart": "💖", "heartpulse": "💗", "two_hearts": "💕", "heart_on_fire": "❤️‍🔥",
        "tada": "🎉", "confetti_ball": "🎊", "balloon": "🎈", "fireworks": "🎆", "sparkles": "✨",
        "fire": "🔥", "100": "💯", "rocket": "🚀", "star": "⭐", "star2": "🌟", "dizzy": "💫", "zap": "⚡",
        "boom": "💥", "collision": "💥", "trophy": "🏆", "medal": "🏅", "sports_medal": "🏅", "crown": "👑",
        "gem": "💎", "gift": "🎁", "birthday": "🎂", "cake": "🍰", "dart": "🎯", "bulb": "💡",
        "warning": "⚠️", "rotating_light": "🚨", "no_entry": "⛔", "no_entry_sign": "🚫",
        "octagonal_sign": "🛑", "stop_sign": "🛑", "construction": "🚧", "bug": "🐛", "question": "❓",
        "grey_question": "❔", "exclamation": "❗", "heavy_exclamation_mark": "❗", "bangbang": "‼️",
        "red_circle": "🔴", "large_green_circle": "🟢", "large_yellow_circle": "🟡", "large_blue_circle": "🔵",
        "large_orange_circle": "🟠", "white_circle": "⚪", "black_circle": "⚫",
        "heavy_plus_sign": "➕", "heavy_minus_sign": "➖", "arrow_right": "➡️", "arrow_left": "⬅️",
        "arrow_up": "⬆️", "arrow_down": "⬇️", "arrows_counterclockwise": "🔄", "repeat": "🔁", "recycle": "♻️",
        "memo": "📝", "pencil": "📝", "pencil2": "✏️", "pushpin": "📌", "round_pushpin": "📍", "paperclip": "📎",
        "link": "🔗", "lock": "🔒", "unlock": "🔓", "key": "🔑", "hammer": "🔨", "wrench": "🔧",
        "hammer_and_wrench": "🛠️", "gear": "⚙️", "computer": "💻", "keyboard": "⌨️", "iphone": "📱",
        "chart_with_upwards_trend": "📈", "chart_with_downwards_trend": "📉", "bar_chart": "📊",
        "calendar": "📆", "date": "📅", "spiral_calendar_pad": "🗓️", "alarm_clock": "⏰", "hourglass": "⌛",
        "hourglass_flowing_sand": "⏳", "stopwatch": "⏱️", "mag": "🔍", "bell": "🔔", "no_bell": "🔕",
        "loudspeaker": "📢", "mega": "📣", "speech_balloon": "💬", "thought_balloon": "💭", "email": "📧",
        "envelope": "✉️", "inbox_tray": "📥", "outbox_tray": "📤", "package": "📦", "ship": "🚢",
        "money_with_wings": "💸", "moneybag": "💰", "dollar": "💵", "coffee": "☕", "tea": "🍵",
        "beer": "🍺", "beers": "🍻", "wine_glass": "🍷", "champagne": "🍾", "pizza": "🍕", "taco": "🌮",
        "hamburger": "🍔", "doughnut": "🍩", "cookie": "🍪", "popcorn": "🍿", "avocado": "🥑",
        "dog": "🐶", "cat": "🐱", "unicorn_face": "🦄", "dragon": "🐉", "snake": "🐍", "turtle": "🐢",
        "octopus": "🐙", "bee": "🐝", "butterfly": "🦋", "monkey": "🐒", "sloth": "🦥", "duck": "🦆",
        "seedling": "🌱", "evergreen_tree": "🌲", "cactus": "🌵", "sunflower": "🌻", "rose": "🌹",
        "sunny": "☀️", "cloud": "☁️", "rain_cloud": "🌧️", "snowflake": "❄️", "rainbow": "🌈", "ocean": "🌊",
        "earth_americas": "🌎", "crescent_moon": "🌙", "full_moon": "🌕", "new_moon": "🌑",
        "zzz": "💤", "wavy_dash": "〰️", "white_flag": "🏳️", "checkered_flag": "🏁", "triangular_flag_on_post": "🚩",
        "ok": "🆗", "new": "🆕", "free": "🆓", "cool": "🆒", "sos": "🆘", "information_source": "ℹ️",
    ]
}
