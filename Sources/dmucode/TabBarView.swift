import SwiftUI

/// The selected session's tmux windows as tabs above the terminal. Clicking
/// a tab selects the window in tmux; switching windows inside tmux moves the
/// highlighted tab (via %session-window-changed).
struct TabBarView: View {
    @ObservedObject var store: SessionStore
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
                        WindowTab(window: window, theme: theme, onSelect: { onSelect(window) })
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
            .help("New tmux window")
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
    let theme: TerminalTheme
    var onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text("\(window.index)")
                .foregroundStyle(.secondary)
            Text(window.name)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: theme.foreground)
                    .opacity(window.isActive ? 0.14 : hovering ? 0.06 : 0)))
        .foregroundStyle(window.isActive ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help("\(window.index): \(window.name)")
    }
}
