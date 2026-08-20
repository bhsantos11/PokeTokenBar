import XCTest
@testable import PokeTokenBar

// companion 표시 상태(displayState) 전이 — update() 입력 조합에 따른 결과 검증.
// SeededRNG / StubProvider 는 CompanionTests.swift 의 내부 헬퍼를 재사용한다.

private func dnode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
private func dline(base: Int, rarity: Rarity = .common) -> EvoLine {
    EvoLine(baseID: base, tree: dnode(base, [dnode(base + 1, [dnode(base + 2)])]),
            rarity: rarity, names: [:])
}
private let dNow = Date(timeIntervalSince1970: 1_700_000_000)

/// 테스트에서 시계를 전진시키기 위한 가변 박스 (이벤트 윈도우 만료 제어용).
private final class ClockBox: @unchecked Sendable {
    nonisolated(unsafe) var now: Date
    init(_ d: Date) { now = d }
}

@MainActor
final class CompanionDisplayStateTests: XCTestCase {
    private func hatchedStore(rarity: Rarity = .common) async -> (CompanionStore, ClockBox) {
        let clock = ClockBox(dNow)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-disp-\(UUID().uuidString).json")
        let s = CompanionStore(provider: StubProvider(value: dline(base: 1, rarity: rarity)),
                               clock: { clock.now }, fileURL: url, rng: SeededRNG(seed: 5))
        await s.hatch(baseID: 1)
        return (s, clock)
    }

