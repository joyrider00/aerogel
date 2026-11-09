import SwiftUI

/// Assistant, inside the Slack conversation: ask about the thread or tell it what to do. Its Slack drafts show as
/// cards here and post (as you) only when you press Send.
struct AssistantPanel: View {
    @EnvironmentObject var model: AppModel
    let ref: ConversationRef

    static let tint = Color(red: 0.62, green: 0.52, blue: 1.0)

    private var turns: [AssistantTurn] { model.assistantSession(ref)?.turns ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Self.tint)
                Text(Prefs.assistantName).font(.system(size: 12.5, weight: .semibold))
                Text("knows this conversation").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                if !turns.isEmpty {
                    IconButton(symbol: "square.and.pencil", help: "New \(Prefs.assistantName) chat", size: 11) { model.newAssistantChat(ref) }
                }
                IconButton(symbol: "xmark", help: "Back to Slack (Esc)", size: 10) { model.closeAssistant() }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollViewReader { proxy in
                FitScroll(maxHeight: 300) { content }
                .onChange(of: turns.last?.answer.count ?? 0) { _ in proxy.scrollTo("assistant-end", anchor: .bottom) }
                .onChange(of: turns.count) { _ in proxy.scrollTo("assistant-end", anchor: .bottom) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Self.tint.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Self.tint.opacity(0.45)))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if turns.isEmpty {
                Text("Ask about this conversation or tell \(Prefs.assistantName) what to do. It reads the thread, and anything it drafts waits here for you to send.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(turns) { AssistantTurnView(turn: $0, ref: ref) }
            Color.clear.frame(height: 1).id("assistant-end")
        }
        .padding(10)
    }
}

struct AssistantTurnView: View {
    @EnvironmentObject var model: AppModel
    let turn: AssistantTurn
    let ref: ConversationRef

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.question)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !turn.answer.isEmpty {
                Text(Self.markdown(turn.answer))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !turn.done {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(turn.activity ?? "Thinking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let err = turn.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(turn.approvals) { ApprovalCard(approval: $0, ref: ref) }
            if turn.done, turn.error == nil, !turn.answer.isEmpty, turn.approvals.isEmpty {
                Button {
                    model.composerInsert = turn.answer
                } label: {
                    Label("Use as my reply", systemImage: "arrow.down.doc").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Put this text in the reply box so you can edit and send it yourself")
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// A Slack message Assistant drafted. Edit it if you like; Send posts it as you, Discard drops it.
struct ApprovalCard: View {
    @EnvironmentObject var model: AppModel
    let approval: AssistantApproval
    let ref: ConversationRef
    @State private var text = ""
    @State private var busy = false

    private var pending: Bool { approval.status == "pending" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: approval.kind == "slack" ? "paperplane.fill" : "checkmark.seal")
                    .font(.system(size: 10)).foregroundStyle(AssistantPanel.tint)
                Text(approval.kind == "slack" ? "Slack draft" : approval.kind.capitalized)
                    .font(.system(size: 10.5, weight: .semibold))
                if let to = approval.to { Text("→ \(model.conversations[to].map { _ in model.title(to) } ?? to)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                statusLabel
            }
            if pending && approval.kind == "slack" {
                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...8)
                    .padding(8)
                    .glassChip(radius: 8, opacity: 0.08)
            } else {
                Text(approval.text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = approval.error {
                Text(err).font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            if pending {
                HStack {
                    Spacer()
                    Button("Discard") {
                        busy = true
                        model.decideAssistant(approval, approve: false, text: nil, ref: ref)
                    }
                    Button("Send") {
                        busy = true
                        model.decideAssistant(approval, approve: true,
                                           text: approval.kind == "slack" && text != approval.text ? text : nil, ref: ref)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(AssistantPanel.tint)
                    .disabled(approval.kind == "slack" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AssistantPanel.tint.opacity(0.35)))
        .onAppear { text = approval.text }
        .onChange(of: approval.status) { _ in busy = false }
        .onChange(of: approval.error) { _ in busy = false }
    }

    @ViewBuilder private var statusLabel: some View {
        switch approval.status {
        case "sent": Label("Sent", systemImage: "checkmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(.green)
        case "rejected": Text("Discarded").font(.system(size: 10.5)).foregroundStyle(.secondary)
        case "failed": Text("Failed").font(.system(size: 10.5)).foregroundStyle(.orange)
        case "approved": Text("Approved").font(.system(size: 10.5)).foregroundStyle(.secondary)
        default: Text("Waiting for you").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}
