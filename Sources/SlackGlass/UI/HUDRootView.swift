import SwiftUI

struct HUDRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: HUDMetrics.gap) {
            if model.current != nil {
                ConversationView()
                    .frame(width: HUDMetrics.convWidth)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
            VStack(spacing: 10) {
                if model.switcherOpen {
                    SwitcherView().transition(.move(edge: .top).combined(with: .opacity))
                }
                InboxView()
                if let err = model.lastError {
                    ErrorBanner(text: err) { model.lastError = nil }
                }
                if let note = model.notice {
                    ErrorBanner(text: note, symbol: "checkmark.circle.fill", tint: .green, seconds: 3) { model.notice = nil }
                }
            }
            .frame(width: HUDMetrics.inboxWidth)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.current)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: model.switcherOpen)
        .padding(HUDMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .environment(\.colorScheme, .dark)
        .environment(\.openURL, OpenURLAction { model.handleLink($0) })
    }
}

struct ErrorBanner: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .yellow
    var seconds: Double = 6
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", size: 10, action: dismiss)
        }
        .padding(12)
        .glassCard(radius: 16)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            dismiss()
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if model.showChats {
                ChatsList()
            } else if model.inbox.isEmpty {
                emptyState
            } else {
                FitScroll(maxHeight: 620) { rows }
            }
            if !model.showChats && !model.snoozed.isEmpty {
                Menu {
                    ForEach(model.snoozed) { s in
                        Button("\(model.userName(s.user)): \(model.plain(s.text).prefix(40))  ·  \(AppModel.shortDate(s.snoozeUntil ?? Date()))") {
                            model.wake(s)
                        }
                    }
                } label: {
                    Label("\(model.snoozed.count) snoozed", systemImage: "moon.zzz.fill")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .help("Click one to bring it back now")
            }
        }
        .padding(10)
        .glassCard()
    }

    private var header: some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 7, height: 7).help(statusHelp)
            tab("NEEDS YOU" + (model.inbox.isEmpty ? "" : " \(model.inbox.count)"), selected: !model.showChats) {
                model.showChats = false
            }
            tab("CHATS", selected: model.showChats) {
                model.showChats = true
                model.chatQuery = ""
            }
            if model.isDemo {
                Text("DEMO").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.purple.opacity(0.5)))
            }
            Spacer()
            IconButton(symbol: "magnifyingglass", help: "Jump to… (⌘K)") {
                model.switcherOpen.toggle()
                model.switcherQuery = ""
            }
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: "Keep open when clicking elsewhere") {
                model.pinned.toggle()
            }
            Menu {
                Button("Clear all") { model.clearAll() }
                Divider()
                Button("Settings…") { model.onOpenSettings?() }
                Button("Quit Slack Glass") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(model.inbox) { item in
                InboxRow(item: item, selected: item.id == model.selectedInboxID || item.ref == model.current)
                    .onTapGesture {
                        model.selectedInboxID = item.id
                        model.open(item.ref)
                    }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("✨").font(.system(size: 26))
            Text("Nothing needs you").font(.system(size: 13, weight: .semibold))
            Text(emptyHint)
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var emptyHint: String {
        if case .failed(let why) = model.connection { return why }
        if model.connection == .idle { return "Connect Slack in Settings, or try the demo." }
        return "⌃⌥Space toggles this · ⌘K jumps anywhere"
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }

    private var statusHelp: String {
        switch model.connection {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .failed(let s): s
        case .idle: "Not connected"
        }
    }
}

struct InboxRow: View {
    @EnvironmentObject var model: AppModel
    let item: InboxItem
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Avatar(url: model.avatar(item.user), name: model.userName(item.user), size: 30,
                   online: model.isOnline(item.user))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(model.userName(item.user))
                        .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    ReasonPill(reason: item.reason)
                    if model.hasDraft(item.ref) {
                        Image(systemName: "pencil").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .help("Unsent draft")
                    }
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(TimeFormat.relative(item.date)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                if !model.isDirect(item.channel) || item.threadTs != nil {
                    Text(model.title(item.channel) + (item.threadTs != nil ? " · thread" : ""))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(model.plain(item.text))
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(2)
            }
            .opacity(item.seen && !selected ? 0.7 : 1)
            if hover {
                VStack(spacing: 0) {
                    IconButton(symbol: "checkmark", help: "Done (E)", size: 11) { model.markDone(item) }
                    SnoozeMenu(item: item)
                }
            } else if !item.seen {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 4)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(selected ? 0.18 : (hover ? 0.08 : 0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.22 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open") { model.open(item.ref) }
            Button("Mark done") { model.markDone(item) }
            Menu("Snooze") {
                ForEach(AppModel.snoozeOptions(), id: \.label) { o in
                    Button(o.label) { model.snooze(item, until: o.date) }
                }
            }
            Button("Open in Slack") { model.openInSlack(item.ref) }
        }
    }
}

struct SnoozeMenu: View {
    @EnvironmentObject var model: AppModel
    let item: InboxItem

    var body: some View {
        Menu {
            ForEach(AppModel.snoozeOptions(), id: \.label) { o in
                Button(o.label) { model.snooze(item, until: o.date) }
            }
        } label: {
            Image(systemName: "moon.zzz").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Snooze (S = 1 hour)")
    }
}

// MARK: - Quick switcher

struct SwitcherView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a channel or person", text: $model.switcherQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onChange(of: model.switcherQuery) { _ in model.switcherIndex = 0 }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            let results = model.switcherResults
            ForEach(Array(results.enumerated()), id: \.element.id) { i, t in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(t.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if i == model.switcherIndex { Text("↵").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(i == model.switcherIndex ? 0.16 : 0)))
                .contentShape(Rectangle())
                .onTapGesture { model.openSwitcherTarget(t) }
            }
        }
        .padding(8)
        .glassCard(radius: 18)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - Toasts

struct ToastStackView: View {
    @ObservedObject var controller: ToastController
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(controller.items) { item in
                ToastView(controller: controller, item: item)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(HUDMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.openURL, OpenURLAction { model.handleLink($0) })
    }
}

/// A notification you can answer in place: type in the field and press Enter.
/// Clicking anywhere else on it opens the full thread in the HUD.
struct ToastView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: ToastController
    let item: InboxItem
    @State private var reply = ""
    @State private var sending = false
    @State private var sent = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(url: model.avatar(item.user), name: model.userName(item.user), size: 34,
                       online: model.isOnline(item.user))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(model.userName(item.user)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        ReasonPill(reason: item.reason)
                        Spacer(minLength: 0)
                        Text(model.isDirect(item.channel) ? "now" : model.title(item.channel))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(model.plain(item.text)).font(.system(size: 12)).lineLimit(2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                controller.onOpen?(item)
                controller.dismiss(item.id)
            }

            HStack(spacing: 6) {
                TextField(sent ? "Sent ✓" : "Reply…", text: $reply)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(sending)
                if sending {
                    ProgressView().controlSize(.mini)
                } else if !reply.isEmpty {
                    Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassChip(radius: 10, opacity: focused ? 0.16 : 0.08)
        }
        .padding(12)
        .glassCard(radius: 20)
        .onChange(of: focused) { f in controller.setEngaged(item.id, f || !reply.isEmpty) }
        .onChange(of: reply) { r in controller.setEngaged(item.id, focused || !r.isEmpty) }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            let ok: Bool
            if let r = await model.runSlashCommand(text, broadcast: false, to: item.ref) {
                ok = r
            } else {
                ok = await model.send(text: text, files: [], broadcast: false, to: item.ref)
            }
            sending = false
            guard ok else { return }
            reply = ""
            sent = true
            controller.setEngaged(item.id, false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { controller.dismiss(item.id) }
        }
    }
}

// MARK: - Chats (browse any conversation)

struct ChatsList: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        let sections = model.chatSections
        let flat = sections.flatMap(\.items)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search channels and people", text: $model.chatQuery)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($focused)
                    .onChange(of: model.chatQuery) { _ in model.chatIndex = 0 }
                    .onChange(of: focused) { model.chatSearchFocused = $0 }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .glassChip(radius: 10, opacity: 0.08)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sections) { section in
                            Text(section.title.uppercased())
                                .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                            ForEach(section.items) { t in
                                let idx = model.chatPosition(t.id)
                                ChatRow(target: t, highlighted: idx == model.chatIndex && model.chatSearchFocused)
                                    .id(t.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 520)
                .onChange(of: model.chatIndex) { i in
                    if flat.indices.contains(i) { proxy.scrollTo(flat[i].id, anchor: .center) }
                }
            }
        }
        .padding(.horizontal, 2)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onDisappear { model.chatSearchFocused = false }
    }
}

struct ChatRow: View {
    @EnvironmentObject var model: AppModel
    let target: SwitchTarget
    var highlighted = false
    @State private var hover = false

    private var channelID: String? {
        if case .conversation(let id) = target.kind { return id }
        return nil
    }

    private var isOpen: Bool { channelID != nil && model.current?.channel == channelID }

    var body: some View {
        HStack(spacing: 9) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(target.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(target.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let id = channelID, model.inbox.contains(where: { $0.channel == id && !$0.seen }) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(isOpen || highlighted ? 0.18 : hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.openSwitcherTarget(target) }
    }

    @ViewBuilder private var icon: some View {
        let userID: String? = {
            switch target.kind {
            case .user(let u): return u
            case .conversation(let c): return model.conversations[c]?.is_im == true ? model.conversations[c]?.user : nil
            }
        }()
        if let u = userID {
            Avatar(url: model.avatar(u), name: model.userName(u), size: 24, online: model.isOnline(u))
        } else {
            Image(systemName: target.subtitle == "Group DM" ? "person.2.fill"
                  : target.subtitle == "Private channel" ? "lock.fill" : "number")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .glassChip(radius: 7, opacity: 0.1)
        }
    }
}
