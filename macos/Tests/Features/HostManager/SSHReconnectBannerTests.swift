import Foundation
import Testing
@testable import Ghostty

@Suite
struct SSHReconnectBannerTests {
    private let dropped = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func namesTheHostTheDropTimeAndTheAttempt() {
        let lines = SSHReconnectBanner.lines(
            target: "deploy@10.0.1.10:2222",
            droppedAt: dropped,
            now: dropped.addingTimeInterval(161),
            attempt: 2
        )

        #expect(lines.count == 2)
        #expect(lines[0].contains("deploy@10.0.1.10:2222"))
        #expect(lines[0].contains(SSHReconnectBanner.clockTime(dropped)))
        #expect(lines[0].contains("2m 41s ago"))
        #expect(lines[1].contains("(attempt 2)"))
        // The whole point of the banner: say the shell is a new one.
        #expect(lines[1].contains("NEW shell"))
    }

    /// A reconnect the user clicked has no attempt counter to report.
    @Test func omitsTheAttemptForAManualReconnect() {
        let lines = SSHReconnectBanner.lines(target: "host:22", droppedAt: dropped,
                                             now: dropped, attempt: 0)
        #expect(!lines[1].contains("attempt"))
    }

    @Test func fallsBackWhenThereIsNoTarget() {
        let lines = SSHReconnectBanner.lines(target: "", droppedAt: dropped,
                                             now: dropped, attempt: 1)
        #expect(lines[0].contains("the server"))
    }

    @Test func elapsedReadsAsSecondsMinutesThenHours() {
        #expect(SSHReconnectBanner.elapsed(from: dropped, to: dropped) == "0s")
        #expect(SSHReconnectBanner.elapsed(from: dropped, to: dropped.addingTimeInterval(8)) == "8s")
        #expect(SSHReconnectBanner.elapsed(from: dropped, to: dropped.addingTimeInterval(161)) == "2m 41s")
        #expect(SSHReconnectBanner.elapsed(from: dropped, to: dropped.addingTimeInterval(4020)) == "1h 07m")
        // A clock that jumped backwards must not print a negative age.
        #expect(SSHReconnectBanner.elapsed(from: dropped, to: dropped.addingTimeInterval(-30)) == "0s")
    }

    @Test func printfPassesTextAsArgumentsSoItIsNeverAFormatString() {
        let command = SSHReconnectBanner.printfCommand(["100% done", "a 'quoted' word"])

        // One %s conversion that printf cycles over both arguments — a literal
        // "%" in the text must not become a directive, and a quote must not end
        // the argument.
        #expect(command.hasPrefix("printf '\\033[2m%s\\033[0m\\r\\n' "))
        #expect(command.contains("'100% done'"))
        #expect(command.contains("'a '\\''quoted'\\'' word'"))
    }

    @Test func printfIsEmptyWithoutLinesSoTheLaunchStaysUnwrapped() {
        #expect(SSHReconnectBanner.printfCommand([]).isEmpty)
    }
}
