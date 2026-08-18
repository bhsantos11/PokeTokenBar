import XCTest
@testable import PokeTokenBar

/// Hover callout and bubble copy for the desktop companion.
///
/// These ran only on macOS while the logic lived on a SwiftUI view; moving it to Core is what lets
/// the GTK pet reuse it, so the contract is pinned here where both platforms compile it.
final class FloatingPetCopyTests: XCTestCase {
    private let l = L(.en)

    func testTokensOnlyWhenNoLimitIsKnown() {
        let text = FloatingPetCopy.hoverTooltip(
            todayTokens: 12_345, limitUtilization: nil, mode: .used, l: l)
        XCTAssertEqual(text, l.floatingPetHoverTokensOnly(TokenFormatter.grouped(12_345)))
    }

    func testUsedModeShowsUtilisationAsGiven() {
        let text = FloatingPetCopy.hoverTooltip(
            todayTokens: 12_345, limitUtilization: 42, mode: .used, l: l)
        XCTAssertTrue(text.contains(TokenFormatter.percent(42)), text)
    }

    /// The whole point of the mode: someone who chose "remaining" must not be shown "used".
    func testRemainingModeInvertsTheNumber() {
        let text = FloatingPetCopy.hoverTooltip(
            todayTokens: 12_345, limitUtilization: 42, mode: .remaining, l: l)
        XCTAssertTrue(text.contains(TokenFormatter.percent(58)), text)
        XCTAssertFalse(text.contains(TokenFormatter.percent(42)), text)
    }

    /// Critical and warning must not collapse to the same title — the bubble's colour is its urgency.
    func testBubbleTitleDistinguishesCritical() {
        let warning = UsageStore.LimitAlert(key: "k", window: "5-hour", isCritical: false, utilization: 82)
        let critical = UsageStore.LimitAlert(key: "k", window: "5-hour", isCritical: true, utilization: 97)
        XCTAssertEqual(FloatingPetCopy.bubble(warning, l: l).title, l.notifWarning)
        XCTAssertEqual(FloatingPetCopy.bubble(critical, l: l).title, l.notifCritical)
        XCTAssertTrue(FloatingPetCopy.bubble(critical, l: l).body.contains("5-hour"))
    }
}
