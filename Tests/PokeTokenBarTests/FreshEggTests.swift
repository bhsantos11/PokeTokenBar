import XCTest
@testable import PokeTokenBar

// MARK: 새 알 (리롤 — 현재 포켓몬 폐기, 도감·확률 무영향)

private struct FreshEggNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class FreshEggTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 활성 포켓몬(baseID 10, common 3형태, 성장 200M) + 도감 1개 + 수집기록 1개(1:3) + 지갑.
    /// active=false 면 알(활성 없음) 상태.
    private func store(active: Bool = true, shiny: Bool = false, used: Int = 5_000_000_000,
                       spent: Int = 0) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("egg-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":200000000,"
            + "\"rarity\":\"common\",\"totalForms\":3,\"isShiny\":\(shiny)}"
        let dex = "{\"baseID\":1,\"finalID\":3,\"chainOrder\":[1,2,3],\"rarity\":\"common\"}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":\(spent),"
            + "\"lastDate\":\"d\",\"active\":\(active ? mon : "null"),\"dex\":[\(dex)],\"collectedFinals\":[\"1:3\"]}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: FreshEggNoProvider(), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))
    }

    func testPriceIsOneBillion() { XCTAssertEqual(FreshEgg.price, 1_000_000_000) }

    /// [핵심] 리롤 = **박스로 이동**(2026-08-19 이전엔 폐기). active 는 비고 새 알이 시작되지만
    /// 개체는 `state.boxed` 에 살아 있다. **도감·확률(collectedFinals) 는 여전히 불변** — 졸업이
    /// 아니라 보관이라, 영구 기록에 들어가지도 부화 가중치를 바꾸지도 않는다.
    func testBuyFreshEggBoxesActiveWithoutDexOrProbabilityImpact() async {
        let s = store(used: 5_000_000_000, spent: 0)
        let persistedDexBefore = s.state.dex
        let collectedBefore = s.state.collectedFinals
        XCTAssertEqual(s.dexEntries.count, persistedDexBefore.count + 1,
                       "현재 포켓몬은 졸업 전에도 도감 화면에 표시")
        XCTAssertTrue(s.hasActive)
        let activeBefore = s.state.active
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertNil(s.state.active, "활성 자리는 비어야 한다(알로 교체)")
        XCTAssertEqual(s.state.boxed.count, 1, "폐기가 아니라 박스로 들어가야 한다")
        XCTAssertEqual(s.state.boxed.first?.baseID, activeBefore?.baseID)
        XCTAssertEqual(s.state.boxed.first?.usedAtStage, activeBefore?.usedAtStage,
                       "성장이 보존돼야 한다 — 잃으면 박스는 느린 폐기일 뿐이다")
        XCTAssertTrue(s.isEgg)
        XCTAssertEqual(s.state.eggUsage, 0, "새 알은 처음부터 인큐베이션")
        XCTAssertNil(s.state.pendingHatchID)
        XCTAssertEqual(s.state.dex.map(\.id), persistedDexBefore.map(\.id),
                       "영구 도감 불변 — 졸업이 아니라 폐기")
        XCTAssertEqual(s.dexEntries.count, persistedDexBefore.count + 1,
                       "박스에 든 개체는 화면용 엔트리로 계속 보여야 한다 — 사라지면 잃은 것과 구별이 안 된다")
        XCTAssertEqual(s.state.collectedFinals, collectedBefore, "확률 가중(collectedFinals) 불변")
        XCTAssertEqual(s.state.spentTokens, FreshEgg.price, "지갑에서 1B 차감")
        XCTAssertEqual(s.availableTokens, 5_000_000_000 - FreshEgg.price)
    }

    /// 폐기한 개체(baseID 10)의 종은 collectedFinals 에 들어가지 않는다(이후 부화 확률에 영향 없음).
    func testDiscardedSpeciesNotCollected() async {
        let s = store()
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertFalse(s.state.collectedFinals.contains { $0.hasPrefix("10:") },
                       "폐기 개체 종은 수집 기록에 없어야 함")
    }

    /// 알 상태(활성 없음)에선 리롤할 게 없어 불가.
    func testCannotRerollWhenEgg() async {
        let s = store(active: false, used: 5_000_000_000)
        XCTAssertFalse(s.hasActive)
        XCTAssertFalse(s.canBuyFreshEgg)
        XCTAssertFalse(s.buyFreshEgg())
        XCTAssertEqual(s.state.spentTokens, 0, "no-op")
    }

    /// 잔액이 가격 미만이면 불가 — 활성 유지.
    func testCannotRerollWithoutFunds() async {
        let s = store(used: 500_000_000)   // 1B 미만
        XCTAssertFalse(s.canBuyFreshEgg)
        XCTAssertFalse(s.buyFreshEgg())
        XCTAssertNotNil(s.state.active, "활성 유지")
        XCTAssertEqual(s.state.spentTokens, 0)
    }

    /// 이로치도 폐기 가능(추가 경고는 UI 단계, 로직은 동일) — 리롤 후 흔적 없음.
    func testShinyCanBeRerolled() async {
        let s = store(shiny: true)
        XCTAssertTrue(s.currentIsShiny)
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertNil(s.state.active)
        XCTAssertFalse(s.currentIsShiny)
    }
}
