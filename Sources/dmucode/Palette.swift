import SwiftUI

/// The palette below the tab bar, one field for two jobs: finding a session
/// (⌘K), or running a tmux command (⌘:). Typing ":" into an empty search
/// turns it into a command line, and ⌫ on an empty command line turns it
/// back, without leaving the field. The ":" is shown before the field, not
/// in it: NSTextField selects all its text after Return and on focus, and
/// typing over a selected ":" would drop out of command mode.
final class PaletteModel: ObservableObject {
    enum Mode {
        case sessions
        case command
    }

    @Published private(set) var isOpen = false
    @Published private(set) var mode = Mode.sessions

    let sessions: SessionSwitcherModel
    let command: CommandBarModel

    var onClose: (() -> Void)?

    init(sessions: SessionSwitcherModel, command: CommandBarModel) {
        self.sessions = sessions
        self.command = command
    }

    /// The field's text: the search, or the command line. A search that
    /// starts with ":" becomes a command line.
    var text: String {
        get { mode == .command ? command.text : sessions.text }
        set {
            switch mode {
            case .command:
                command.text = newValue
            case .sessions where newValue.hasPrefix(":"):
                // Switched on the next turn of the run loop: the field
                // ignores a value its own edit's setter changes, but follows
                // one changed afterwards (as with Tab completion).
                sessions.text = newValue
                DispatchQueue.main.async { [self] in
                    guard mode == .sessions, sessions.text.hasPrefix(":") else { return }
                    command.text = String(sessions.text.dropFirst())
                    sessions.reset()
                    mode = .command
                }
            case .sessions:
                sessions.text = newValue
            }
        }
    }

    /// ⌫ on an empty command line: back to the search.
    func leaveCommandMode() {
        guard mode == .command, command.text.isEmpty else { return }
        sessions.reset()
        mode = .sessions
    }

    /// Opens empty in a mode, or switches an open palette to it.
    func open(_ mode: Mode) {
        sessions.reset()
        command.reset()
        self.mode = mode
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        onClose?()
    }
}

struct PaletteView: View {
    @ObservedObject var palette: PaletteModel
    @ObservedObject var sessions: SessionSwitcherModel
    @ObservedObject var command: CommandBarModel
    @ObservedObject var store: SessionStore
    let theme: TerminalTheme
    @FocusState private var focused: Bool

    init(palette: PaletteModel, store: SessionStore, theme: TerminalTheme) {
        self.palette = palette
        self.sessions = palette.sessions
        self.command = palette.command
        self.store = store
        self.theme = theme
    }

    private var isCommand: Bool { palette.mode == .command }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One field for both modes, never rebuilt, so it keeps focus
            // when a ":" switches the mode.
            HStack(spacing: 6) {
                Group {
                    if isCommand {
                        Text(":").font(CommandResults.mono)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 14)
                TextField(isCommand ? "tmux command" : "Switch to session, or : for a tmux command",
                          text: Binding(get: { palette.text }, set: { palette.text = $0 }))
                    .textFieldStyle(.plain)
                    .font(isCommand ? CommandResults.mono : .system(size: 13))
                    .focused($focused)
                    .onSubmit { isCommand ? command.submit() : sessions.choose() }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.tab) {
                        guard isCommand else { return .ignored }
                        command.complete()
                        return .handled
                    }
                    // ⌫ sends U+007F on macOS, not KeyEquivalent.delete's U+0008.
                    .onKeyPress(keys: [.delete, KeyEquivalent("\u{7f}")]) { _ in
                        guard isCommand, command.text.isEmpty else { return .ignored }
                        palette.leaveCommandMode()
                        return .handled
                    }
                    .onExitCommand { palette.close() }
                if command.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isCommand {
                CommandResults(model: command) { picked in
                    command.complete(picked)
                    focused = true
                }
            } else {
                SessionResults(model: sessions, store: store)
            }
        }
        .paletteChrome(theme: theme)
        // Only gains focus here; on close the terminal takes it back
        // (TerminalContainerController.setOverlayVisible).
        .onChange(of: palette.isOpen) { _, open in if open { focused = true } }
        .onAppear { focused = palette.isOpen }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        isCommand ? command.move(delta) : sessions.move(delta)
        return .handled
    }
}
