import XCTest
@testable import PokeTokenBar

// MARK: 성격이 성장 속도를 바꾼다 (G3)

final class NatureGrowthTests: XCTestCase {

    /// 매핑은 본가 스피드 보정을 따른다 — 지어낸 규칙이 아니라 팬이 아는 표여야 납득된다.
    func testMultiplierFollowsTheMainSeriesSpeedNatures() {
        for fast in [PokemonNature.timid, .hasty, .jolly, .naive] {
            XCTAssertEqual(fast.growthMultiplier, 1.1, "본가 +스피드 성격은 빨리 자라야 한다: \(fast)")
        }
        for slow in [PokemonNature.brave, .relaxed, .quiet, .sassy] {
            XCTAssertEqual(slow.growthMultiplier, 0.9, "본가 −스피드 성격은 느리게 자라야 한다: \(slow)")
        }
        let touched = Set<PokemonNature>([.timid, .hasty, .jolly, .naive, .brave, .relaxed, .quiet, .sassy])
        for neutral in PokemonNature.allCases where !touched.contains(neutral) {
            XCTAssertEqual(neutral.growthMultiplier, 1.0, "스피드를 안 건드리는 성격은 정확히 1.0: \(neutral)")
        }
        XCTAssertEqual(PokemonNature.allCases.count, 25)
    }

    /// 구버전 세이브의 성격 없는 개체는 **정확히 중립**이어야 한다.
    /// nil 을 0 배로 다루면 성장이 영영 멈춘다 — 조용해서 알아채기까지 오래 걸리는 종류의 결함이다.
    func testNilNatureIsExactlyNeutral() {
        XCTAssertEqual(CompanionStore.grownAmount(1_000, nature: nil), 1_000)
        XCTAssertEqual(CompanionStore.grownAmount(1, nature: nil), 1)
        XCTAssertEqual(CompanionStore.grownAmount(0, nature: nil), 0)
    }

    func testFastAndSlowScaleInBothDirections() {
        XCTAssertEqual(CompanionStore.grownAmount(1_000, nature: .jolly), 1_100)
        XCTAssertEqual(CompanionStore.grownAmount(1_000, nature: .brave), 900)
        XCTAssertEqual(CompanionStore.grownAmount(1_000, nature: .hardy), 1_000)
    }

    /// **작은 델타에서 느린 성격이 0 이 되면 안 된다.** 실사용은 1~수천 토큰씩 자주 들어오므로,
    /// 버림을 쓰면 0.9 배가 매번 0 이 되어 그 개체가 영영 안 자란다. 최소 1 을 보장한다.
    func testSlowNatureStillGrowsOnTinyDeltas() {
        XCTAssertGreaterThanOrEqual(CompanionStore.grownAmount(1, nature: .brave), 1)
        XCTAssertGreaterThanOrEqual(CompanionStore.grownAmount(3, nature: .relaxed), 1)
        for delta in 1...20 {
            XCTAssertGreaterThan(CompanionStore.grownAmount(delta, nature: .quiet), 0,
                                 "delta=\(delta) 에서 성장이 멈췄다")
        }
    }

    /// 가장 느린 성격이어도 졸업은 도달 가능해야 한다 — 배율이 균형표를 깨지 않는지 확인한다.
    /// (3B / 0.9 = 3.33B — 도달 가능. 배율을 더 낮추면 이 테스트가 먼저 경고한다.)
    func testSlowestNatureStillReachesGraduation() {
        for rarity in [Rarity.common, .uncommon, .rare, .legendary] {
            let total = Double(PokemonBalance.graduationTotal(rarity))
            let needed = total / 0.9
            XCTAssertLessThan(needed, Double(SaveTransfer.maxTokenValue),
                              "\(rarity) 는 가장 느린 성격으로도 도달 가능해야 한다")
        }
    }

    /// 효과가 있는 성격만 라벨이 붙는다 — 중립 17종에 "±0%" 를 붙이면 소음이다.
    func testOnlyEffectfulNaturesGetALabel() {
        let l = L(.en)
        XCTAssertNotNil(l.natureGrowthEffect(.jolly))
        XCTAssertNotNil(l.natureGrowthEffect(.brave))
        XCTAssertNil(l.natureGrowthEffect(.hardy))
        XCTAssertNil(l.natureGrowthEffect(nil))
    }
}
