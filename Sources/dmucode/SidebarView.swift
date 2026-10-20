import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    let theme: TerminalTheme
    var onNew: () -> Void
    var onRename: (TmuxSession) -> Void
    var onKill: (TmuxSession) -> Void
    /// Asks for a name; the session, if any, moves into the new group.
    var onNewGroup: (TmuxSession?) -> Void
    var onRenameGroup: (String) -> Void

    var body: some View {
        // ⌘1…⌘9 follow the sidebar order, groups included.
        let shortcuts = Dictionary(uniqueKeysWithValues: store.sessions.prefix(9).enumerated().map { ($1.id, $0 + 1) })
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                Section {
                    // One flat list, so a drag can move a session into or out
                    // of a group (onMove only works within a ForEach).
                    ForEach(store.sidebarRows) { row in
                        switch row {
                        case .group(let name):
                            GroupHeader(name: name)
                                .selectionDisabled()
                                .contextMenu {
                                    Button("Rename Group…") { onRenameGroup(name) }
                                    Button("Remove Group") { store.removeGroup(name) }
                                }
                        case .session(let session):
                            SessionRow(session: session, name: store.layout.displayName(ofSession: session.name),
                                       alert: store.alerts[session.id], shortcut: shortcuts[session.id])
                                .tag(session.id)
                                .contextMenu { sessionMenu(session) }
                        }
                    }
                    .onMove { source, destination in
                        guard let first = source.first else { return }
                        store.moveSidebarRow(from: first, to: destination)
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
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissCommandError() }
                    .help(store.commandError != nil ? "Click to dismiss" : "")
            }

            HStack {
                Button(action: onNew) {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("New tmux session (⌘N)")
                Spacer()
                Button { onNewGroup(nil) } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New group: drag sessions into it to keep them together")
            }
            .padding(10)
        }
        // The terminal theme's background instead of the sidebar material,
        // including under the transparent title bar.
        .background(Color(nsColor: theme.chromeBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private func sessionMenu(_ session: TmuxSession) -> some View {
        Button("Rename…") { onRename(session) }
        Menu("Move to Group") {
            let current = store.layout.group(ofSession: session.name)
            ForEach(store.layout.groups, id: \.self) { group in
                Button(group) { store.setGroup(group, forSession: session.id) }
                    .disabled(group == current)
            }
            if current != nil {
                Button("No Group") { store.setGroup(nil, forSession: session.id) }
            }
            if !store.layout.groups.isEmpty { Divider() }
            Button("New Group…") { onNewGroup(session) }
        }
        Divider()
        Button("Kill Session…", role: .destructive) { onKill(session) }
    }
}

private struct GroupHeader: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct SessionRow: View {
    let session: TmuxSession
    /// Without the "group/" prefix when under that group.
    let name: String
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
                Text(name)
                    .lineLimit(1)
                    .fontWeight(wantsAttention ? .semibold : .regular)
                    .help(session.name)
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
