import Foundation

/// How long until a limit window resets, as compact text.
///
/// SwiftUI gives macOS `Text(date, style: .relative)` for free, and corelibs-foundation has no
/// `RelativeDateTimeFormatter` at all, so the Linux popover needs its own. Keeping the arithmetic
/// here rather than in the GTK layer makes it testable, and the output deliberately uses digits and
/// unit letters rather than a sentence — a limit row has a few characters of space, and "2h 13m"
/// reads the same in every language this app ships.
enum RelativeTime {
    /// Compact time remaining: `2h 13m`, `45m`, `<1m`. Returns nil once the moment has passed,
    /// so callers show nothing rather than a negative or a stale "0m".
    static func remaining(until deadline: Date, now: Date = Date()) -> String? {
        let seconds = deadline.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let totalMinutes = Int(seconds / 60)
        // Under a minute still means "not yet", and rounding it to 0m would read as "now".
        guard totalMinutes >= 1 else { return "<1m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        // Past a day the minutes are noise; weekly windows are the case that matters here.
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// Clock time for the burn-rate forecast ("limit hit at 14:32"), in the app's language.
    static func clockTime(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
