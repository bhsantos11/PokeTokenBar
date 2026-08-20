import Foundation

/// Text shown around the desktop companion.
///
/// Pure string building, kept out of the views because both frontends show the same words: the
/// macOS panel's hover callout and the GTK pet's tooltip must not drift into describing the same
/// numbers differently.
enum FloatingPetCopy {
    /// The hover callout: today's usage, plus the highest official limit when one is known.
    ///
    /// `mode` decides whether the limit reads as used or remaining, the same choice the menu bar
    /// honours — a user who set "remaining" should not meet "used" here.
    static func hoverTooltip(
        todayTokens: Int, limitUtilization: Double?, mode: UsageStore.LimitDisplayMode, l: L
    ) -> String {
        let usage = TokenFormatter.grouped(todayTokens)
        guard let utilization = limitUtilization else { return l.floatingPetHoverTokensOnly(usage) }
        let percent = TokenFormatter.percent(UsageStore.displayPercent(utilization, mode: mode))
        return l.floatingPetHoverWithLimit(usage, mode == .remaining ? l.percentRemaining(percent) : percent)
    }

    /// What the companion says when you click it.
    ///
    /// Pure, and **deterministic given `roll`** — the caller supplies the randomness so tests can
    /// pin a line and so the same click cannot produce two different answers on two frontends.
    /// Keyed on display state because a sleeping pet cheering you on is worse than saying nothing.
    static func tapReaction(state: CompanionStateKind, name: String, roll: UInt64, l: L) -> String {
        let lines = l.petReactions(state: state, name: name)
        guard !lines.isEmpty else { return l.petReactionFallback(name) }
        return lines[Int(roll % UInt64(lines.count))]
    }

    /// Title and body for a limit-alert speech bubble.
    static func bubble(_ alert: UsageStore.LimitAlert, l: L) -> (title: String, body: String) {
        (alert.isCritical ? l.notifCritical : l.notifWarning,
         l.notifBody(alert.window, TokenFormatter.percent(alert.utilization)))
    }
}
