import Foundation

/// The sidebar's order and groups, kept by session name: a session takes
/// its place again whenever one with the same name exists, after a reboot,
/// a tmux server restart or when created anew.
///
/// A flat list: a group header is followed by its sessions, and sessions
/// before the first header are ungrouped. Sessions that aren't running keep
/// their place in it; new names are added at the end of the ungrouped ones.
///
/// A name like "work/api" files itself: seen for the first time (or renamed
/// to it), the session goes into group "work", created if needed, and is
/// shown there as "api". The prefix matches a group whatever its case, so
/// "projects/x" joins an existing "Projects". Dragging it elsewhere
/// afterwards is up to the user.
public struct SidebarLayout: Codable, Equatable {
    enum Entry: Codable, Equatable {
        case group(String)
        case session(String)

        var groupName: String? {
            if case .group(let name) = self { return name }
            return nil
        }
    }

    /// A sidebar row: a group header or a running session.
    public enum Row: Identifiable, Equatable {
        case group(String)
        case session(TmuxSession)

        public var id: String {
            switch self {
            case .group(let name): return "group:" + name
            case .session(let session): return session.id
            }
        }

        fileprivate var entry: Entry {
            switch self {
            case .group(let name): return .group(name)
            case .session(let session): return .session(session.name)
            }
        }
    }

    private(set) var entries: [Entry] = []

    public init() {}

    public var groups: [String] { entries.compactMap(\.groupName) }