    func testEggWhenNoUsageData() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-disp-\(UUID().uuidString).json")
        let s = CompanionStore(provider: StubProvider(value: dline(base: 1)),
                               clock: { dNow }, fileURL: url, rng: SeededRNG(seed: 1))
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: false)
        XCTAssertEqual(s.displayState, .egg)
    }

    // MARK: 하루 리듬 (G2) — 로컬 블록 위치가 표시 상태에 미치는 영향

    /// [핵심] **한도 경고 없이도** `.tired` 에 도달해야 한다.
    ///
    /// `isLimitWarning` 은 한도 API 만 읽는데 그 엔드포인트는 429 로 자주 죽는다 → 그동안 `.tired` 는
    /// 도달 불가능한 죽은 상태였다. 로컬 블록 후반이면 지치는 것이 그 구멍을 메운다.
    /// 트리거 브랜치는 **limitWarning=false + winding** 조합이다(둘 다 참인 케이스만 보면 못 잡는다).
    func testWindingBlockMakesTheCompanionTiredWithoutAnyLimitWarning() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(10)   // 부화 연출(.levelUp) 창 만료
        s.update(todayTokensByProvider: ["test": 1_000], todayDate: "d", monthTotal: 0,
                 burnTier: .normal, limitWarning: false, hasUsageData: true, circadian: .winding)
        XCTAssertEqual(s.displayState, .tired, "작업 구간 후반이면 한도와 무관하게 지쳐야 한다")
    }

    /// 5시간 넘게 조용하면 잔다 — 오늘 토큰을 썼더라도. 날짜 기준만 쓰면 아침에 쓴 사용량 때문에
    /// 저녁 내내 자리를 비워도 "일하는 중"으로 남는다.
    func testAsleepPhaseSleepsEvenWithUsageEarlierToday() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(10)
        s.update(todayTokensByProvider: ["test": 1_000], todayDate: "d", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true, circadian: .asleep)
        XCTAssertEqual(s.displayState, .sleep)
    }

    /// [회귀 — Codex 리뷰] **자정을 건너는 작업 구간에서 자면 안 된다.**
    ///
    /// 오늘 토큰이 아직 0이어도(00:05) 블록이 살아 있으면 사람은 일하는 중이다. 날짜 기준을 함께
    /// 두면 리듬이 없애려던 바로 그 달력 경계 문제가 그대로 남는다.
    /// 트리거 브랜치: **today == 0 + 활성 블록**(둘 중 하나만 보면 못 잡는다).
    func testMidnightWithALiveBlockDoesNotSleep() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(10)
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d", monthTotal: 0,
                 burnTier: .normal, limitWarning: false, hasUsageData: true, circadian: .steady)
        XCTAssertEqual(s.displayState, .working, "블록이 살아 있으면 자정 직후여도 일하는 중이다")
    }

    /// 리듬을 안 넘기는 호출부(nil = macOS)는 종전 날짜 기준 그대로여야 한다.
    func testCallersWithoutCircadianKeepTheCalendarRule() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(10)
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d", monthTotal: 0,
                 burnTier: .normal, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.displayState, .sleep, "리듬 없는 호출부는 today == 0 이면 종전대로 잔다")
    }

    /// 중립값(.steady)에서는 기존 동작이 그대로여야 한다 — 기본 인자를 쓰는 호출부(macOS)가
    /// 리듬 기능만 빠진 채 종전대로 도는지 확인한다.
    func testSteadyPhaseLeavesTheExistingBehaviourUnchanged() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(10)
        s.update(todayTokensByProvider: ["test": 1_000], todayDate: "d", monthTotal: 0,
                 burnTier: .normal, limitWarning: false, hasUsageData: true, circadian: .steady)
        XCTAssertEqual(s.displayState, .working)
        // 인자를 아예 안 넘긴 호출(nil)도 오늘 사용량이 있으면 같은 결과여야 한다.
        s.update(todayTokensByProvider: ["test": 2_000], todayDate: "d", monthTotal: 0,
                 burnTier: .normal, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.displayState, .working)
    }

    /// 한도 경고는 여전히 우선한다 — 블록 초반이어도 한도가 위험하면 지친 상태다.
    func testLimitWarningStillWinsOverAFreshBlock() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(10)
        s.update(todayTokensByProvider: ["test": 1_000], todayDate: "d", monthTotal: 0,
                 burnTier: .normal, limitWarning: true, hasUsageData: true, circadian: .fresh)
        XCTAssertEqual(s.displayState, .tired)
    }

    func testLevelUpDuringEventWindow() async {
        let (s, _) = await hatchedStore()
        // 이벤트 윈도우가 살아있는 동안(시계 미전진) → levelUp 유지
        s.update(todayTokensByProvider: ["test": 100], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.displayState, .levelUp)
    }

    func testWorkingAfterEventExpires() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(60)   // 이벤트 만료
        s.update(todayTokensByProvider: ["test": 100], todayDate: "d", monthTotal: 0, burnTier: .normal, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.displayState, .working)
    }

    func testFocusOnHighBurn() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(60)
        s.update(todayTokensByProvider: ["test": 100], todayDate: "d", monthTotal: 0, burnTier: .blazing, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.displayState, .focus)
    }

    func testTiredWhenLimitWarning() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(60)
        s.update(todayTokensByProvider: ["test": 100], todayDate: "d", monthTotal: 0, burnTier: .normal, limitWarning: true, hasUsageData: true)
        XCTAssertEqual(s.displayState, .tired)
    }

    func testSleepWhenZeroUsageToday() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(60)
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.displayState, .sleep)
    }

    /// 회귀(#4): 진화 문구(justEvolvedTo)는 진화가 연 .levelUp 창 **전체** 동안 유지돼야 한다.
    /// 과거엔 update() 초입에서 매 틱 무조건 nil 로 밀어, 창 도중 틱이 끼면 표시가
    /// "…(으)로 진화했어요"→"성장했어요"(statusEvolved→statusGrew)로 되돌아갔다.
    func testEvolveStatusSurvivesUpdateWithinEventWindow() async {
        let (s, clock) = await hatchedStore()
        clock.now = dNow.addingTimeInterval(60)   // 부화 창 만료 — 이후엔 진화 이벤트만 남게
        // 기준선 설정(첫 update 는 baseline 만 잡고 delta 는 적용 안 함).
        s.update(todayTokensByProvider: ["test": 100], todayDate: "d", monthTotal: 0, burnTier: .normal, limitWarning: false, hasUsageData: true)
        // stage0 임계 도달 → 정확히 1회 진화(1→2). justEvolvedTo 설정 + 이벤트 창 갱신(clock+4).
        s.applyUsage(PokemonBalance.phaseThreshold(rarity: .common, totalForms: 3, stageIndex: 0))
        XCTAssertEqual(s.state.active?.stageIndex, 1)
        let evolvedName = s.justEvolvedTo
        XCTAssertNotNil(evolvedName, "진화 직후 진화 문구가 설정돼야 함")
        // 창이 살아있는 동안 추가 update()(delta 0)가 와도 진화 문구·levelUp 이 유지돼야 한다.
        s.update(todayTokensByProvider: ["test": 100], todayDate: "d", monthTotal: 0, burnTier: .normal, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.justEvolvedTo, evolvedName, "이벤트 창 도중 진화 문구가 nil 로 밀리면 안 됨(#4)")
        XCTAssertEqual(s.displayState, .levelUp)
        // 창 만료 후 update → 진화 문구 정리 + 일반 상태 복귀.
        clock.now = dNow.addingTimeInterval(70)
        s.update(todayTokensByProvider: ["test": 100], todayDate: "d", monthTotal: 0, burnTier: .normal, limitWarning: false, hasUsageData: true)
        XCTAssertNil(s.justEvolvedTo, "창 만료 시 진화 문구가 정리돼야 함")
        XCTAssertEqual(s.displayState, .working)
    }

    // MARK: 알(egg) 인큐베이션 파생값

    func testEggProgressAndTokensToHatch() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-disp-\(UUID().uuidString).json")
        let s = CompanionStore(provider: StubProvider(value: dline(base: 1)),
                               clock: { dNow }, fileURL: url, rng: SeededRNG(seed: 1))
        XCTAssertTrue(s.isEgg)
        XCTAssertEqual(s.eggProgress, 0)
        XCTAssertEqual(s.eggTokensToHatch, PokemonBalance.eggHatchThreshold)

        // 임계의 40% 사용
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: true)
        let part = PokemonBalance.eggHatchThreshold * 2 / 5
        s.update(todayTokensByProvider: ["test": part], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.eggProgress, 0.4, accuracy: 0.001)
        XCTAssertEqual(s.eggTokensToHatch, PokemonBalance.eggHatchThreshold - part)
        XCTAssertTrue(s.eggStarted)
    }
}
