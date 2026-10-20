import AppKit
import dmucodeCore
import SwiftUI

/// The palette's session mode (⌘K): finds a session by its name, by a
/// window's name or directory, or by a pane's title or program, and
/// switches to it (and to that window and pane). Session templates (sesh)
/// that aren't running are found by name and directory too, and starting
/// one creates the session.
/// Without a query the sessions are listed by when they were last shown,
/// the current one last, so ⌘K Return goes back to the previous session;
/// a few templates follow.
final class SessionSwitcherModel: ObservableObject {
    struct Item: Identifiable {
        enum Target {
            /// The window that matched, or the matched pane's; nil when the
            /// session itself is the match.
            case session(TmuxSession, window: TmuxWindow?, pane: TmuxPane?)
            case template(SessionTemplate)
        }

        let target: Target
        let id: String
        let name: String
        let nameMatches: [Int]
        /// The matched window's name and directory, or the matched pane's
        /// window name, title and program; else the session's current
        /// directory. For a template, its directory and startup command.
        let detail: String
        let detailMatches: [Int]

        init(session: TmuxSession, window: TmuxWindow?, pane: TmuxPane?, nameMatches: [Int],
             detail: String, detailMatches: [Int]) {
            target = .session(session, window: window, pane: pane)
            id = session.id
            name = session.name
            self.nameMatches = nameMatches
            self.detail = detail
            self.detailMatches = detailMatches
        }

        init(template: SessionTemplate, nameMatches: [Int], detail: String, detailMatches: [Int]) {
            target = .template(template)
            id = "template:" + template.name
            name = template.name
            self.nameMatches = nameMatches
            self.detail = detail
            self.detailMatches = detailMatches
        }

        var session: TmuxSession? {
            if case .session(let session, _, _) = target { return session }
            return nil
        }
        var isTemplate: Bool {
            if case .template = target { return true }
            return false
        }
    }

    @Published var text = "" {
        didSet { if text != oldValue { selection = 0 } }
    }
    @Published var selection = 0
    /// Every pane, fetched when the palette opens: their titles change
    /// without an event (Claude Code's follows its conversation).
    @Published var panes: [TmuxPane] = []
    /// Session templates, fetched when the palette opens (sesh's config
    /// may have changed). Running ones are left out of the results.
    @Published var templates: [SessionTemplate] = []

    var onChoose: ((Item) -> Void)?

    private let store: SessionStore
    private static let maxItems = 10
    /// Templates shown after the sessions when nothing is typed.
    private static let maxTemplatesWithoutQuery = 5

    init(store: SessionStore) {
        self.store = store
    }

    /// Empty, for the palette opening again.
    func reset() {
        text = ""
        selection = 0
    }

    func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func choose(_ item: Item? = nil) {
        guard let item = item ?? items[safe: selection] else { NSSound.beep(); return }
        onChoose?(item)
    }

    var currentID: String? { store.selectedID }

    var items: [Item] {
        let sessions = byRecency
        let templates = templatesNotRunning
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            let running = sessions.prefix(Self.maxItems).map { session in
                Item(session: session, window: nil, pane: nil, nameMatches: [],
                     detail: Self.directory(session.windows.first(where: \.isActive)), detailMatches: [])
            }
            let startable = templates.prefix(Self.maxTemplatesWithoutQuery).map {
                Item(template: $0, nameMatches: [], detail: Self.detail($0), detailMatches: [])
            }
            return running + startable
        }

