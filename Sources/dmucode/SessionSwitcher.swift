import AppKit
import SwiftUI

/// The ⌘K switcher: finds a session by its name, or by a window's name or
/// directory, and switches to it (and to that window). Without a query the
/// sessions are listed by when they were last shown, the current one last,
/// so ⌘K Return goes back to the previous session.
final class SessionSwitcherModel: ObservableObject {
    struct Item: Identifiable {
        let session: TmuxSession
        /// The window that matched; nil when the session itself is the match.
        let window: TmuxWindow?
        let nameMatches: [Int]
        /// The matched window's name and directory, else the session's
        /// current directory.
        let detail: String
        let detailMatches: [Int]
        var id: String { session.id }
    }

    @Published private(set) var isOpen = false
    @Published var text = "" {
        didSet { if text != oldValue { selection = 0 } }
    }
    @Published var selection = 0

    var onChoose: ((_ session: TmuxSession, _ window: TmuxWindow?) -> Void)?
    var onClose: (() -> Void)?

    private let store: SessionStore
    private static let maxItems = 10

    init(store: SessionStore) {
        self.store = store
    }

    func open() {
        text = ""
        selection = 0
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        text = ""
        onClose?()
    }

    func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func choose(_ item: Item? = nil) {
        guard let item = item ?? items[safe: selection] else { NSSound.beep(); return }
        close()
        onChoose?(item.session, item.window)
    }

    var currentID: String? { store.selectedID }

    var items: [Item] {
        let sessions = byRecency
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return sessions.prefix(Self.maxItems).map { session in
                Item(session: session, window: nil, nameMatches: [],
                     detail: Self.directory(session.windows.first(where: \.isActive)), detailMatches: [])
            }
        }

        // Each session once, at its best match; ties keep recency order and
        // prefer the session's own name.
        var scored: [(score: Int, item: Item)] = []
        for session in sessions {
            var best: (score: Int, item: Item)?
            func consider(_ match: FuzzyMatch.Match?, _ item: (FuzzyMatch.Match) -> Item) {
                guard let match, match.score > best?.score ?? .min else { return }
                best = (match.score, item(match))
            }
            let current = Self.directory(session.windows.first(where: \.isActive))
            consider(FuzzyMatch.match(query, in: session.name)) {
                Item(session: session, window: nil, nameMatches: $0.indices, detail: current, detailMatches: [])
            }
            for window in session.windows {
                let path = Self.directory(window)
                let detail = window.name + "  " + path
                consider(FuzzyMatch.match(query, in: window.name)) {
                    Item(session: session, window: window, nameMatches: [], detail: detail, detailMatches: $0.indices)
                }
                let offset = window.name.count + 2
                consider(FuzzyMatch.match(query, in: path)) {
                    Item(session: session, window: window, nameMatches: [], detail: detail,
                         detailMatches: $0.indices.map { $0 + offset })
                }
            }
            if let best { scored.append(best) }
        }
        return Array(scored.enumerated()
            .sorted { ($0.element.score, $1.offset) > ($1.element.score, $0.offset) }
            .map(\.element.item)
            .prefix(Self.maxItems))
    }

    /// Previously shown sessions, most recent first, then the never shown
    /// ones in sidebar order, then the current one.
    private var byRecency: [TmuxSession] {
        let sessions = store.sessions
        let current = store.selectedID
        let recent = store.recentIDs.filter { $0 != current }
        var ordered = recent.compactMap { id in sessions.first { $0.id == id } }
        ordered += sessions.filter { $0.id != current && !recent.contains($0.id) }
        ordered += sessions.filter { $0.id == current }
        return ordered
    }

    private static func directory(_ window: TmuxWindow?) -> String {
        guard let path = window?.path, !path.isEmpty else { return "" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// One line per item for the debug hook: "> name [window] detail".
    var debugState: String {
        let rows = items.enumerated().map { index, item in
            (index == selection ? ">" : " ") + item.session.name + (item.window.map { " [\($0.name)]" } ?? "")
        }
        return "switcher open=\(isOpen) text=\(text) items=\(rows.joined(separator: ","))"
    }
}

struct SessionSwitcherView: View {
    @ObservedObject var model: SessionSwitcherModel
    @ObservedObject var store: SessionStore
    let theme: TerminalTheme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to session", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { model.choose() }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onExitCommand { model.close() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            let items = model.items
            Divider()
            if items.isEmpty {
                Text("No matching session")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SwitcherRow(item: item, selected: index == model.selection,
                                    current: item.session.id == model.currentID,
                                    wantsAttention: store.needsAttention(item.session))
                            .contentShape(Rectangle())
                            .onTapGesture { model.choose(item) }
                    }
                }
                .padding(4)
            }
        }
        .paletteChrome(theme: theme)
        .onAppear { focused = true }
    }
}

private struct SwitcherRow: View {
    let item: SessionSwitcherModel.Item
    let selected: Bool
    let current: Bool
    let wantsAttention: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: wantsAttention ? "bell.fill" : "terminal")
                .foregroundStyle(wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            Text(Self.highlight(item.session.name, item.nameMatches))
                .font(.system(size: 13))
                .lineLimit(1)
            Text(Self.highlight(item.detail, item.detailMatches))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if current {
                Text("current")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .paletteRow(selected: selected)
    }

    /// The matched characters in bold, in the regular text color.
    private static func highlight(_ text: String, _ indices: [Int]) -> AttributedString {
        guard !indices.isEmpty else { return AttributedString(text) }
        let matched = Set(indices)
        var result = AttributedString()
        for (index, character) in text.enumerated() {
            var part = AttributedString(String(character))
            if matched.contains(index) {
                part.inlinePresentationIntent = .stronglyEmphasized
                part.foregroundColor = .primary
            }
            result += part
        }
        return result
    }
}

/// The floating slot below the tab bar: the ⌘K switcher while it is open,
/// otherwise the ⌘: command bar (hidden while closed).
struct PaletteOverlay: View {
    @ObservedObject var commandBar: CommandBarModel
    @ObservedObject var switcher: SessionSwitcherModel
    let store: SessionStore
    let theme: TerminalTheme

    var body: some View {
        if switcher.isOpen {
            SessionSwitcherView(model: switcher, store: store, theme: theme)
        } else {
            CommandBarView(model: commandBar, theme: theme)
        }
    }
}
