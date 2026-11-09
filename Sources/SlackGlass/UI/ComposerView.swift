import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    /// Bumped whenever the app (not your typing) changes the text, so only those changes are pushed into the box.
    @State private var textTick = 0
    @State private var height: CGFloat = 18
    @State private var files: [URL] = []
    @State private var broadcast = false
    @State private var sending = false
    @State private var draftRef: ConversationRef?
    @State private var customSchedule = false
    @State private var emojiPicker = false
    @State private var customDate = Date().addingTimeInterval(3600)
    @State private var caret = 0
    @State private var caretTarget: Int?
    @State private var mentionIndex = 0
    @State private var dismissedMentionAt: Int?

    /// The "@name" being typed at the caret, unless Esc dismissed it.
    private var mention: (range: NSRange, query: String)? {
        guard let t = AppModel.mentionToken(in: text, caret: caret), t.range.location != dismissedMentionAt else { return nil }
        return t
    }

    private var mentionList: [MentionSuggestion] {
        mention.map { model.mentionSuggestions($0.query) } ?? []
    }

    private var isThread: Bool { model.current?.threadTs != nil }

    private var placeholder: String {
        if model.editing != nil { return "Edit message" }
        if model.assistantMode { return "Ask \(Prefs.assistantName), or tell it what to do…" }
        guard let cur = model.current else { return "" }
        return isThread ? "Reply…" : "Message \(model.title(cur.channel))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.editing != nil {
                HStack {
                    Image(systemName: "pencil").font(.system(size: 10))
                    Text("Editing · Enter to save · Esc to cancel").font(.system(size: 10.5))
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip").font(.system(size: 10))
                                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Button { files.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glassChip(radius: 8, opacity: 0.12)
                        }
                    }
                }
            }
            if !mentionList.isEmpty {
                MentionPopup(list: mentionList, index: mentionIndex, onPick: insertMention)
            }
            let commands = model.editing == nil ? SlashCommands.matching(text) : []
            if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(commands.prefix(6)) { c in
                        HStack(spacing: 8) {
                            Image(systemName: c.isBuiltin ? "sparkles" : c.isText ? "text.quote"
                                  : c.isVideo ? "play.rectangle.fill" : "photo.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(c.isBuiltin ? AssistantPanel.tint : .secondary).frame(width: 16)
                            Text("/" + c.name).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text(c.isBuiltin ? "Ask \(Prefs.assistantName) about this conversation" : c.url.lastPathComponent)
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(c.id == commands.first?.id ? 0.12 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture { complete(c) }
                    }
                    Text("Enter sends · Tab completes · add more in Settings → Commands folder")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                IconButton(symbol: "paperclip", help: "Attach files (or paste / drop)") { pickFiles() }
                    .disabled(model.editing != nil)
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.system(size: 13)).foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(text: $text, height: $height, caret: $caret, caretTarget: $caretTarget,
                                     textTick: textTick, focusTick: model.focusComposerTick,
                                     onSubmit: submit, onFiles: { files += $0 },
                                     onKey: { mentionKey($0) },
                                     onTab: {
                                         guard let first = SlashCommands.matching(text).first else { return false }
                                         complete(first)
                                         return true
                                     })
                        .frame(height: height)
                }
                .padding(.vertical, 3)
                IconButton(symbol: "face.smiling", help: "Emoji") { emojiPicker = true }
                    .popover(isPresented: $emojiPicker, arrowEdge: .top) {
                        ReactionPicker { name in
                            emojiPicker = false
                            insertEmoji(name)
                        }
                    }
                if model.editing == nil {
                    Menu {
                        ForEach(AppModel.snoozeOptions().dropFirst(), id: \.label) { o in
                            Button("Send \(o.label == "1 hour" ? "in 1 hour" : o.label == "3 hours" ? "in 3 hours" : o.label)") {
                                scheduleSend(at: o.date)
                            }
                        }
                        Divider()
                        Button("Custom time…") { customSchedule = true }
                    } label: {
                        Image(systemName: "clock").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
                    .help("Schedule send")
                    .popover(isPresented: $customSchedule, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Schedule message").font(.headline)
                            DatePicker("", selection: $customDate, in: Date()...,
                                       displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                            HStack {
                                Spacer()
                                Button("Cancel") { customSchedule = false }
                                Button("Schedule") {
                                    customSchedule = false
                                    scheduleSend(at: customDate)
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(14)
                    }
                }
                Button(action: submit) {
                    Image(systemName: sending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(canSend ? Color.accentColor : .white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Enter) · newline (Shift-Enter)")
            }
            if isThread, model.editing == nil, let cur = model.current, !model.isDirect(cur.channel) {
                Toggle("Also send to \(model.title(cur.channel))", isOn: $broadcast)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(model.assistantMode ? AssistantPanel.tint.opacity(0.14) : .white.opacity(model.dropHover ? 0.2 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(model.assistantMode ? AssistantPanel.tint.opacity(0.7) : .white.opacity(0.22)))
        .padding(10)
        .onChange(of: model.composerInsert) { s in
            guard let s else { return }
            model.closeAssistant()
            setText(s)
            model.composerInsert = nil
        }
        .onChange(of: model.droppedFiles) { urls in
            guard let urls else { return }
            files.append(contentsOf: urls)
            model.droppedFiles = nil
        }
        .onChange(of: model.editing) { m in
            setText(m.map { Mrkdwn.decode($0.text ?? "") } ?? model.current.map { model.draft(for: $0) } ?? "")
        }
        .onChange(of: model.current) { new in
            // Drafts: stash what was typed for the old conversation, restore the new one's.
            if let old = draftRef, model.editing == nil { model.setDraft(text, for: old) }
            files = []
            broadcast = false
            setText(new.map { model.draft(for: $0) } ?? "")
            draftRef = new
        }
        .onChange(of: mentionList.isEmpty) { empty in model.composerPopupOpen = !empty }
        .onChange(of: mention?.query) { _ in mentionIndex = 0 }
        .onChange(of: model.composerDismissTick) { _ in dismissedMentionAt = mention?.range.location }
        .onDisappear { model.composerPopupOpen = false }
        .onChange(of: text) { t in
            if AppModel.mentionToken(in: t, caret: min(caret, (t as NSString).length)) == nil { dismissedMentionAt = nil }
            if model.editing == nil, let ref = model.current { model.setDraft(t, for: ref) }
        }
        .onAppear {
            draftRef = model.current
            if let ref = model.current, text.isEmpty { setText(model.draft(for: ref)) }
        }
    }

    private var canSend: Bool {
        !sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
    }

    private func submit() {
        guard canSend else { return }
        let body = text, attachments = files, bc = broadcast
        sending = true
        Task {
            let ok: Bool
            if let m = model.editing {
                ok = await model.saveEdit(m, text: body)
            } else if model.assistantMode, attachments.isEmpty, let ref = model.current,
                      SlashCommands.parse(body).map({ SlashCommands.isAssistant($0.name) }) != false {
                // In Assistant mode the box talks to Assistant ("/assistant …" works too); other /commands still go to Slack.
                let q = SlashCommands.parse(body).map(\.rest) ?? body
                model.askAssistant(q, about: ref)
                ok = true
            } else if attachments.isEmpty, let result = await model.runSlashCommand(body, broadcast: bc) {
                ok = result
            } else {
                ok = await model.send(text: body, files: attachments, broadcast: bc)
            }
            sending = false
            if ok {
                setText("")
                files = []
                broadcast = false
            }
        }
    }

    private func scheduleSend(at date: Date) {
        let body = text, bc = broadcast
        Task {
            if await model.schedule(text: body, at: date, broadcast: bc) {
                setText("")
                broadcast = false
            }
        }
    }

    /// ↑↓ move through the @mention popup; Enter or Tab inserts. Returns true when the key was used.
    private func mentionKey(_ code: UInt16) -> Bool {
        guard let m = mention else { return false }
        let list = model.mentionSuggestions(m.query)
        guard !list.isEmpty else { return false }
        switch code {
        case 125: mentionIndex = min(mentionIndex + 1, list.count - 1); return true
        case 126: mentionIndex = max(mentionIndex - 1, 0); return true
        case 36, 76, 48: insertMention(list[min(mentionIndex, list.count - 1)]); return true
        default: return false
        }
    }

    private func insertMention(_ s: MentionSuggestion) {
        guard let m = mention else { return }
        let ins = "@\(s.insert) "
        setText((text as NSString).replacingCharacters(in: m.range, with: ins))
        caretTarget = m.range.location + (ins as NSString).length
        mentionIndex = 0
    }

    /// Puts the emoji where the caret is (the character itself; workspace emoji as :name:).
    private func insertEmoji(_ name: String) {
        let ins = Emoji.unicode(name) ?? ":\(name):"
        let ns = text as NSString
        let at = min(caret, ns.length)
        setText(ns.replacingCharacters(in: NSRange(location: at, length: 0), with: ins))
        caretTarget = at + (ins as NSString).length
        model.focusComposerTick += 1
    }

    private func setText(_ t: String) {
        text = t
        textTick += 1
    }

    private func complete(_ c: SlashCommands.Command) {
        setText("/" + c.name + " ")
        model.focusComposerTick += 1
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { files += panel.urls }
    }
}

/// NSTextView wrapper: Enter sends, Shift-Enter adds a newline, paste/drop of files and images attaches them.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var caret: Int
    @Binding var caretTarget: Int?
    var textTick: Int
    var focusTick: Int
    var onSubmit: () -> Void
    var onFiles: ([URL]) -> Void
    var onKey: (UInt16) -> Bool = { _ in false }
    var onTab: () -> Bool = { false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .labelColor
        tv.insertionPointColor = .white
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        tv.onFiles = { [weak coordinator = context.coordinator] in coordinator?.parent.onFiles($0) }
        tv.onTab = { [weak coordinator = context.coordinator] in coordinator?.parent.onTab() ?? false }
        tv.onKey = { [weak coordinator = context.coordinator] in coordinator?.parent.onKey($0) ?? false }
        tv.registerForDraggedTypes(DropReader.types)

        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller = false
        sv.borderType = .noBorder
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? SubmitTextView else { return }
        // Only push text the app changed (send, draft, mention, edit). Never overwrite what you're typing with
        // SwiftUI's copy, which can lag a keystroke behind and used to garble fast typing.
        if context.coordinator.lastTextTick != textTick {
            context.coordinator.lastTextTick = textTick
            if tv.string != text {
                tv.string = text
                if caretTarget == nil { tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) }
                context.coordinator.recalc(tv)
            }
        }
        if let t = caretTarget {
            tv.setSelectedRange(NSRange(location: min(t, (tv.string as NSString).length), length: 0))
            DispatchQueue.main.async { caretTarget = nil; caret = t }
        }
        if context.coordinator.lastFocus != focusTick {
            context.coordinator.lastFocus = focusTick
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocus = -1
        var lastTextTick = -1

        init(_ p: ComposerTextView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            let loc = tv.selectedRange().location
            if parent.caret != loc { parent.caret = loc }
            recalc(tv)
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            let loc = tv.selectedRange().location
            if parent.caret != loc { DispatchQueue.main.async { self.parent.caret = loc } }
        }

        func recalc(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = max(18, min(140, ceil(lm.usedRect(for: tc).height)))
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onTab: (() -> Bool)?
    var onKey: ((UInt16) -> Bool)?

    override func keyDown(with e: NSEvent) {
        let plain = e.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        if plain, !hasMarkedText(), [125, 126, 36, 76, 48].contains(e.keyCode), onKey?(e.keyCode) == true { return }
        if e.keyCode == 48, onTab?() == true { return }
        let isReturn = e.keyCode == 36 || e.keyCode == 76
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isReturn, !flags.contains(.shift), !flags.contains(.option), !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: e)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasImage = pb.string(forType: .string) == nil && pb.availableType(from: [.png, .tiff]) != nil
        if hasFiles || hasImage {
            DropReader.read(pb) { [weak self] urls in if !urls.isEmpty { self?.onFiles?(urls) } }
            return
        }
        pasteAsPlainText(sender)
    }

    // Files, screenshots and images dropped on the text become attachments, not pasted paths.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropReader.canRead(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropReader.canRead(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard DropReader.canRead(pb) else { return super.performDragOperation(sender) }
        DropReader.read(pb) { [weak self] urls in if !urls.isEmpty { self?.onFiles?(urls) } }
        return true
    }
}

/// The @mention suggestions above the reply box.
private struct MentionPopup: View {
    @EnvironmentObject var model: AppModel
    let list: [MentionSuggestion]
    let index: Int
    let onPick: (MentionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                row(s, selected: i == min(index, list.count - 1))
            }
            Text("↑↓ choose · Enter or Tab inserts · Esc dismisses")
                .font(.system(size: 9.5)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 2)
        }
    }

    private func row(_ s: MentionSuggestion, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if let u = s.userID {
                Avatar(url: model.avatar(u), name: s.title, size: 20, online: model.isOnline(u))
            } else {
                Image(systemName: "megaphone.fill").font(.system(size: 10))
                    .foregroundStyle(.secondary).frame(width: 20, height: 20)
            }
            Text(s.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(s.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(selected ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { onPick(s) }
    }
}
