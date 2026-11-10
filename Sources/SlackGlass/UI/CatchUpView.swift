import SwiftUI

/// Catch up: one unread conversation at a time. → marks it read, ← keeps it unread, Return opens it.
struct CatchUpView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                Text("Catch up").font(.system(size: 12.5, weight: .semibold))
                if model.catchUpScanning { ProgressView().controlSize(.mini) }
                Spacer()
                if model.catchUpCard != nil {
                    let left = model.catchUpCards.count - model.catchUpIndex
                    Text("\(left)\(model.catchUpScanning ? "+" : "") left")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                        .help(model.catchUpScanning ? "Still checking \(model.catchUpTotal - model.catchUpChecked) more conversations" : "")
                }
                IconButton(symbol: "xmark", help: "Back to Activity", size: 10) { model.closeCatchUp() }
            }
            .padding(.horizontal, 6)

            if let card = model.catchUpCard {
                CatchUpCardView(card: card)
                    .id(card.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                HStack(spacing: 6) {
                    actionButton("Keep unread", symbol: "arrow.left", help: "Keep unread and go to the next (←)") {
                        withAnimation(.easeOut(duration: 0.2)) { model.catchUpSkip() }
                    }
                    actionButton("Open", symbol: "return", help: "Open the conversation (Return)") { model.catchUpOpen() }
                    actionButton("Mark read", symbol: "arrow.right", prominent: true, help: "Mark read and go to the next (→)") {
                        withAnimation(.easeOut(duration: 0.2)) { model.catchUpMarkRead() }
                    }
                }
            } else if model.catchUpScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.catchUpTotal > 0
                         ? "Checking your conversations… \(model.catchUpChecked) of \(model.catchUpTotal)"
                         : "Looking for unread messages…")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
                    Text(model.catchUpCards.isEmpty ? "Nothing unread. You're all caught up." : "You're all caught up.")
                        .font(.system(size: 12.5, weight: .medium))
                    if model.catchUpIndex > 0 {
                        Button("Go back") { withAnimation { model.catchUpBack() } }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, prominent: Bool = false, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if symbol == "arrow.left" { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                if symbol != "arrow.left" { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(prominent ? Color.blue.opacity(0.85) : Color.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct CatchUpCardView: View {
    @EnvironmentObject var model: AppModel
    let card: CatchUpCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.title(card.channel)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(card.messages.count)\(card.messages.count == 20 ? "+" : "") new")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue.opacity(0.7)))
                Spacer()
            }
            FitScroll(maxHeight: 380) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(card.messages, id: \.ts) { m in
                        let a = model.author(of: m)
                        HStack(alignment: .top, spacing: 7) {
                            Avatar(url: a.avatar, name: a.name, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(a.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                    Text(TimeFormat.stamp(m.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(m.text?.isEmpty == false ? model.render(m.text ?? "") : AttributedString(m.previewText))
                                    .font(.system(size: 12)).lineLimit(8)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let n = m.reply_count, n > 0 {
                                    Text("\(n) \(n == 1 ? "reply" : "replies")").font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

/// The way into Catch up, at the top of Activity.
struct CatchUpEntry: View {
    @EnvironmentObject var model: AppModel
    @State private var hover = false

    var body: some View {
        Button { model.startCatchUp() } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack").font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                Text("Catch up on unread channels").font(.system(size: 11.5, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Go through every channel and chat with unread messages, one at a time")
    }
}
