import Foundation

/// What a `dmucode:` URL asks for, for the `dmucode` command and for other
/// programs (Raycast, scripts, sesh hooks):
///
///   dmucode://session/<name>            show the session
///   dmucode://new/<name>?dir=<path>     create the session in that directory
///                                       and show it; shown if it exists
///   dmucode://new?dir=<path>            create a session named by tmux
///
/// The name is the URL's path, so `group/name` needs no encoding; spaces and
/// the rest are percent-encoded as usual. Without `dir`, the home directory.
public enum AppURL: Equatable {
    case show(name: String)
    case new(name: String?, directory: String?)

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "dmucode",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `path` is percent-decoded. A trailing slash isn't part of a name.
        var name = Substring(components.path).drop(while: { $0 == "/" })
        while name.last == "/" { name = name.dropLast() }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        switch components.host?.lowercased() {
        case "session":
            guard !name.isEmpty else { return nil }
            self = .show(name: String(name))
        case "new":
            let directory = query["dir"].flatMap { $0.isEmpty ? nil : $0 }
            self = .new(name: name.isEmpty ? nil : String(name), directory: directory)
        default:
            return nil
        }
    }
}
