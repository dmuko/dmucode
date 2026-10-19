import Testing
@testable import dmucode

struct GitStatusTests {
    @Test func branchWithChangesConflictsAndUpstream() {
        let output = """
            # branch.oid 1234567890abcdef1234567890abcdef12345678
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +2 -1
            1 .M N... 100644 100644 100644 abc abc Sources/a.swift
            2 R. N... 100644 100644 100644 abc abc R100 new.swift\told.swift
            u UU N... 100644 100644 100644 100644 a b c conflict.swift
            ? untracked.txt
            ? other.txt
            """
        let status = GitStatus.parse(output)
        #expect(status == GitStatus(branch: "main", changed: 2, untracked: 2, conflicted: 1, ahead: 2, behind: 1))
        #expect(status?.isDirty == true)
    }

    @Test func cleanWithoutUpstream() {
        let status = GitStatus.parse("# branch.oid 1234567890abcdef\n# branch.head feature/x\n")
        #expect(status == GitStatus(branch: "feature/x", changed: 0, untracked: 0, conflicted: 0, ahead: 0, behind: 0))
        #expect(status?.isDirty == false)
    }

    @Test func detachedHeadShowsShortCommit() {
        let status = GitStatus.parse("# branch.oid 1234567890abcdef\n# branch.head (detached)\n")
        #expect(status?.branch == "1234567")
    }

    @Test func initialCommit() {
        let status = GitStatus.parse("# branch.oid (initial)\n# branch.head main\n? new.txt\n")
        #expect(status == GitStatus(branch: "main", changed: 0, untracked: 1, conflicted: 0, ahead: 0, behind: 0))
    }

    @Test func notARepository() {
        #expect(GitStatus.parse("") == nil)
        #expect(GitStatus.parse("fatal: not a git repository (or any of the parent directories): .git\n") == nil)
    }
}
