import SwiftUI

/// The selected session's tmux windows as tabs above the terminal. Clicking
/// a tab selects the window in tmux; switching windows inside tmux moves the
/// highlighted tab (via %session-window-changed). Each tab shows its active
/// pane's directory and, inside a repository, the git status.
struct TabBarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var git: GitStatusStore
    let theme: TerminalTheme
    var onSelect: (TmuxWindow) -> Void
    var onNew: () -> Void
    var onRename: (TmuxWindow) -> Void
    var onClose: (TmuxWindow) -> Void

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.selectedSession?.windows ?? []) { window in
                        WindowTab(window: window, git: git.statuses[window.path], theme: theme,
                                  onSelect: { onSelect(window) })
                            .contextMenu {
                                Button("Rename…") { onRename(window) }
                                Divider()
                                Button("Close Window…", role: .destructive) { onClose(window) }
                            }
                    }
                }
                .padding(.horizontal, 6)
            }
            Button(action: onNew) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("New tmux window (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: Self.height)
        .background(Color(nsColor: theme.chromeBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: theme.foreground).opacity(0.1))
                .frame(height: 1)
        }
    }
}

private struct WindowTab: View {
    let window: TmuxWindow
    let git: GitStatus?
    let theme: TerminalTheme
    var onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text("\(window.index)")
                .foregroundStyle(.secondary)
            if window.hasBell {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if window.hasActivity {
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
            }
            Text(window.name)
                .lineLimit(1)
            if !window.path.isEmpty {
                Text(folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let git {
                GitBadge(status: git)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: theme.foreground)
                    .opacity(window.isActive ? 0.14 : hovering ? 0.06 : 0)))
        .foregroundStyle(window.isActive ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    /// The directory's name; "~" for home.
    private var folder: String {
        let path = window.path
        return path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
    }

    private var tooltip: String {
        var lines = ["\(window.index): \(window.name)", (window.path as NSString).abbreviatingWithTildeInPath]
        if let git {
            var parts = ["branch \(git.branch)"]
            if git.changed > 0 { parts.append("\(git.changed) changed") }
            if git.conflicted > 0 { parts.append("\(git.conflicted) conflicted") }
            if git.untracked > 0 { parts.append("\(git.untracked) untracked") }
            if git.ahead > 0 { parts.append("\(git.ahead) ahead") }
            if git.behind > 0 { parts.append("\(git.behind) behind") }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Branch, a dot when the tree has changes, and ahead/behind counts.
private struct GitBadge: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
            Text(status.branch)
                .lineLimit(1)
                .truncationMode(.middle)
            if status.conflicted > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            } else if status.isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
            if status.ahead > 0 { Text("↑\(status.ahead)") }
            if status.behind > 0 { Text("↓\(status.behind)") }
        }
        .foregroundStyle(.secondary)
    }
}
