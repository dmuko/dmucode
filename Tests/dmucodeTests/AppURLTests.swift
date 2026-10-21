import Foundation
import Testing
@testable import dmucodeCore

struct AppURLTests {
    private func parse(_ string: String) -> AppURL? {
        URL(string: string).flatMap(AppURL.init)
    }

    @Test func showsASessionByItsPath() {
        #expect(parse("dmucode://session/work") == .show(name: "work"))
        // A group's slash is part of the name; a trailing one isn't.
        #expect(parse("dmucode://session/agents/claude-1/") == .show(name: "agents/claude-1"))
        #expect(parse("dmucode://session/my%20project") == .show(name: "my project"))
        #expect(parse("DMUCODE://Session/x") == .show(name: "x"))
        #expect(parse("dmucode://session") == nil)
        #expect(parse("dmucode://session/") == nil)
    }

    @Test func createsASession() {
        #expect(parse("dmucode://new/work?dir=%2FUsers%2Fme%2Fsrc") == .new(name: "work", directory: "/Users/me/src"))
        #expect(parse("dmucode://new/agents/x") == .new(name: "agents/x", directory: nil))
        #expect(parse("dmucode://new?dir=/tmp") == .new(name: nil, directory: "/tmp"))
        #expect(parse("dmucode://new/?dir=") == .new(name: nil, directory: nil))
    }

    @Test func otherURLsAreRejected() {
        #expect(parse("dmucode://palette") == nil)
        #expect(parse("dmucode://") == nil)
        #expect(parse("https://session/x") == nil)
    }
}
