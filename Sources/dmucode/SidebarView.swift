import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    let theme: TerminalTheme
    var onNew: () -> Void
    var onRename: (TmuxSession) -> Void
    var onKill: (TmuxSession) -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                Section {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(session: session, alert: store.alerts[session.id],
                                   shortcut: index < 9 ? index + 1 : nil)
                            .tag(session.id)
                            .contextMenu {
                                Button("Rename…") { onRename(session) }
                                Divider()
                                Button("Kill Session…", role: .destructive) { onKill(session) }
                            }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Text(store.tmux.socketName.map { "tmux (-L \($0))" } ?? "tmux")
                        Circle()
                            .fill(store.isLive ? Color.green : Color.secondary)
                            .frame(width: 5, height: 5)
                            .help(store.isLive
                                  ? "Live: updates arrive as tmux control-mode events"
                                  : "Polling: waiting for a tmux session to connect to")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            HStack {
                Button(action: onNew) {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("New tmux session (⌘N)")
                Spacer()
            }
            .padding(10)
        }
        // The terminal theme's background instead of the sidebar material,
        // including under the transparent title bar.
        .background(Color(nsColor: theme.chromeBackground).ignoresSafeArea())
    }
}

private struct SessionRow: View {
    let session: TmuxSession
    let alert: TerminalAlert?
    let shortcut: Int?

    private var wantsAttention: Bool { alert != nil || session.hasBell }

    var body: some View {
        HStack(spacing: 8) {
            // A bell or a notification (e.g. Claude Code waiting for input)
            // in a session the user isn't looking at.
            Image(systemName: wantsAttention ? "bell.fill" : "terminal")
                .foregroundStyle(wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .lineLimit(1)
                    .fontWeight(wantsAttention ? .semibold : .regular)
                if let message = alert?.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(message)
                } else {
                    Text(session.windows.count == 1 ? "1 window" : "\(session.windows.count) windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !wantsAttention && session.hasActivity {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .help("Activity in a window (monitor-activity)")
            }
            if session.attachedClients > 0 {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .help("\(session.attachedClients) client(s) attached")
            }
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
