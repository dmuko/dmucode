/// Fuzzy matching for the ⌘K switcher: the query's characters must appear
/// in the candidate in order, ignoring case. Matches at word starts and in
/// runs score higher and gaps cost a little, so "dc" ranks "dmu-code" above
/// "dmucode" and "code" ranks "~/Code/x" above "~/dmucode".
enum FuzzyMatch {
    struct Match: Equatable {
        let score: Int
        /// Positions of the matched characters in the candidate.
        let indices: [Int]
    }

    private static let matchScore = 16
    private static let wordStartBonus = 24
    private static let firstCharacterBonus = 8
    private static let runBonus = 20
    private static let gapPenalty = 1
    private static let none = Int.min / 2

    static func match(_ query: String, in candidate: String) -> Match? {
        let q = query.map { $0.lowercased() }
        let original = Array(candidate)
        let c = original.map { $0.lowercased() }
        guard !q.isEmpty else { return Match(score: 0, indices: []) }
        guard q.count <= c.count else { return nil }

        func bonus(_ j: Int) -> Int {
            var score = matchScore
            if j == 0 {
                score += wordStartBonus + firstCharacterBonus
            } else if " -_/.:~".contains(original[j - 1]) || (original[j - 1].isLowercase && original[j].isUppercase) {
                score += wordStartBonus
            }
            return score
        }

        // best[j]: the best score with the current query character at j.
        // back[i][j]: where query character i - 1 was then.
        var best = [Int](repeating: none, count: c.count)
        var back = [[Int]](repeating: [Int](repeating: -1, count: c.count), count: q.count)
        for i in q.indices {
            var row = [Int](repeating: none, count: c.count)
            // Max of best[k] + k * gapPenalty over k <= j - 2: with a linear
            // gap penalty, the best non-adjacent predecessor in one pass.
            var gapMax = none, gapArg = -1
            for j in c.indices {
                if i > 0, j >= 2, best[j - 2] != none, best[j - 2] + (j - 2) * gapPenalty > gapMax {
                    gapMax = best[j - 2] + (j - 2) * gapPenalty
                    gapArg = j - 2
                }
                guard c[j] == q[i] else { continue }
                if i == 0 {
                    row[j] = bonus(j)
                    continue
                }
                var score = none, from = -1
                if j >= 1, best[j - 1] != none {
                    score = best[j - 1] + runBonus
                    from = j - 1
                }
                if gapArg >= 0, gapMax - (j - 1) * gapPenalty > score {
                    score = gapMax - (j - 1) * gapPenalty
                    from = gapArg
                }
                guard from >= 0 else { continue }
                row[j] = score + bonus(j)
                back[i][j] = from
            }
            best = row
        }

        guard let end = best.indices.max(by: { best[$0] < best[$1] }), best[end] != none else { return nil }
        var indices = [end]
        for i in stride(from: q.count - 1, to: 0, by: -1) {
            indices.append(back[i][indices.last!])
        }
        return Match(score: best[end], indices: indices.reversed())
    }
}