        // Each session once, at its best match; ties keep recency order and
        // prefer the session's own name, then windows, then panes.
        let panesBySession = Dictionary(grouping: panes, by: \.sessionID)
        var scored: [(score: Int, item: Item)] = []
        for session in sessions {
            var best: (score: Int, item: Item)?
            func consider(_ match: FuzzyMatch.Match?, _ item: (FuzzyMatch.Match) -> Item) {
                guard let match, match.score > best?.score ?? .min else { return }
                best = (match.score, item(match))
            }
            let current = Self.directory(session.windows.first(where: \.isActive))
            consider(FuzzyMatch.match(query, in: session.name)) {
                Item(session: session, window: nil, pane: nil, nameMatches: $0.indices, detail: current, detailMatches: [])
            }
            for window in session.windows {
                let path = Self.directory(window)
                let detail = window.name + "  " + path
                consider(FuzzyMatch.match(query, in: window.name)) {
                    Item(session: session, window: window, pane: nil, nameMatches: [], detail: detail,
                         detailMatches: $0.indices)
                }
                let offset = window.name.count + 2
                consider(FuzzyMatch.match(query, in: path)) {
                    Item(session: session, window: window, pane: nil, nameMatches: [], detail: detail,
                         detailMatches: $0.indices.map { $0 + offset })
                }
            }
            // A pane by its title or program, shown after its window's name:
            // "claude  ✳ Fix the login bug  claude".
            for pane in panesBySession[session.id] ?? [] {
                guard let window = session.windows.first(where: { $0.id == pane.windowID }) else { continue }
                let parts = [pane.meaningfulTitle, pane.meaningfulCommand].compactMap { $0 }
                var offset = window.name.count + 2
                let detail = ([window.name] + parts).joined(separator: "  ")
                for part in parts {
                    let start = offset
                    consider(FuzzyMatch.match(query, in: part)) {
                        Item(session: session, window: window, pane: pane, nameMatches: [], detail: detail,
                             detailMatches: $0.indices.map { $0 + start })
                    }
                    offset += part.count + 2
                }
            }
            if let best { scored.append(best) }
        }
        // Templates after the sessions, so a session wins a tie with the
        // template it was started from (same name) and with any other.
        for template in templates {
            let detail = Self.detail(template)
            var best: (score: Int, item: Item)?
            if let match = FuzzyMatch.match(query, in: template.name) {
                best = (match.score, Item(template: template, nameMatches: match.indices, detail: detail, detailMatches: []))
            }
            if let match = FuzzyMatch.match(query, in: Self.directory(template.path)),
               match.score > best?.score ?? .min {
                best = (match.score, Item(template: template, nameMatches: [], detail: detail, detailMatches: match.indices))
            }
            if let best { scored.append(best) }
        }
        return Array(scored.enumerated()
            .sorted { ($0.element.score, $1.offset) > ($1.element.score, $0.offset) }
            .map(\.element.item)
            .prefix(Self.maxItems))
    }

    /// Templates whose session doesn't exist; the running ones are found as
    /// sessions.
    private var templatesNotRunning: [SessionTemplate] {
        let names = Set(store.sessions.map(\.name))
        return templates.filter { !names.contains($0.name) }
    }

    /// "~/Code/x  claude": the directory, and the startup command if any.
    private static func detail(_ template: SessionTemplate) -> String {
        let command = template.startupCommand.trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? directory(template.path) : directory(template.path) + "  " + command
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
        directory(window?.path ?? "")
    }

    /// Without a trailing slash (sesh keeps the config's), with "~".
    private static func directory(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// One line per item for the debug hook: "> name [window] detail", or
    /// "+name" for a template.
    var debugState: String {
        let rows = items.enumerated().map { index, item in
            let marker = index == selection ? ">" : " "
            switch item.target {
            case .session(let session, let window, let pane):
                return marker + session.name + (window.map { " [\($0.name)]" } ?? "") + (pane.map { " {\($0.id)}" } ?? "")
            case .template(let template):
                return marker + "+" + template.name
            }
        }
        return "text=\(text) items=\(rows.joined(separator: ","))"
    }
}

/// Below the palette's field in session mode: the matching sessions.
struct SessionResults: View {
    @ObservedObject var model: SessionSwitcherModel
    @ObservedObject var store: SessionStore

    var body: some View {
        let items = model.items
        Divider()
        if items.isEmpty {
            Text(model.templates.isEmpty ? "No matching session" : "No matching session or template")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    SwitcherRow(item: item, selected: index == model.selection,
                                current: item.session?.id == model.currentID,
                                wantsAttention: item.session.map(store.needsAttention) ?? false)
                        .contentShape(Rectangle())
                        .onTapGesture { model.choose(item) }
                }
            }
            .padding(4)
        }
    }
}

private struct SwitcherRow: View {
    let item: SessionSwitcherModel.Item
    let selected: Bool
    let current: Bool
    let wantsAttention: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: wantsAttention ? "bell.fill" : item.isTemplate ? "plus.circle" : "terminal")
                .foregroundStyle(wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            Text(Self.highlight(item.name, item.nameMatches))
                .font(.system(size: 13))
                .lineLimit(1)
            Text(Self.highlight(item.detail, item.detailMatches))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if current || item.isTemplate {
                Text(current ? "current" : "sesh")
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
