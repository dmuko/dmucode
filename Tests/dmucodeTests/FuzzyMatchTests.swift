import Testing
@testable import dmucode

struct FuzzyMatchTests {
    private func score(_ query: String, _ candidate: String) -> Int? {
        FuzzyMatch.match(query, in: candidate)?.score
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.match("", in: "anything") == FuzzyMatch.Match(score: 0, indices: []))
    }

    @Test func charactersMustAppearInOrder() {
        #expect(FuzzyMatch.match("ba", in: "abc") == nil)
        #expect(FuzzyMatch.match("abcd", in: "abc") == nil)
        #expect(FuzzyMatch.match("x", in: "") == nil)
    }

    @Test func ignoresCase() {
        #expect(FuzzyMatch.match("CFG", in: "config")?.indices == [0, 3, 5])
        #expect(FuzzyMatch.match("work", in: "Work")?.indices == [0, 1, 2, 3])
    }

    @Test func wordStartsRankHigher() {
        #expect(score("dc", "dmu-code")! > score("dc", "dmucode")!)
        #expect(score("code", "~/Code/x")! > score("code", "~/dmucode")!)
        // camelCase counts as a word start.
        #expect(score("sv", "SidebarView")! > score("sv", "Sidebarview")!)
    }

    @Test func runsRankHigher() {
        #expect(score("abc", "abcxyz")! > score("abc", "axbxcx")!)
    }

    @Test func picksTheBestAlignment() {
        // The first "a" would leave a long gap; the one at a word start
        // followed by "b" scores higher.
        #expect(FuzzyMatch.match("ab", in: "axxx_ab")?.indices == [5, 6])
    }

    @Test func nonASCII() {
        #expect(FuzzyMatch.match("työ", in: "~/Työt")?.indices == [2, 3, 4])
    }
}
