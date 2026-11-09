import Foundation

/// The Slack app every user creates for themselves. Keeping it a private,
/// single-workspace app means each person's events only go to their own Mac
/// and the app stays exempt from Slack's limits on non-Marketplace apps.
enum SlackManifest {
    static let userScopes = [
        "channels:history", "channels:read", "channels:write",
        "groups:history", "groups:read", "groups:write",
        "im:history", "im:read", "im:write",
        "mpim:history", "mpim:read", "mpim:write",
        "users:read",
        "chat:write",
        "reactions:read", "reactions:write",
        "files:read", "files:write",
        "emoji:read",
    ]

    static let userEvents = [
        "message.channels", "message.groups", "message.im", "message.mpim",
        "reaction_added", "reaction_removed",
    ]

    static var manifest: [String: Any] {
        [
            "display_information": [
                "name": "Aerogel",
                "description": "A glass HUD for reading and replying to Slack without opening Slack.",
                "background_color": "#1a1033",
            ],
            "oauth_config": [
                "scopes": ["user": userScopes],
            ],
            "settings": [
                "event_subscriptions": ["user_events": userEvents],
                "socket_mode_enabled": true,
                "org_deploy_enabled": false,
                "token_rotation_enabled": false,
            ],
        ]
    }

    static var createAppURL: URL {
        let data = try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8)!
        var c = URLComponents(string: "https://api.slack.com/apps")!
        c.queryItems = [URLQueryItem(name: "new_app", value: "1"), URLQueryItem(name: "manifest_json", value: json)]
        return c.url!
    }
}
