import XCTest
@testable import PokeTokenBar

// MARK: 한도 캐시 — 재기동을 건너 살아남는 마지막 성공값 (G5)

final class LimitsCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("limits-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func status(fiveHour: Double) throws -> LimitStatus {
        let json = """
        {"five_hour":{"utilization":\(fiveHour),"resets_at":"2026-08-20T03:00:00Z"},
         "seven_day":{"utilization":17.0,"resets_at":"2026-08-25T00:00:00Z"}}
        """
        return try JSONDecoder().decode(LimitStatus.self, from: Data(json.utf8))
    }

    /// 왕복 무손실 — 되살린 값이 화면에 그대로 나와야 한다.
    func testRoundTripPreservesTheWindows() throws {
        let dir = tempDir()
        let cached = CachedLimits(fetchedAt: now, status: try status(fiveHour: 24),
                                  subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        LimitsCache.save(cached, to: dir)

        let loaded = try XCTUnwrap(LimitsCache.load(from: dir, now: now.addingTimeInterval(60)))
        XCTAssertEqual(loaded.restored.fiveHour?.utilization, 24)
        XCTAssertEqual(loaded.restored.sevenDay?.utilization, 17)
        XCTAssertEqual(loaded.fetchedAt, now)
    }

    /// **주입 필드(플랜)는 `LimitStatus.CodingKeys` 에 없어 인코딩에서 빠진다.** 별도로 싣지 않으면
    /// 되살린 카드에서 "Max 20x" 만 조용히 사라진다 — 나머지가 멀쩡해서 눈치채기 어렵다.
    func testSubscriptionFieldsSurviveEvenThoughTheyAreNotCodingKeys() throws {
        let dir = tempDir()
        LimitsCache.save(CachedLimits(fetchedAt: now, status: try status(fiveHour: 10),
                                      subscriptionType: "max", rateLimitTier: "default_claude_max_20x"),
                         to: dir)
        let loaded = try XCTUnwrap(LimitsCache.load(from: dir, now: now))
        XCTAssertEqual(loaded.restored.subscriptionType, "max")
        XCTAssertEqual(loaded.restored.rateLimitTier, "default_claude_max_20x")
    }

    /// 오래된 캐시는 안 쓴다 — 일주일 지난 사용률은 '갱신 지연' 딱지를 달아도 오해를 부른다.
    /// **트리거 브랜치**: 유효기간 직전/직후를 각각 확인한다(하나만 보면 상한이 없어도 통과한다).
    func testStaleCacheIsRefusedButFreshOneIsKept() throws {
        let dir = tempDir()
        LimitsCache.save(CachedLimits(fetchedAt: now, status: try status(fiveHour: 5)), to: dir)
        XCTAssertNotNil(LimitsCache.load(from: dir, now: now.addingTimeInterval(LimitsCache.maxAge - 1)),
                        "유효기간 안이면 써야 한다")
        XCTAssertNil(LimitsCache.load(from: dir, now: now.addingTimeInterval(LimitsCache.maxAge + 1)),
                     "유효기간을 넘으면 버려야 한다")
    }

    /// 시계가 뒤로 간 캐시(미래 시각)도 버린다 — 음수 나이로 영원히 '신선'해지지 않게.
    func testCacheFromTheFutureIsRefused() throws {
        let dir = tempDir()
        LimitsCache.save(CachedLimits(fetchedAt: now, status: try status(fiveHour: 5)), to: dir)
        XCTAssertNil(LimitsCache.load(from: dir, now: now.addingTimeInterval(-60)))
    }

    /// 손상 파일은 없음과 같이 다룬다 — 던지지 않고 조용히 nil(기동을 막으면 안 된다).
    func testCorruptCacheIsTreatedAsAbsent() throws {
        let dir = tempDir()
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(LimitsCache.fileName))
        XCTAssertNil(LimitsCache.load(from: dir, now: now))
    }

    func testMissingCacheIsNil() {
        XCTAssertNil(LimitsCache.load(from: tempDir(), now: now))
    }

    /// [회귀 — Codex 리뷰] 되살린 값은 **표시 전용**이어야 한다.
    ///
    /// 사탕 지급은 엣지 트리거다: 100% 미만을 보면 다음 지급을 위해 재무장한다. 캐시된 과거 값이
    /// 그 파이프라인에 들어가면 이미 지급한 창이 재무장되고, 다음 실제 조회에서 **두 번째 지급**이
    /// 나간다. `limitsReady` 가 되살린 상태를 "준비됨"으로 치면 안 되는 이유다.
    func testRestoredLimitsAreNotTreatedAsReadyForGrants() throws {
        let dir = tempDir()
        LimitsCache.save(CachedLimits(fetchedAt: now, status: try status(fiveHour: 30)), to: dir)
        let cached = try XCTUnwrap(LimitsCache.load(from: dir, now: now))
        // 캐시 자체는 값이 온전하다(화면에는 쓸 수 있다)…
        XCTAssertEqual(cached.restored.fiveHour?.utilization, 30)
        // …하지만 지급/알림 판정은 실제 조회를 기다려야 한다. 그 구분을 UsageStore 가 들고 있다.
        XCTAssertFalse(UsageStore.limitsReady(hasClaudeLimits: true, restored: true, hasCodexLimits: false),
                       "되살린 한도를 준비됨으로 치면 사탕이 두 번 지급된다")
        // 반대 갈래도 확인 — 실제 조회는 당연히 준비됨이고, Codex 한도는 캐시 대상이 아니라 그대로다.
        XCTAssertTrue(UsageStore.limitsReady(hasClaudeLimits: true, restored: false, hasCodexLimits: false))
        XCTAssertTrue(UsageStore.limitsReady(hasClaudeLimits: true, restored: true, hasCodexLimits: true))
        XCTAssertFalse(UsageStore.limitsReady(hasClaudeLimits: false, restored: false, hasCodexLimits: false))
    }

    /// 되살린 값에 붙는 "얼마나 오래됐나" 라벨. `remaining` 을 뒤집어 쓰므로 같은 반올림 규칙을
    /// 따라야 한다 — 두 벌로 두면 한쪽만 고쳐져 갈라진다.
    func testElapsedMirrorsRemainingFormatting() {
        XCTAssertEqual(RelativeTime.elapsed(since: now, now: now.addingTimeInterval(45 * 60)), "45m")
        XCTAssertEqual(RelativeTime.elapsed(since: now, now: now.addingTimeInterval(2 * 3600 + 13 * 60)),
                       "2h 13m")
        XCTAssertEqual(RelativeTime.elapsed(since: now, now: now.addingTimeInterval(30)), "<1m")
        XCTAssertNil(RelativeTime.elapsed(since: now, now: now), "같은 시각은 경과 아님")
        XCTAssertNil(RelativeTime.elapsed(since: now, now: now.addingTimeInterval(-60)),
                     "미래 시각(시계 보정)은 음수 나이 대신 아무것도 안 보여준다")
    }
}
