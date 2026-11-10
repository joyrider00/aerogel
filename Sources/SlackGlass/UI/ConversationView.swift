import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @EnvironmentObject var model: AppModel

    private var isThread: Bool { model.current?.threadTs != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            if model.messages.isEmpty {
                Group {
                    if model.loadingConversation || model.connection == .connecting { ProgressView().controlSize(.small) }
                    else { Text("No messages yet").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // Short threads hug their content; long ones scroll.
                messageList
            }
            if model.assistantMode, let ref = model.current {
                AssistantPanel(ref: ref)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ComposerView()
        }
        .glassCard()
    }

    private var header: some View {
        HStack(spacing: 6) {
            if model.canGoBack {
                IconButton(symbol: "chevron.left", help: "Back (⌘[)") { model.goBack() }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.current.map { model.title($0.channel) } ?? "")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let ref = model.current {
                IconButton(symbol: "envelope.badge", help: "Mark unread (⌘U): back in Activity with a blue dot") {
                    model.markUnread(ref)
                }
            }
            IconButton(symbol: "arrow.up.forward.app", help: "Open in Slack (⌘O): huddles, canvases, everything else") {
                model.openInSlack()
            }
            IconButton(symbol: "xmark", help: "Close (Esc)") { model.closeConversation() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        if isThread {
            let people = Set(model.messages.compactMap(\.user)).count
            return "Thread · \(max(model.messages.count - 1, 0)) replies · \(people) \(people == 1 ? "person" : "people")"
        }
        if let ch = model.current?.channel, let c = model.conversations[ch], c.is_im == true {
            switch model.isOnline(c.user) {
            case true?: return "Active now"
            case false?: return "Away"
            case nil: return "Direct message"
            }
        }
        return model.isDirect(model.current?.channel ?? "") ? "Group DM" : "Channel"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            FitScroll(onHeightChange: { _ in
                // While a just-opened chat settles (images, previews and long messages taking their space),
                // keep it pinned to the newest message.
                if settling { scroll(proxy) }
            }) {
                messageStack
            }
            .onChange(of: model.current) { _ in startSettling(proxy) }
            .onChange(of: model.scrollToLatestTick) { _ in startSettling(proxy) }
            .onChange(of: model.messages.count) { _ in startSettling(proxy) }
            .onChange(of: model.messages.last?.id) { _ in
                withAnimation(.easeOut(duration: 0.2)) { scroll(proxy) }
            }
            .onAppear { startSettling(proxy) }
            // Scrolling yourself ends the pinning straight away.
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in
                settleUntil = .distantPast
            }
        }
    }

    @State private var settleUntil = Date.distantPast
    private var settling: Bool { Date() < settleUntil }

    private func startSettling(_ proxy: ScrollViewProxy) {
        settleUntil = Date().addingTimeInterval(2.5)
        scroll(proxy)
        // Layout lands a frame or two after the messages do; catch those passes too.
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if settling { scroll(proxy) } }
        }
    }

    /// To the message opened from search (once it's loaded), otherwise to the newest.
    private func scroll(_ proxy: ScrollViewProxy) {
        if let f = model.focusTs, model.messages.contains(where: { $0.ts == f }) {
            proxy.scrollTo(f, anchor: .center)
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var messageStack: some View {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                        MessageRow(message: m, inThread: isThread,
                                   compact: i > 0 && model.messages[i - 1].user == m.user && m.user != nil
                                       && m.date.timeIntervalSince(model.messages[i - 1].date) < 300
                                       && !(isThread && i == 1))
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.yellow.opacity(m.ts == model.focusTs ? 0.14 : 0)))
                            .id(m.id)
                        if isThread && i == 0 && model.messages.count > 1 {
                            HStack(spacing: 8) {
                                Text("\(model.messages.count - 1) \(model.messages.count == 2 ? "reply" : "replies")")
                                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.vertical, 8)
    }
}

// MARK: - Message

struct MessageRow: View {
    @EnvironmentObject var model: AppModel
    let message: SlackMessage
    let inThread: Bool
    let compact: Bool
    @State private var hover = false
    @State private var picker = false
    @State private var confirmDelete = false

    private var mine: Bool { message.user == model.meID && !model.meID.isEmpty }