    /// Every group header, and the running sessions in their places.
    public func rows(for sessions: [TmuxSession]) -> [Row] {
        var layout = self
        layout.include(sessions.map(\.name))
        let byName = Dictionary(sessions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.entries.compactMap { entry in
            switch entry {
            case .group(let name): return .group(name)
            case .session(let name): return byName[name].map(Row.session)
            }
        }
    }

    /// The sessions in sidebar order (⌘1…⌘9, ⌘↑/⌘↓).
    func sorted(_ sessions: [TmuxSession]) -> [TmuxSession] {
        rows(for: sessions).compactMap { row in
            if case .session(let session) = row { return session }
            return nil
        }
    }

    /// Adds names seen for the first time: at the end of their prefix's
    /// group ("work/api" → work), else at the end of the ungrouped ones.
    mutating func include(_ names: [String]) {
        var known = Set(entries.compactMap { entry -> String? in
            if case .session(let name) = entry { return name }
            return nil
        })
        let new = names.filter { known.insert($0).inserted }
        guard !new.isEmpty else { return }
        entries.insert(contentsOf: new.filter { Self.prefix(of: $0) == nil }.map(Entry.session), at: ungroupedEnd)
        for name in new {
            guard let prefix = Self.prefix(of: name)?.group else { continue }
            let group = self.group(matching: prefix) ?? prefix
            addGroup(group)
            entries.insert(.session(name), at: groupRange(group)!.upperBound)
        }
    }

    /// A renamed session keeps its place, replacing any remembered place of
    /// the new name. A new prefix files it under that group; dropping the
    /// prefix takes it out of the old prefix's group.
    mutating func renameSession(_ old: String, to new: String) {
        guard old != new else { return }
        let oldPrefix = Self.prefix(of: old)?.group, newPrefix = Self.prefix(of: new)?.group
        let inOldGroup = oldPrefix.map { Self.same(group(ofSession: old), $0) } ?? false
        entries.removeAll { $0 == .session(new) }
        guard let index = entries.firstIndex(of: .session(old)) else {
            include([new])
            return
        }
        entries[index] = .session(new)
        guard !Self.same(oldPrefix, newPrefix) else { return }
        if let newPrefix {
            let group = group(matching: newPrefix) ?? newPrefix
            addGroup(group)
            setGroup(group, ofSession: new)
        } else if inOldGroup {
            setGroup(nil, ofSession: new)
        }
    }

    /// "work/api" → ("work", "api"); nil without a "/" or with nothing
    /// before or after it. "a/b/c" → ("a", "b/c").
    static func prefix(of name: String) -> (group: String, rest: String)? {
        guard let slash = name.firstIndex(of: "/") else { return nil }
        let group = String(name[..<slash]), rest = String(name[name.index(after: slash)...])
        return group.isEmpty || rest.isEmpty ? nil : (group, rest)
    }

    /// What the sidebar shows: the name without its prefix while the session
    /// is in the group the prefix names, else the whole name.
    public func displayName(ofSession name: String) -> String {
        guard let (prefix, rest) = Self.prefix(of: name), Self.same(group(ofSession: name), prefix) else { return name }
        return rest
    }

    /// The existing group a prefix names, whatever its case.
    private func group(matching prefix: String) -> String? {
        groups.first { Self.same($0, prefix) }
    }

    /// Group names as prefixes compare them: ignoring case.
    private static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// A drag in the sidebar as List's onMove reports it: `rows[source]`
    /// dropped before `rows[destination]`, or at the end. A group moves with
    /// its sessions, to the first group boundary at or after the drop point.
    mutating func move(_ rows: [Row], from source: Int, to destination: Int) {
        guard rows.indices.contains(source) else { return }
        let target = destination < rows.count ? rows[destination].entry : nil
        switch rows[source] {
        case .session(let session):
            let moved = Entry.session(session.name)
            guard target != moved, let from = entries.firstIndex(of: moved) else { return }
            entries.remove(at: from)
            entries.insert(moved, at: target.flatMap { entries.firstIndex(of: $0) } ?? entries.count)
        case .group(let name):
            guard let block = groupRange(name) else { return }
            let moved = Array(entries[block])
            if let target, moved.contains(target) { return }
            entries.removeSubrange(block)
            var index = target.flatMap { entries.firstIndex(of: $0) } ?? entries.count
            // Sessions after a header belong to its group, and the ungrouped
            // ones come first: a group fits only before a header or at the end.
            while index < entries.count, entries[index].groupName == nil { index += 1 }
            entries.insert(contentsOf: moved, at: index)
        }
    }

    // MARK: Groups

    /// A new, empty group at the end. False if the name is taken.
    @discardableResult
    mutating func addGroup(_ name: String) -> Bool {
        guard !groups.contains(name) else { return false }
        entries.append(.group(name))
        return true
    }

    @discardableResult
    mutating func renameGroup(_ old: String, to new: String) -> Bool {
        guard old != new, !groups.contains(new), let index = entries.firstIndex(of: .group(old)) else { return false }
        entries[index] = .group(new)
        return true
    }

    /// Removes the header; its sessions become ungrouped.
    mutating func removeGroup(_ name: String) {
        guard let block = groupRange(name) else { return }
        let sessions = entries[block].dropFirst()
        entries.removeSubrange(block)
        entries.insert(contentsOf: sessions, at: ungroupedEnd)
    }

    /// Moves a session to the end of a group, or of the ungrouped ones (nil).
    mutating func setGroup(_ group: String?, ofSession name: String) {
        guard group.map({ groups.contains($0) }) ?? true else { return }
        include([name])
        entries.removeAll { $0 == .session(name) }
        let index = group.flatMap({ groupRange($0) })?.upperBound ?? ungroupedEnd
        entries.insert(.session(name), at: index)
    }

    /// The group a session is in; nil when ungrouped.
    public func group(ofSession name: String) -> String? {
        guard let index = entries.firstIndex(of: .session(name)) else { return nil }
        return entries[..<index].last(where: { $0.groupName != nil })?.groupName
    }

    /// A group's header and its sessions.
    private func groupRange(_ name: String) -> Range<Int>? {
        guard let start = entries.firstIndex(of: .group(name)) else { return nil }
        let end = entries[(start + 1)...].firstIndex { $0.groupName != nil } ?? entries.count
        return start..<end
    }

    private var ungroupedEnd: Int {
        entries.firstIndex { $0.groupName != nil } ?? entries.count
    }
}
