import XCTest
@testable import PokeTokenBar

// MARK: 박스(PC) — 알 구매가 개체를 폐기하지 않고 보관한다

/// 단일 형태 라인만 돌려주는 프로바이더 — 그 개체는 곧바로 terminal 이라 임계를 넘기면 **졸업**한다.
/// 졸업 경로를 밟으려면 라인이 로딩돼야 한다(`applyUsage` 의 진화 루프가 `currentLine` 을 요구).
private struct BoxTerminalLineProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common, names: [baseSpeciesID: ["en": "Testmon"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

private struct BoxNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class BoxTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 활성 개체(baseID 10, common 3형태, 성장 200M) + 지갑. `active: false` 면 알 상태.
    /// 개체 JSON 한 마리. `state` 가 `private(set)` 이라 테스트는 파일로 씨를 뿌린다 — 덕분에
    /// 모든 케이스가 **디코더를 실제로 통과**한다(이 기능이 깨지는 주된 지점이 디코더다).
    private func monJSON(_ baseID: Int, grown: Int = 200_000_000, rarity: String = "common",
                         forms: Int = 3, extra: String = "") -> String {
        "{\"baseID\":\(baseID),\"pathIDs\":[\(baseID)],\"stageIndex\":0,\"usedAtStage\":\(grown),"
            + "\"rarity\":\"\(rarity)\",\"totalForms\":\(forms)\(extra)}"
    }

    private func store(active: Bool = true, used: Int = 5_000_000_000,
                       eggUsage: Int = 0, eggTier: String = "null", pendingHatchID: String = "null",
                       boxed: [String] = [], url: URL? = nil) -> CompanionStore {
        let url = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("box-\(UUID().uuidString).json")
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(active ? monJSON(10) : "null"),"
            + "\"boxed\":[\(boxed.joined(separator: ","))],"
            + "\"pendingHatchID\":\(pendingHatchID),"
            + "\"eggUsage\":\(eggUsage),\"eggTier\":\(eggTier)}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: BoxNoProvider(), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))
    }

    // MARK: 영속 (이 기능이 실패할 가장 그럴듯한 방식)

    /// [핵심 회귀] 박스는 **디스크 왕복을 견뎌야 한다.**
    ///
    /// `CompanionState` 는 손수 쓴 `init(from:)` 을 갖고 `CodingKeys` 는 합성이다 → 새 필드는 인코딩은
    /// 되는데 디코더가 안 읽으면 조용히 사라진다. 저장은 "성공"하고 다음 기동에서 박스만 비어 있다.
    /// 개체를 잃지 않으려고 만든 기능이 개체를 잃는 가장 그럴듯한 경로라, 메모리 상태가 아니라
    /// **파일을 다시 읽어** 확인한다.
    func testBoxSurvivesAReloadFromDisk() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-persist-\(UUID().uuidString).json")
        let s = store(url: url)
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertEqual(s.state.boxed.count, 1)

        // 같은 파일을 새 스토어로 다시 읽는다 = 앱 재기동.
        let reloaded = CompanionStore(provider: BoxNoProvider(), clock: { self.now },
                                      fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.state.boxed.count, 1, "재기동 후 박스가 비었다 — 디코더가 boxed 를 안 읽는다")
        XCTAssertEqual(reloaded.state.boxed.first?.baseID, 10)
        XCTAssertEqual(reloaded.state.boxed.first?.usedAtStage, 200_000_000, "성장까지 살아남아야 한다")
    }

    /// 박스 항목 하나가 깨져도 나머지는 살아남는다(도감과 같은 항목별 격리).
    /// 통째 디코드였다면 개체 하나의 손상이 박스 전체를 날린다.
    func testCorruptBoxEntryDoesNotWipeTheWholeBox() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-lossy-\(UUID().uuidString).json")
        let good = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":1,"
            + "\"rarity\":\"common\",\"totalForms\":3}"
        let broken = "{\"baseID\":11,\"pathIDs\":[],\"stageIndex\":0,\"usedAtStage\":1,"
            + "\"rarity\":\"common\",\"totalForms\":3}"   // 빈 pathIDs = 디코드 실패 조건
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":null,\"boxed\":[\(good),\(broken),\(good)]}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: BoxNoProvider(), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertEqual(s.state.boxed.count, 2, "손상 항목만 빠지고 나머지는 남아야 한다")
    }

    // MARK: 교대

    /// 꺼내기 = 교대. 활성이 박스로, 고른 개체가 활성으로. 양쪽 성장 모두 보존.
    func testWithdrawSwapsActiveAndPreservesGrowth() async {
        let s = store()
        XCTAssertTrue(s.buyFreshEgg())            // 10 번이 박스로, 알 시작
        XCTAssertTrue(s.withdraw(at: 0))          // 10 번을 다시 꺼낸다
        XCTAssertEqual(s.state.active?.baseID, 10)
        XCTAssertEqual(s.state.active?.usedAtStage, 200_000_000, "꺼낸 개체의 성장 보존")
        XCTAssertTrue(s.state.boxed.isEmpty)

        // 활성이 **있는** 상태에서의 교대 — 위 케이스(알 상태에서 꺼내기)와 다른 분기다.
        let swap = store(boxed: [monJSON(25, grown: 7, rarity: "rare", forms: 2)])
        XCTAssertTrue(swap.withdraw(at: 0))
        XCTAssertEqual(swap.state.active?.baseID, 25)
        XCTAssertEqual(swap.state.boxed.map(\.baseID), [10], "직전 활성이 박스로 들어가야 한다")
        XCTAssertEqual(swap.state.boxed.first?.usedAtStage, 200_000_000, "넣은 개체의 성장도 보존")
    }

    /// 꺼내기는 진행 중인 부화를 무효화해야 한다 — `activeGeneration` 이 안 오르면 날아오던 부화
    /// 응답이 방금 꺼낸 개체를 덮어쓴다.
    func testWithdrawInvalidatesInFlightWork() async {
        let s = store()
        XCTAssertTrue(s.buyFreshEgg())
        let before = s.activeGeneration
        XCTAssertTrue(s.withdraw(at: 0))
        XCTAssertGreaterThan(s.activeGeneration, before, "세대가 안 오르면 in-flight 결과가 덮어쓴다")
        XCTAssertNil(s.currentLine, "이전 개체의 진화 트리를 그대로 쓰면 이름·진화가 틀린다")
    }

    // MARK: 보류된 알 (산 보증이 사라지지 않는다)

    /// 알을 품은 채 개체를 꺼내면 알은 **파괴되지 않고 보류**된다. 진행·보증·프리롤이 함께 간다.
    func testWithdrawingDuringAnEggHoldsItInsteadOfDestroyingIt() async {
        let s = store(active: false, eggUsage: 3_000_000, eggTier: "\"rare\"",
                      pendingHatchID: "133", boxed: [monJSON(10, grown: 5, forms: 2)])
        XCTAssertTrue(s.withdraw(at: 0))

        XCTAssertEqual(s.state.heldEgg?.usage, 3_000_000, "인큐베이션 진행이 보존돼야 한다")
        XCTAssertEqual(s.state.heldEgg?.tier, .rare, "4B 주고 산 보증이 사라지면 안 된다")
        XCTAssertEqual(s.state.heldEgg?.pendingHatchID, 133)
        XCTAssertEqual(s.state.eggUsage, 0, "품고 있는 알 자리는 비어야 한다(개체가 들어왔다)")
        XCTAssertNil(s.state.eggTier)
    }

    /// 보류된 알로 돌아가면 진행·보증이 그대로 복원된다(왕복 무손실).
    func testReturningToAHeldEggRestoresItExactly() async {
        let s = store(active: false, eggUsage: 3_000_000, eggTier: "\"rare\"",
                      pendingHatchID: "133", boxed: [monJSON(10, grown: 5, forms: 2)])
        XCTAssertTrue(s.withdraw(at: 0))
        XCTAssertTrue(s.returnToHeldEgg())

        XCTAssertNil(s.state.active, "알 상태로 돌아가야 한다")
        XCTAssertEqual(s.state.eggUsage, 3_000_000)
        XCTAssertEqual(s.state.eggTier, .rare)
        XCTAssertEqual(s.state.pendingHatchID, 133)
        XCTAssertNil(s.state.heldEgg, "복원했으면 보류분은 비워야 한다 — 남으면 알이 둘이 된다")
        XCTAssertEqual(s.state.boxed.map(\.baseID), [10], "데리고 있던 개체는 박스로")
    }

    /// **경제 구멍 가드.** 보류된 알이 없으면 알로 돌아갈 수 없다. 열어 두면 개체를 박스에 넣는 것만으로
    /// `eggUsage == 0` 인 새 알이 공짜로 생기고, 알을 얻는 정당한 경로(졸업 750M~6B / 구매 1B~4B)가
    /// 통째로 우회된다.
    func testCannotConjureAFreeEggByEmptyingTheActiveSlot() async {
        let s = store()
        XCTAssertNil(s.state.heldEgg)
        XCTAssertFalse(s.canReturnToHeldEgg)
        XCTAssertFalse(s.returnToHeldEgg(), "보류된 알 없이 활성 자리를 비우면 공짜 알이 된다")
        XCTAssertNotNil(s.state.active, "상태가 바뀌면 안 된다")
        XCTAssertTrue(s.state.boxed.isEmpty)
    }

    /// 보류된 알이 있는 동안엔 새 알을 팔지 않는다 — 팔면 이미 값을 치른 알이 조용히 덮어써진다.
    func testShopRefusesANewEggWhileOneIsHeld() async {
        let s = store(active: false, eggUsage: 3_000_000, eggTier: "\"rare\"",
                      boxed: [monJSON(10, grown: 5, forms: 2)])
        XCTAssertTrue(s.withdraw(at: 0))
        XCTAssertNotNil(s.state.heldEgg)
        for tier in FreshEgg.shopTiers {
            XCTAssertFalse(s.canBuyEgg(tier), "보류된 알이 있는데 \(tier?.rawValue ?? "기본") 알이 팔린다")
            XCTAssertFalse(s.buyEgg(tier))
        }
        XCTAssertEqual(s.state.heldEgg?.tier, .rare, "보류된 알은 그대로여야 한다")
    }

    /// [P1 회귀 — Codex 리뷰 2026-08-19] 보류된 알을 둔 채 그 개체가 **졸업**하면 알이 사라졌다.
    /// `graduate()` 가 active 만 비우고 heldEgg 를 남기면, 다음 기동의 `sanitized` 가
    /// "active 없는데 heldEgg 있음"을 손상으로 보고 지운다 — 산 알이 졸업 축하와 함께 증발한다.
    /// 트리거 브랜치는 **졸업 경로**다: 꺼내기·되돌리기만 테스트하면 절대 안 밟힌다.
    func testGraduatingWhileAnEggIsHeldResumesItInsteadOfLosingIt() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-grad-\(UUID().uuidString).json")
        // 졸업 직전(common 총 750M, 1형태 → 임계 750M)까지 키운 개체를 박스에 두고 알을 품는다.
        let nearlyDone = monJSON(10, grown: 749_999_999, rarity: "common", forms: 1)
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":null,\"boxed\":[\(nearlyDone)],"
            + "\"eggUsage\":3000000,\"eggTier\":\"rare\",\"pendingHatchID\":133}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: BoxTerminalLineProvider(), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertTrue(s.withdraw(at: 0))
        XCTAssertEqual(s.state.heldEgg?.tier, .rare)
        // 꺼낸 개체의 라인이 로딩될 때까지 기다린다 — 없으면 진화/졸업 판정 자체가 안 돈다.
        for _ in 0..<500 where s.currentLine == nil { await Task.yield() }
        XCTAssertNotNil(s.currentLine, "라인이 로딩돼야 졸업 경로를 밟는다")

        // 첫 update 는 프로바이더 기준값만 심는다(과거 로그 소급 금지) — 성장은 **그 다음** 틱부터다.
        // 한 번만 부르면 델타가 0이라 졸업이 안 일어나고, 테스트가 조용히 아무것도 검증하지 않는다.
        s.update(todayTokensByProvider: ["t": 1], todayDate: "d2", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
        // 마지막 1 토큰으로 졸업시킨다.
        s.update(todayTokensByProvider: ["t": 2], todayDate: "d2", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
        XCTAssertNil(s.state.active, "졸업했어야 한다")
        XCTAssertNil(s.state.heldEgg, "보류분은 복원되며 비워져야 한다")
        XCTAssertEqual(s.state.eggTier, .rare, "산 보증이 졸업으로 사라지면 안 된다")
        XCTAssertEqual(s.state.eggUsage, 3_000_000, "인큐베이션 진행도 돌아와야 한다")
        XCTAssertEqual(s.state.pendingHatchID, 133)

        // 그리고 디스크 왕복을 견뎌야 한다 — sanitized 가 지우던 바로 그 지점.
        let reloaded = CompanionStore(provider: BoxTerminalLineProvider(), clock: { self.now },
                                      fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.state.eggTier, .rare, "재기동에서 보증이 지워졌다")
        XCTAssertEqual(reloaded.state.eggUsage, 3_000_000)
    }

    /// [P1 회귀] 새 상태를 담은 세이브는 **구버전이 읽어서 납작하게 만들면 안 된다.** 스키마를 올려
    /// 구버전이 `newerSchema` 로 거절하게 한다 — "못 읽는다"가 "읽고 지웠다"보다 낫다.
    ///
    /// 값만 비교하지 않고 **필드 수와 함께** 고정한다: 스키마를 안 올린 채 필드만 늘어나는 것이 실제로
    /// 일어난 일이라(2 에서 멈춘 사이 다섯 개가 추가됐다), 막아야 하는 건 그 조합이다.
    func testSaveSchemaIsBumpedWheneverStateGainsFields() async {
        let fieldCount = Mirror(reflecting: CompanionState()).children.count
        XCTAssertEqual(SaveEnvelope.schemaVersion, 4,
                       "필드를 더했으면 스키마도 올려라 — 안 올리면 구버전이 조용히 날린다")
        XCTAssertEqual(fieldCount, 23,
                       "CompanionState 필드 수가 바뀌었다. 저장에 남는 필드를 더했다면 "
                       + "SaveEnvelope.schemaVersion 을 올리고 이 숫자도 갱신하라 — 안 올리면 그 사이 "
                       + "버전의 앱이 모르는 키를 무시한 뒤 다음 저장에서 통째로 날린다.")
    }

    /// 알 구매는 이제 파괴가 아니다 — destructive 스타일과 이로치 경고가 남아 있으면 안전한 동작이
    /// 위험해 보이고, 진짜 위험한 곳에서 그 경고의 무게가 사라진다.
    func testEggPurchaseIsNoLongerPresentedAsDestructive() async {
        for tier in FreshEgg.shopTiers {
            XCTAssertFalse(ActionConfirmPolicy.discardsCompanion(.egg(tier)))
            XCTAssertEqual(ActionConfirmPolicy.steps(buying: .egg(tier), currentIsShiny: true),
                           [.confirm], "박스로 가는데 '정말 놓아줄까요?'를 물으면 거짓말이다")
        }
    }

    // MARK: 화면용 파생값

    /// 박스에 넣은 개체는 도감 화면에서 **사라지면 안 된다** — 사라지면 잃은 것과 구별이 안 된다.
    func testBoxedMonsStayVisibleInTheCollection() async {
        let s = store()
        let speciesBefore = Set(s.dexSpecies.map(\.id))
        XCTAssertTrue(speciesBefore.contains(10))
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertTrue(Set(s.dexSpecies.map(\.id)).contains(10), "박스 개체의 종이 격자에서 사라졌다")
        XCTAssertTrue(s.dexEntries.contains { $0.baseID == 10 }, "박스 개체의 포획 로그 항목이 사라졌다")
    }

    /// 위장 중인 메타몽은 박스에서도 이로치를 숨긴다 — 박스 화면이 리빌 전에 정체를 흘리면
    /// 연출이 통째로 죽는다.
    func testBoxDoesNotLeakAnUnrevealedShiny() async {
        let disguised = MonState(baseID: 10, pathIDs: [10], stageIndex: 0, usedAtStage: 1,
                                 rarity: .common, totalForms: 2, isShiny: true,
                                 dittoDisguise: 10, dittoRevealed: false)
        XCTAssertFalse(CompanionStore.displayShiny(disguised), "리빌 전엔 숨겨야 한다")
        var revealed = disguised
        revealed.dittoRevealed = true
        XCTAssertTrue(CompanionStore.displayShiny(revealed), "리빌 후엔 보여야 한다")

        let s = store(active: false,
                      boxed: [monJSON(10, grown: 1, forms: 2,
                                      extra: ",\"isShiny\":true,\"dittoDisguise\":10,\"dittoRevealed\":false")])
        XCTAssertFalse(s.dexEntries.contains { $0.baseID == 10 && $0.isShiny },
                       "박스 항목이 위장 중인 이로치를 흘렸다")
    }
}
