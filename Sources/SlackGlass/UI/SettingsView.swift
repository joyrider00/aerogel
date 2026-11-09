import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var userToken = Secrets.get(TokenKey.user) ?? ""
    @State private var appToken = Secrets.get(TokenKey.app) ?? ""
    @State private var userRefresh = Secrets.get(TokenKey.userRefresh) ?? ""
    @State private var appRefresh = Secrets.get(TokenKey.appRefresh) ?? ""
    @State private var clientID = Secrets.get(TokenKey.clientID) ?? ""
    @State private var clientSecret = Secrets.get(TokenKey.clientSecret) ?? ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(PrefKey.style) private var style = NotificationStyle.hud.rawValue
    @AppStorage(PrefKey.sound) private var sound = true
    @AppStorage(PrefKey.channelWide) private var channelWide = false
    @AppStorage(PrefKey.keywords) private var keywords = ""
    @AppStorage(PrefKey.glassTint) private var tint = 0.0
    @AppStorage(PrefKey.showBubble) private var showBubble = true
    @AppStorage(PrefKey.assistantURL) private var assistantURL = ""
    @AppStorage(PrefKey.assistantName) private var assistantName = ""
    @State private var assistantToken = Secrets.get(TokenKey.assistant) ?? ""
    @State private var assistantStatus: String?
    @State private var assistantOK = false

    var body: some View {
        Form {
            Section {
                Text("Slack Glass talks to Slack through a private app that only you install, in your own workspace. Setup takes about a minute.")
                    .font(.callout).foregroundStyle(.secondary)
                step(1, "Create the app from Slack Glass's manifest") {
                    Button("Create Slack app ↗") { NSWorkspace.shared.open(SlackManifest.createAppURL) }
                }
                step(2, "In the app: **Install to Workspace**, then copy the **User OAuth Token** from *OAuth & Permissions*") {
                    SecureField("xoxp-…", text: $userToken).textFieldStyle(.roundedBorder)
                }
                step(3, "In *Basic Information → App-Level Tokens*, generate a token with the **connections:write** scope") {
                    SecureField("xapp-… or xoxe.xapp-…", text: $appToken).textFieldStyle(.roundedBorder)
                }
                if rotating {
                    step(4, "These tokens **rotate**. So Slack Glass can renew them before they expire, paste the **Refresh token** from the same dialog, plus the **Client ID** and **Client Secret** from *Basic Information → App Credentials*") {
                        VStack(spacing: 6) {
                            if TokenRotation.isRotating(cleanApp) {
                                SecureField("App-level refresh token (xoxe-1-…)", text: $appRefresh).textFieldStyle(.roundedBorder)
                            }
                            if TokenRotation.isRotating(cleanUser) {
                                SecureField("User refresh token (xoxe-1-…)", text: $userRefresh).textFieldStyle(.roundedBorder)
                            }
                            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                            SecureField("Client Secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                if let hint = tokenHint {
                    Label(hint, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Save & Connect") {
                        Secrets.set(TokenKey.user, cleanUser)
                        Secrets.set(TokenKey.app, cleanApp)
                        Secrets.set(TokenKey.userRefresh, trim(userRefresh))
                        Secrets.set(TokenKey.appRefresh, trim(appRefresh))
                        Secrets.set(TokenKey.clientID, trim(clientID))
                        Secrets.set(TokenKey.clientSecret, trim(clientSecret))
                        model.connect()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tokenHint != nil)
                    statusLabel
                    Spacer()
                    Button("Try demo") { model.startDemo() }
                }
            } header: { Text("Connect Slack") }

            Section {
                Picker("Notify with", selection: $style) {
                    ForEach(NotificationStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: style) { s in
                    if s == NotificationStyle.native.rawValue, Bundle.main.bundleIdentifier != nil {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                }
                Toggle("Play a sound", isOn: $sound)
                Toggle("Include @here / @channel", isOn: $channelWide)
                TextField("Keywords", text: $keywords, prompt: Text("deploy, outage, my-project"))
                Text("You're always notified for DMs, group DMs, @mentions, and replies in threads you've posted in or were mentioned in. Mute Slack's own desktop notifications so you don't get two of each.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Notifications") }

            Section {
                Text("Connect any assistant server that speaks Slack Glass's assistant API (see the README). Type **/\(assistantName.isEmpty ? "assistant" : assistantName.lowercased().filter { !$0.isWhitespace })** in a conversation to ask it about that conversation or tell it what to do. Anything it drafts shows as a card you send yourself.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Name", text: $assistantName, prompt: Text("Assistant"))
                TextField("Server", text: $assistantURL, prompt: Text("https://assistant.example.com"))
                SecureField("Token", text: $assistantToken, prompt: Text("Bearer token"))
                HStack {
                    Button("Save & Test") { saveAssistant() }
                        .disabled(assistantURL.isEmpty || assistantToken.isEmpty)
                    Spacer()
                    if let s = assistantStatus {
                        Label(s, systemImage: assistantOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(assistantOK ? .green : .orange).font(.caption).lineLimit(2)
                    }
                }
            } header: { Text("Assistant") }

            Section {
                Slider(value: $tint, in: 0...0.6) {
                    Text("Glass tint")
                } minimumValueLabel: {
                    Text("Clear").font(.caption)
                } maximumValueLabel: {
                    Text("Smoky").font(.caption)
                }
                Toggle("Floating bubble (click to open, drag to move)", isOn: $showBubble)
                LabeledContent("Slash commands") {
                    HStack {
                        Text(SlashCommands.all().map { "/" + $0.name }.joined(separator: " ").isEmpty
                             ? "none yet" : SlashCommands.all().map { "/" + $0.name }.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button("Open Commands folder") { NSWorkspace.shared.open(SlashCommands.folder) }
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.lastError = "Launch at login: \(error.localizedDescription)"
                        }
                    }
                LabeledContent("Show / hide HUD") { Text("⌃⌥Space").monospaced() }
                LabeledContent("Reply to latest") { Text("⌃⌥R").monospaced() }
                LabeledContent("In the HUD") {
                    Text("J/K move · ↵ open · E done · ⌘K jump · ⌘[ back · ⌥↑↓ next · ⌘O open in Slack · Esc close")
                        .font(.caption).multilineTextAlignment(.trailing)
                }
            } header: { Text("General") }

            Section {
                HStack {
                    Button("Disconnect") { model.disconnect() }
                    Button("Remove tokens") {
                        for k in [TokenKey.user, TokenKey.app, TokenKey.userRefresh, TokenKey.appRefresh,
                                  TokenKey.clientID, TokenKey.clientSecret] { Secrets.set(k, nil) }
                        userToken = ""
                        appToken = ""
                        model.disconnect()
                    }
                    Spacer()
                    Button("Quit Slack Glass") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 720)
    }

    private func saveAssistant() {
        assistantURL = trim(assistantURL).replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        Secrets.set(TokenKey.assistant, trim(assistantToken))
        assistantStatus = "Testing…"
        assistantOK = false
        Task {
            guard let client = model.assistantClient else {
                assistantStatus = "Enter an https:// server address and a token."
                return
            }
            do {
                try await client.check()
                assistantStatus = "Connected to \(Prefs.assistantName)"
                assistantOK = true
            } catch {
                assistantStatus = error.localizedDescription
            }
        }
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanUser: String { trim(userToken) }
    private var cleanApp: String { trim(appToken) }
    private var rotating: Bool { TokenRotation.isRotating(cleanUser) || TokenRotation.isRotating(cleanApp) }

    /// Strips the `xoxe.` rotation prefix so both token styles validate the same way.
    private func kind(_ t: String) -> String {
        String((t.hasPrefix("xoxe.") ? String(t.dropFirst(5)) : t).prefix(5))
    }

    /// Explains why Save is disabled instead of silently greying it out.
    private var tokenHint: String? {
        if cleanUser.isEmpty && cleanApp.isEmpty { return nil }
        if cleanUser.isEmpty || cleanApp.isEmpty { return "Both tokens are needed." }
        switch kind(cleanUser) {
        case "xoxp-": break
        case "xoxb-": return "Field 2 has a Bot token (xoxb-). Use the User OAuth Token (xoxp-) instead."
        case "xapp-": return "Field 2 has the app-level token. It belongs in field 3."
        default: return "Field 2 should be the User OAuth Token (xoxp-…), from OAuth & Permissions."
        }
        switch kind(cleanApp) {
        case "xapp-": break
        case "xoxp-": return "Field 3 has the User OAuth Token. It belongs in field 2."
        default: return "Field 3 should be the App-Level Token (xapp-… or xoxe.xapp-…), from Basic Information → App-Level Tokens."
        }
        if rotating {
            if TokenRotation.isRotating(cleanApp), !trim(appRefresh).hasPrefix("xoxe-") {
                return "Paste the app-level Refresh token (xoxe-1-…) from the same dialog as the access token."
            }
            if TokenRotation.isRotating(cleanUser), !trim(userRefresh).hasPrefix("xoxe-") {
                return "Paste the user Refresh token (xoxe-1-…)."
            }
            if trim(clientID).isEmpty || trim(clientSecret).isEmpty {
                return "Add the Client ID and Client Secret (Basic Information → App Credentials) so tokens can renew."
            }
        }
        return nil
    }

    private func step<C: View>(_ n: Int, _ text: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n)").font(.caption.bold()).frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor.opacity(0.25)))
                Text(text)
            }
            content().padding(.leading, 26)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch model.connection {
        case .idle: Text("Not connected").foregroundStyle(.secondary)
        case .connecting: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Connecting…") }
        case .connected: Label(model.isDemo ? "Demo mode" : "Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let why): Text(why).foregroundStyle(.red).lineLimit(2)
        }
    }
}
