import SwiftUI

/// The palette's command mode (a leading ":", or ⌘:): a native take on
/// tmux's `:` prompt. Lines are parsed by tmux and run as the shown
/// session's active pane, so they act on what the terminal shows. Completes
/// command names, shows the usage of the command being typed, and shows
/// output and errors in place.
final class CommandBarModel: ObservableObject {
    enum Outcome: Equatable {
        case output(String)
        case error(String)
    }

    /// The command line, without the palette's ":".
    @Published var text = "" {
        didSet {
            guard text != oldValue else { return }
            selection = 0
            outcome = nil
        }
    }
    @Published var selection = 0
    @Published private(set) var outcome: Outcome?
    @Published private(set) var isRunning = false
    @Published var commands: [TmuxCommand] = []

    /// Runs a line; calls back on the main thread with its output.
    var onRun: ((_ line: String, _ done: @escaping (Result<String, Error>) -> Void) -> Void)?
    /// A command ran without output: the palette closes.
    var onDone: (() -> Void)?

    private static let historyKey = "commandBarHistory"
    private var history: [String] = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    /// Position while stepping through history with ↑/↓; nil when not.
    private var historyIndex: Int?

    /// Empty, for the palette opening again.
    func reset() {
        text = ""
        outcome = nil
        historyIndex = nil
    }

    // MARK: Completion

    /// Commands matching the first word while it is being typed: names and
    /// aliases starting with it first, then names containing it.
    var suggestions: [TmuxCommand] {
        let word = text.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !text.contains(" ") else { return [] }
        let prefix = commands.filter { $0.name.hasPrefix(word) || $0.alias.hasPrefix(word) }
        let contains = commands.filter { !$0.name.hasPrefix(word) && !$0.alias.hasPrefix(word) && $0.name.contains(word) }
        return Array((prefix + contains).prefix(8))
    }

    /// The command named by the first word (name or alias), for its usage.
    var currentCommand: TmuxCommand? {
        guard let word = text.split(separator: " ").first.map(String.init) else { return nil }
        return commands.first { $0.name == word || (!$0.alias.isEmpty && $0.alias == word) }
    }

    func complete(_ command: TmuxCommand? = nil) {
        guard let command = command ?? suggestions[safe: selection] else { return }
        text = command.name + " "
    }

    /// ↑/↓: moves in the suggestions while there are some, else in history.
    func move(_ delta: Int) {
        let count = suggestions.count
        if count > 0 {
            selection = (selection + delta + count) % count
            return
        }
        guard !history.isEmpty else { return }
        let index = (historyIndex ?? history.count) + delta
        guard index >= 0 else { return }
        if index >= history.count {
            historyIndex = nil
            text = ""
        } else {
            historyIndex = index
            text = history[index]
        }
    }

    // MARK: Running

    func submit() {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !isRunning, let onRun else { return }
        remember(line)
        isRunning = true
        onRun(line) { [weak self] result in
            guard let self else { return }
            self.isRunning = false
            switch result {
            case .success(let output) where output.isEmpty:
                self.onDone?()
            case .success(let output):
                self.outcome = .output(output)
            case .failure(let error):
                self.outcome = .error("\(error)")
            }
        }
    }

    private func remember(_ line: String) {
        history.removeAll { $0 == line }
        history.append(line)
        history = Array(history.suffix(100))
        historyIndex = nil
        UserDefaults.standard.set(history, forKey: Self.historyKey)
    }
}

/// Below the palette's field in command mode: completions, else the usage
/// of the command being typed; and the last command's output or error.
struct CommandResults: View {
    @ObservedObject var model: CommandBarModel
    /// A completion was clicked.
    var onPick: (TmuxCommand) -> Void

    static let mono = Font.system(size: 13, design: .monospaced)

    var body: some View {
        let suggestions = model.suggestions
        if !suggestions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.name) { index, command in
                    SuggestionRow(command: command, selected: index == model.selection, mono: Self.mono)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(command) }
                }
            }
            .padding(4)
        } else if let command = model.currentCommand, model.outcome == nil {
            Divider()
            Text("\(command.name) \(command.usage)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let outcome = model.outcome {
            Divider()
            ScrollView {
                Group {
                    switch outcome {
                    case .output(let text):
                        Text(text).foregroundStyle(.primary)
                    case .error(let text):
                        Text(text).foregroundStyle(.red)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// The palette's floating panel.
    func paletteChrome(theme: TerminalTheme) -> some View {
        frame(width: 600)
            .background(Color(nsColor: theme.background))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: theme.foreground).opacity(0.15)))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            // Room for the shadow inside the hosting view, which clips.
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
    }

    /// A suggestion or result row, highlighted while selected.
    func paletteRow(selected: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.35) : .clear))
    }
}

private struct SuggestionRow: View {
    let command: TmuxCommand
    let selected: Bool
    let mono: Font

    var body: some View {
        HStack(spacing: 8) {
            Text(command.name)
                .font(mono)
            if !command.alias.isEmpty {
                Text(command.alias)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(command.usage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .paletteRow(selected: selected)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
