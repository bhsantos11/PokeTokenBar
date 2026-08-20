import XCTest
@testable import PokeTokenBar

// MARK: 하루 리듬 — 5시간 활성 블록 안의 위치

final class CircadianTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 시작 시각이 `startedMinutesAgo` 분 전인 블록.
    private func block(startedMinutesAgo: Double) -> BlockUsage {
        let iso = ISO8601DateFormatter()
        let start = now.addingTimeInterval(-startedMinutesAgo * 60)
        return BlockUsage(id: "b", startTime: iso.string(from: start),
                          endTime: iso.string(from: start.addingTimeInterval(Circadian.windowSeconds)),
                          isActive: true, totalTokens: 1, costUSD: 0, tokensPerMinute: 1)
    }

    /// 블록이 없으면 5시간 넘게 조용했다는 뜻 = 잔다.
    func testNoBlockMeansAsleep() {
        XCTAssertEqual(Circadian.phase(block: nil, now: now), .asleep)
        XCTAssertNil(Circadian.progress(block: nil, now: now))
    }

    /// 창 전체를 훑어 경계마다 단계가 바뀌는지 본다. 한 지점만 보면 경계 오프바이원을 못 잡는다.
    func testPhaseAdvancesThroughTheWindow() {
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 0), now: now), .fresh)
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 99), now: now), .fresh)
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 101), now: now), .steady,
                       "1/3(100분) 을 넘으면 steady")
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 239), now: now), .steady)
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 241), now: now), .winding,
                       "80%(240분) 를 넘으면 winding")
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 299), now: now), .winding)
    }

    /// **끝을 넘긴 블록은 winding 이 아니라 asleep 이다.** 1 로 뭉개면 새로고침 사이에 잠깐 stale 해진
    /// 블록이 영원히 "지쳐 있음"으로 굳는다 — 자리를 비웠는데 계속 피곤한 펫이 된다.
    func testExpiredBlockIsAsleepNotPermanentlyTired() {
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 300), now: now), .asleep,
                       "정확히 창 끝")
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: 600), now: now), .asleep,
                       "한참 지난 블록")
        XCTAssertNil(Circadian.progress(block: block(startedMinutesAgo: 400), now: now))
    }

    /// 시계가 뒤로 간 경우(시간대 변경·NTP 보정) 미래의 블록 → 음수 진행도를 만들면 안 된다.
    func testFutureBlockIsNotTreatedAsProgress() {
        XCTAssertEqual(Circadian.phase(block: block(startedMinutesAgo: -30), now: now), .asleep)
        XCTAssertNil(Circadian.progress(block: block(startedMinutesAgo: -30), now: now))
    }

    /// 파싱 불가한 시작 시각은 블록 없음과 같이 다룬다(추측해서 리듬을 만들지 않는다).
    func testUnparseableStartIsAsleep() {
        let broken = BlockUsage(id: "b", startTime: "not-a-date", endTime: "also-not",
                                isActive: true, totalTokens: 1, costUSD: 0, tokensPerMinute: 1)
        XCTAssertEqual(Circadian.phase(block: broken, now: now), .asleep)
    }

    /// 창 길이는 블록을 만드는 쪽(`LocalUsageReader.blockWindow`)과 같아야 한다. 갈라지면 진행도가
    /// 100% 를 넘거나 영영 winding 에 도달하지 못한다.
    func testWindowMatchesTheReadersBlockLength() {
        XCTAssertEqual(Circadian.windowSeconds, 5 * 60 * 60)
    }
}
