import Foundation
import Testing
@testable import dmucodeCore

struct ControlModeParserTests {
    /// Feeds the chunks in order, as separate reads from the pipe.
    private func parse(_ chunks: [Data]) -> [ControlModeParser.Event] {
        var parser = ControlModeParser()
        return chunks.flatMap { parser.consume($0) }
    }

    private func parse(_ chunks: String...) -> [ControlModeParser.Event] {
        parse(chunks.map { Data($0.utf8) })
    }

    @Test func replyToOurCommand() {
        #expect(parse("%begin 1760000000 12 1\n$0 main\n$1 work\n%end 1760000000 12 1\n")
                == [.reply(.success(["$0 main", "$1 work"]))])
    }

    @Test func emptyReply() {
        #expect(parse("%begin 1 5 1\n%end 1 5 1\n") == [.reply(.success([]))])
    }

    @Test func errorReply() {
        #expect(parse("%begin 1 5 1\nunknown command: foo\nsecond line\n%error 1 5 1\n")
                == [.reply(.failure(TmuxError(description: "unknown command: foo\nsecond line")))])
    }

    @Test func blockOfAnotherCommandIsSkipped() {
        // flags 0: e.g. the attach-session given on tmux's command line.
        #expect(parse("%begin 1 3 0\nwhatever\n%end 1 3 0\n%sessions-changed\n")
                == [.notification(name: "%sessions-changed", args: [])])
    }

    @Test func outputThatLooksLikeProtocolStaysInTheReply() {
        // Only a guard line with the block's own number ends it.
        #expect(parse("%begin 1 7 1\n%sessions-changed\n%end 1 6 1\n%end 1 7 1\n")
                == [.reply(.success(["%sessions-changed", "%end 1 6 1"]))])
    }

    @Test func notificationArguments() {
        #expect(parse("%session-renamed $1 my session\n%window-add @4\n%client-session-changed /dev/ttys003 $2 work\n") == [
            .notification(name: "%session-renamed", args: ["$1", "my", "session"]),
            .notification(name: "%window-add", args: ["@4"]),
            .notification(name: "%client-session-changed", args: ["/dev/ttys003", "$2", "work"]),
        ])
    }

    @Test func repliesAndNotificationsInOrder() {
        #expect(parse("%begin 1 1 1\na\n%end 1 1 1\n%sessions-changed\n%begin 1 2 1\nb\n%end 1 2 1\n") == [
            .reply(.success(["a"])),
            .notification(name: "%sessions-changed", args: []),
            .reply(.success(["b"])),
        ])
    }

    @Test func linesSplitAcrossReads() {
        #expect(parse("%begin 1 9 1\nfir", "st\n%en", "d 1 9 1\n%client-detached /dev/ttys0", "03\n") == [
            .reply(.success(["first"])),
            .notification(name: "%client-detached", args: ["/dev/ttys003"]),
        ])
    }

    @Test func characterSplitAcrossReads() {
        let bytes = Data("%begin 1 4 1\n~/Työt\n%end 1 4 1\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1 // inside "ö"
        #expect(parse([bytes[..<split], bytes[split...]]) == [.reply(.success(["~/Työt"]))])
    }

    @Test func incompleteLineWaits() {
        #expect(parse("%sessions-changed") == [])
    }

    @Test func paneOutputAndOtherLinesAreIgnored() {
        #expect(parse("%output %1 hello\n%extended-output %1 0 : hi\nnot a notification\n\n") == [])
    }
}
