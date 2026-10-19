import Foundation

/// The bundle id changed from dev.dmucode.app to com.dmuko.dmucode, and the
/// settings (sidebar order and groups, command history, window frame...)
/// live in a domain named after it.
enum DefaultsMigration {
    static let oldDomain = "dev.dmucode.app"

    /// Copies the old domain's settings into `domain` while it has none of
    /// its own, so this happens once. The old domain is left as it was.
    @discardableResult
    static func run(from oldDomain: String = oldDomain, into domain: String,
                    defaults: UserDefaults = .standard) -> Bool {
        guard !domain.isEmpty, domain != oldDomain,
              defaults.persistentDomain(forName: domain)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return false }
        defaults.setPersistentDomain(old, forName: domain)
        return true
    }
}
