import Foundation

/// The banner printed at the top of the terminal that REPLACES a dropped SSH
/// session.
///
/// Auto-reconnect swaps a brand-new surface into the pane (see
/// `VaultsTabsModel.launchSSHConnection`), which throws the old scrollback away
/// — including ssh's own "Connection to <host> closed." Without this banner a
/// drop-and-recover is indistinguishable from an untouched session: the user
/// comes back to a working prompt on the right host and the only visible
/// symptom is that whatever the old session was running (redis-cli, an editor,
/// `tail -f`) is silently gone, which reads as "the tool died, not my SSH".
///
/// Pure string building — no I/O, no state — so both halves are unit testable.
enum SSHReconnectBanner {
    /// Banner lines for a session that dropped at `droppedAt` and is being
    /// relaunched at `now`. `attempt` is the automatic-retry counter; 0 means a
    /// reconnect the user asked for, which gets no attempt suffix.
    static func lines(target: String, droppedAt: Date, now: Date, attempt: Int) -> [String] {
        let who = target.isEmpty ? "the server" : target
        let tries = attempt > 0 ? " (attempt \(attempt))" : ""
        return [
            "-- SarvTerminal: the session to \(who) ended at \(clockTime(droppedAt)), "
                + "\(elapsed(from: droppedAt, to: now)) ago --",
            "-- Reconnecting now\(tries). This is a NEW shell: anything the old session "
                + "was running ended with it. --",
        ]
    }

    /// A `printf` command that writes `lines` dimmed, one per line. The text is
    /// passed as ARGUMENTS (a single `%s` conversion that printf cycles), never
    /// spliced into the format string, so a host label containing `%` or a
    /// backslash can't be interpreted as a directive.
    static func printfCommand(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let args = lines.map(shellQuote).joined(separator: " ")
        return "printf '\\033[2m%s\\033[0m\\r\\n' \(args)"
    }

    // MARK: - Formatting

    /// "8s", "2m 41s", "1h 07m".
    static func elapsed(from: Date, to: Date) -> String {
        let seconds = max(0, Int(to.timeIntervalSince(from).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// Wall-clock "14:32:07". POSIX locale so the fixed format can't be bent
    /// into a 12-hour clock by the user's region settings.
    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