    var body: some View {
        let author = model.author(of: message)
        HStack(alignment: .top, spacing: 9) {
            if compact {
                Text(hover ? TimeFormat.stamp(message.date).components(separatedBy: " ").last ?? "" : "")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                    .padding(.top, 3)
            } else {
                Avatar(url: author.avatar, name: author.name, size: 32, online: model.isOnline(message.user))
            }
            VStack(alignment: .leading, spacing: 4) {
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(author.name).font(.system(size: 12.5, weight: .semibold))
                        Text(TimeFormat.stamp(message.date)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                if let text = message.text, !text.isEmpty {
                    (Text(model.render(text)) + Text(message.edited != nil ? "  (edited)" : "")
                        .font(.system(size: 10)).foregroundColor(.secondary))
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach((message.blocks ?? []).filter(\.isImage), id: \.self) { b in
                    BlockImageView(block: b)
                }
                ForEach(message.attachments ?? [], id: \.self) { a in
                    AttachmentView(attachment: a)
                }
                if let files = message.files, !files.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(files) { f in
                            FileView(file: f, place: model.current.map {
                                AppModel.FilePlace(channel: $0.channel, ts: message.ts, threadTs: message.thread_ts)
                            })
                        }
                    }
                }
                if let reactions = message.reactions, !reactions.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(reactions, id: \.name) { r in
                            ReactionChip(reaction: r, mine: r.users?.contains(model.meID) ?? false) {
                                model.toggleReaction(message, r.name)
                            }
                        }
                        Button { picker = true } label: {
                            Image(systemName: "face.smiling").font(.system(size: 11))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .glassChip(radius: 9, opacity: 0.08)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !inThread, let n = message.reply_count, n > 0 {
                    Button {
                        model.open(ConversationRef(channel: model.current?.channel ?? "", threadTs: message.ts))
                    } label: {
                        HStack(spacing: 4) {
                            ForEach((message.reply_users ?? []).prefix(3), id: \.self) { u in
                                Avatar(url: model.avatar(u), name: model.userName(u), size: 16)
                            }
                            Text("\(n) \(n == 1 ? "reply" : "replies")")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Mrkdwn.linkColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 2 : 6)
        .background(Color.white.opacity(hover ? 0.05 : 0))
        .overlay(alignment: .topTrailing) {
            if hover { toolbar.padding(.trailing, 10).offset(y: -6) }
        }
        .onHover { hover = $0 }
        .popover(isPresented: $picker, arrowEdge: .leading) {
            ReactionPicker { name in
                picker = false
                model.toggleReaction(message, name)
            }
        }
        .contextMenu { menuItems }
        .confirmationDialog("Delete this message?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(message) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(["+1", "white_check_mark", "eyes"], id: \.self) { e in
                Button { model.toggleReaction(message, e) } label: {
                    Text(Emoji.unicode(e) ?? "").font(.system(size: 12)).frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
            }
            IconButton(symbol: "face.smiling", help: "React") { picker = true }
            if !inThread {
                IconButton(symbol: "arrowshape.turn.up.left", help: "Reply in thread") {
                    model.open(ConversationRef(channel: model.current?.channel ?? "", threadTs: message.thread_ts ?? message.ts))
                }
            }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 3)
        .glassChip(radius: 9, opacity: 0.2)
        .background(VisualEffectBlur(material: .hudWindow, blending: .withinWindow).clipShape(RoundedRectangle(cornerRadius: 9)))
    }

    @ViewBuilder private var menuItems: some View {
        if !inThread {
            Button("Reply in thread") {
                model.open(ConversationRef(channel: model.current?.channel ?? "", threadTs: message.thread_ts ?? message.ts))
            }
        }
        Button("Copy text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.plain(message.text ?? ""), forType: .string)
        }
        if let ref = model.current {
            Button("Mark unread from here") { model.markUnread(ref, from: message) }
        }
        Button("Copy link") { model.copyLink(message) }
        Button("Open in Slack") { model.openInSlack() }
        if mine {
            Divider()
            Button("Edit") {
                model.editing = message
                model.focusComposerTick += 1
            }
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
    }
}

struct ReactionChip: View {
    @EnvironmentObject var model: AppModel
    let reaction: SlackReaction
    let mine: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let u = Emoji.unicode(reaction.name) {
                    Text(u).font(.system(size: 12))
                } else if let url = model.emojiURL(reaction.name) {
                    RemoteImage(url: url, contentMode: .fit) { Color.clear }.frame(width: 15, height: 15)
                } else {
                    Text(":\(reaction.name):").font(.system(size: 10))
                }
                Text("\(reaction.count)").font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 9).fill(mine ? Color.accentColor.opacity(0.35) : .white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(mine ? Color.accentColor.opacity(0.8) : .white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(reaction.users?.map { model.userName($0) }.joined(separator: ", ") ?? "")
    }
}

struct ReactionPicker: View {
    @EnvironmentObject var model: AppModel
    let pick: (String) -> Void
    @State private var query = ""

    private var results: [String] {
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        if q.isEmpty { return Emoji.quick + Emoji.pickerNames.filter { !Emoji.quick.contains($0) }.prefix(36) }
        let all = Set(Emoji.pickerNames).union(model.customEmoji.keys)
        return all.filter { $0.contains(q) }.sorted { ($0.hasPrefix(q) ? 0 : 1, $0) < ($1.hasPrefix(q) ? 0 : 1, $1) }.prefix(48).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let f = results.first { pick(f) } }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                ForEach(results, id: \.self) { name in
                    Button { pick(name) } label: {
                        Group {
                            if let u = Emoji.unicode(name) {
                                Text(u).font(.system(size: 18))
                            } else {
                                RemoteImage(url: model.emojiURL(name), contentMode: .fit) { Color.clear }
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(":\(name):")
                }
            }
        }
        .padding(10)
        .frame(width: 290)
    }
}

struct FileView: View {
    @EnvironmentObject var model: AppModel
    let file: SlackFile
    var place: AppModel.FilePlace?

    var body: some View {
        Group {
            if file.isImage {
                Group {
                    if let gif = file.animatedThumbURL {
                        AnimatedRemoteImage(url: gif)
                    } else {
                        RemoteImage(url: file.thumbURL, contentMode: .fill) {
                            Rectangle().fill(.white.opacity(0.08)).overlay(ProgressView().controlSize(.small))
                        }
                    }
                }
                .frame(width: 220, height: 140)
                .overlay {
                    if file.isVideo {
                        Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.45)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15)))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text((file.filetype ?? "file").uppercased()
                             + (file.size.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: 260, alignment: .leading)
                .glassChip(radius: 10, opacity: 0.08)
            }
        }
        .onTapGesture { model.openFile(file, at: place) }
        .help(file.isPDF ? "Open in Preview" : file.isVideo ? "Play video" : file.isImage ? "View image" : "Open in Slack")
    }
}

/// A GIF (from Slack's GIF picker) or other image block, playing, at its own size.
struct BlockImageView: View {
    let block: SlackMessage.ImageBlock

    var body: some View {
        let size = block.displaySize
        AnimatedRemoteImage(url: block.url)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help(block.alt_text ?? "")
    }
}

struct AttachmentView: View {
    @EnvironmentObject var model: AppModel
    let attachment: SlackMessage.Attachment

    var body: some View {
        let images = attachment.images
        if !images.isEmpty, attachment.title == nil, attachment.text == nil, attachment.pretext == nil {
            // Just a GIF: show it, not the "shared a GIF" placeholder text.
            ForEach(images, id: \.self) { BlockImageView(block: $0) }
        } else {
            card
            ForEach(images, id: \.self) { BlockImageView(block: $0) }
        }
    }

    private var card: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.3)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                if let p = attachment.pretext { Text(model.render(p)).font(.system(size: 12)) }
                if let t = attachment.title {
                    Text(t).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(attachment.title_link != nil ? Mrkdwn.linkColor : .primary)
                        .onTapGesture { if let u = attachment.title_link.flatMap(URL.init(string:)) { model.openExternal(u) } }
                }
                if let t = attachment.text { Text(model.render(t)).font(.system(size: 12)).lineLimit(6) }
                if attachment.title == nil, attachment.text == nil, let f = attachment.fallback {
                    Text(model.render(f)).font(.system(size: 12)).lineLimit(4)
                }
                if let f = attachment.footer { Text(model.plain(f)).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
