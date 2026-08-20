import XCTest
@testable import PokeTokenBar

// MARK: 지갑 요약 — "지금 뭘 살 수 있나 / 다음 목표까지 얼마나"

private struct WalletNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class WalletTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// `active` 가 있어야 알이 상점에 나온다(알은 "지금 개체를 박스로 보내는" 상품이므로).
    private func store(used: Int, spent: Int = 0, active: Bool = true) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallet-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":1,"
            + "\"rarity\":\"common\",\"totalForms\":2}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":\(spent),"
            + "\"lastDate\":\"d\",\"active\":\(active ? mon : "null")}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: WalletNoProvider(), clock: { self.now },
                              fileURL: url, rng: SeededRNG(seed: 6))
    }

    /// 잔액 = 누적 − 사용. 구매는 잔액만 줄이고 **누적(성장 미터)은 건드리지 않는다** — 이게
    /// 지갑 요약이 세 값을 함께 보여 주는 이유다.
    func testBalanceIsEarnedMinusSpentAndEarnedNeverDrops() async {
        let s = store(used: 3_000_000_000, spent: 1_000_000_000)
        XCTAssertEqual(s.availableTokens, 2_000_000_000)
        XCTAssertEqual(s.walletEarned, 3_000_000_000)
        XCTAssertEqual(s.walletSpent, 1_000_000_000)

        let before = s.walletEarned
        XCTAssertTrue(s.buy(.mint))
        XCTAssertEqual(s.walletEarned, before, "구매가 누적을 되감으면 성장이 줄어든 것처럼 보인다")
        XCTAssertLessThan(s.availableTokens, 2_000_000_000)
    }

    /// "지금 살 수 있는 것 중 가장 비싼 것" — 목록에서 값 비교를 사람이 하지 않게 한다.
    func testBestAffordableIsTheDearestThingInReach() async {
        // 민트 100M / 사탕 500M — 사탕은 되고 알(1B)은 안 되는 잔액.
        let s = store(used: 600_000_000)
        XCTAssertEqual(s.bestAffordable.map { $0.price }, 500_000_000)
    }

    /// 아무것도 못 살 때는 nil — "0개까지 살 수 있어요" 같은 문장을 만들지 않는다.
    func testNothingAffordableIsNil() async {
        let s = store(used: 1_000)
        XCTAssertNil(s.bestAffordable)
        XCTAssertNotNil(s.nextGoal, "못 사더라도 다음 목표는 있어야 한다")
    }

    /// 다음 목표 = **못 사는 것 중 가장 싼 것**, 그리고 그 차액.
    func testNextGoalIsTheCheapestThingOutOfReach() async {
        let s = store(used: 600_000_000)
        let goal = try? XCTUnwrap(s.nextGoal)
        XCTAssertEqual(goal?.entry.price, 1_000_000_000, "다음은 기본 알")
        XCTAssertEqual(goal?.remaining, 400_000_000)
    }

    /// 전부 살 수 있으면 목표는 없다 — 남은 것이 없는데 "얼마 남았어요"를 만들면 거짓말이 된다.
    func testNoGoalWhenEverythingIsAffordable() async {
        let s = store(used: 100_000_000_000)
        XCTAssertNotNil(s.bestAffordable)
        XCTAssertNil(s.nextGoal)
    }

    /// 상점 이름은 모든 항목에 있어야 한다 — 빠지면 지갑 문장이 빈칸으로 나온다.
    func testEveryShopEntryHasAName() async {
        let l = L(.en)
        for kind in ItemKind.allCases {
            XCTAssertFalse(l.shopEntryName(.item(kind)).isEmpty)
        }
        for tier in FreshEgg.shopTiers {
            XCTAssertFalse(l.shopEntryName(.egg(tier)).isEmpty)
        }
    }
}
