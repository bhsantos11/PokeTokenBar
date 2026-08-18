import XCTest
@testable import PokeTokenBar

/// Countdown text for limit resets.
///
/// Exists because corelibs-foundation has no `RelativeDateTimeFormatter`, so this arithmetic is
/// ours rather than the system's — which makes the boundaries (just-passed, under a minute, exact
/// hour, multi-day) ours to get wrong.
final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func remaining(_ seconds: TimeInterval) -> String? {
        RelativeTime.remaining(until: now.addingTimeInterval(seconds), now: now)
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(remaining(2 * 3600 + 13 * 60), "2h 13m")
    }

    func testMinutesOnlyUnderAnHour() {
        XCTAssertEqual(remaining(45 * 60), "45m")
    }

    /// An exact hour should not read "2h 0m".
    func testExactHourOmitsZeroMinutes() {
        XCTAssertEqual(remaining(2 * 3600), "2h")
    }

    /// Weekly windows are the reason days exist; minutes would be noise at that range.
    func testMultiDayUsesDaysAndHours() {
        XCTAssertEqual(remaining(3 * 86_400 + 5 * 3600), "3d 5h")
    }

    /// Still in the future, so it must not round down to "0m" and read as "now".
    func testUnderOneMinuteIsNotZero() {
        XCTAssertEqual(remaining(30), "<1m")
    }

    /// Past deadlines return nil so the row hides the countdown instead of showing a negative.
    func testPastReturnsNil() {
        XCTAssertNil(remaining(-1))
        XCTAssertNil(remaining(0))
    }
}
