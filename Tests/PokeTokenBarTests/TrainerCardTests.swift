import XCTest
@testable import PokeTokenBar

// MARK: 트레이너 카드 — 여정 요약 수치

final class TrainerCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func dex(_ base: Int, _ final: Int, rarity: Rarity = .common,
                     shiny: Bool = false, chain: [Int]? = nil) -> DexEntry {
        DexEntry(baseID: base, finalID: final, chainOrder: chain ?? [base, final],
                 rarity: rarity, caughtAt: nil, isShiny: shiny)
    }

    private func mon(_ base: Int, stage: Int = 0, path: [Int]? = nil, shiny: Bool = false) -> MonState {
        MonState(baseID: base, pathIDs: path ?? [base], stageIndex: stage, usedAtStage: 1,
                 rarity: .common, totalForms: 2, isShiny: shiny)
    }

    /// 종 수는 **체인 전체**를 센다 — 졸업한 개체는 그 라인의 모든 단계를 거쳐 왔다.
    func testGraduatedSpeciesCountsTheWholeChain() async {
        var state = CompanionState()
        state.dex = [dex(1, 3, chain: [1, 2, 3])]
        let stats = TrainerCard.stats(state: state, now: now)
        XCTAssertEqual(stats.speciesGraduated, 3)
        XCTAssertEqual(stats.graduations, 1, "개체 수는 1")
    }

    /// 아직 키우는 중인 개체는 **도달한 단계까지만** 본 것으로 센다.
    /// 계획된 미래 단계까지 세면 아직 못 본 종이 보유로 잡힌다.
    func testSeenCountsOnlyReachedStagesOfLivingMons() async {
        var state = CompanionState()
        state.active = mon(1, stage: 0, path: [1, 2, 3])
        let stats = TrainerCard.stats(state: state, now: now)
        XCTAssertEqual(stats.speciesSeen, 1, "1단계만 도달했다")
        XCTAssertEqual(stats.speciesGraduated, 0)
        XCTAssertEqual(stats.completion, 0)
    }

    /// 박스 개체도 함께 센다 — 넣어 두었다고 본 적 없는 게 되지는 않는다.
    func testBoxedMonsCountTowardsSeen() async {
        var state = CompanionState()
        state.boxed = [mon(25), mon(100)]
        XCTAssertEqual(TrainerCard.stats(state: state, now: now).speciesSeen, 2)
        XCTAssertEqual(TrainerCard.stats(state: state, now: now).inBox, 2)
    }

    /// 위장 중인 메타몽의 이로치는 **세지 않는다** — 리빌 전에는 본인도 모르는 사실이다.
    func testDisguisedShinyDoesNotCountUntilRevealed() async {
        var hidden = mon(10, shiny: true)
        hidden.dittoDisguise = 10
        var state = CompanionState()
        state.active = hidden
        XCTAssertEqual(TrainerCard.stats(state: state, now: now).shinySpecies, 0)

        state.active?.dittoRevealed = true
        XCTAssertEqual(TrainerCard.stats(state: state, now: now).shinySpecies, 1)
    }

    /// 완성도 분모는 **본 적 있는 종**이다. 전체 종 수로 나누면 649분의 5 같은 값이 나와 의미가 없다.
    func testCompletionIsRelativeToSpeciesSeen() async {
        var state = CompanionState()
        state.dex = [dex(1, 2, chain: [1, 2])]
        state.active = mon(25)
        let stats = TrainerCard.stats(state: state, now: now)
        XCTAssertEqual(stats.speciesSeen, 3)
        XCTAssertEqual(stats.speciesGraduated, 2)
        XCTAssertEqual(stats.completion, 2.0 / 3.0, accuracy: 0.0001)
    }

    /// 비어 있는 상태에서 0으로 나누지 않는다.
    func testEmptyStateHasNoCompletionAndNoCrash() async {
        let stats = TrainerCard.stats(state: CompanionState(), now: now)
        XCTAssertEqual(stats.completion, 0)
        XCTAssertNil(stats.daysJourneyed)
        XCTAssertNil(stats.favouriteSpeciesID)
        XCTAssertNil(stats.rarestGraduated)
    }

    /// 최고 등급은 졸업 기록 중 가장 높은 것.
    func testRarestUsesTheHighestGraduatedRarity() async {
        var state = CompanionState()
        state.dex = [dex(1, 2, rarity: .common), dex(3, 4, rarity: .legendary), dex(5, 6, rarity: .rare)]
        XCTAssertEqual(TrainerCard.stats(state: state, now: now).rarestGraduated, .legendary)
    }

    /// 가장 많이 키운 종은 졸업 횟수 기준, 동률이면 도감 번호가 작은 쪽으로 **결정적**이어야 한다
    /// (딕셔너리 순회 순서에 따라 화면이 매번 바뀌면 안 된다).
    func testFavouriteIsDeterministicOnATie() async {
        var state = CompanionState()
        state.dex = [dex(7, 8), dex(1, 2)]
        for _ in 0..<20 {
            XCTAssertEqual(TrainerCard.stats(state: state, now: now).favouriteSpeciesID, 1)
        }
    }

    /// 여정 일수는 **일지의 첫 사건**부터다 — 설치일이 아니라 첫 사건이 이야기의 시작이다.
    func testJourneyLengthStartsAtTheFirstChronicledEvent() async {
        var state = CompanionState()
        state.chronicle = [
            ChronicleEntry(at: now.addingTimeInterval(-86_400 * 3), kind: .hatched, speciesID: 1),
            ChronicleEntry(at: now.addingTimeInterval(-86_400 * 9), kind: .hatched, speciesID: 2),
        ]
        XCTAssertEqual(TrainerCard.stats(state: state, now: now).daysJourneyed, 9)
    }

    /// 내보낸 파일 이름에 초 단위 시각이 들어가 **두 번 저장해도 첫 장을 안 덮어쓴다.**
    /// 이름 생성은 Core 에 있다 — Linux 뷰 안에 두면 이 계약을 테스트할 수 없다.
    func testExportFileNameIsUniquePerSecond() async {
        let a = TrainerCard.exportFileName(now: now)
        let b = TrainerCard.exportFileName(now: now.addingTimeInterval(1))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".png"))
        XCTAssertTrue(a.hasPrefix("PokeTokenBar-Trainer-"))
    }

    /// 파일명은 앱 언어와 무관해야 한다 — 언어에 따라 달라지면 정렬·스크립트 처리가 깨진다.
    func testExportFileNameIsLocaleIndependent() async {
        let name = TrainerCard.exportFileName(now: now)
        XCTAssertNil(name.rangeOfCharacter(from: CharacterSet.letters.subtracting(
            CharacterSet(charactersIn: "PokeTnBarTraienpg-"))),
            "파일명에 로케일 의존 문자가 섞였다: \(name)")
    }
}
