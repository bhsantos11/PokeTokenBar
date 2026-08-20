import XCTest
@testable import PokeTokenBar

// MARK: 상호작용 — 애칭 / 쓰다듬기

/// 2단계 라인 — 임계를 넘긴 개체가 라인 로딩 직후 진화하게 만드는 프로바이더.
private struct EvolvingLineProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID,
                tree: EvoNode(speciesID: baseSpeciesID,
                              children: [EvoNode(speciesID: baseSpeciesID + 1, children: [])]),
                rarity: .common, names: [:])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

private struct InteractionNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class InteractionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(url: URL? = nil, nickname: String = "null") -> CompanionStore {
        let url = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("interact-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":1,"
            + "\"rarity\":\"common\",\"totalForms\":3,\"nickname\":\(nickname)}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(mon)}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: InteractionNoProvider(), clock: { self.now },
                              fileURL: url, rng: SeededRNG(seed: 4))
    }

    // MARK: 애칭

    /// [핵심 회귀] 애칭은 **디스크 왕복을 견뎌야 한다.** `MonState` 는 손수 쓴 디코더를 갖고 있어,
    /// 새 필드는 인코딩만 되고 디코딩에서 빠지면 저장은 "성공"하면서 다음 기동에 사라진다
    /// (박스가 정확히 이 방식으로 죽을 뻔했다). 메모리가 아니라 파일을 다시 읽어 확인한다.
    func testNicknameSurvivesAReloadFromDisk() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nick-\(UUID().uuidString).json")
        let s = store(url: url)
        XCTAssertTrue(s.setNickname("Sprout"))
        XCTAssertEqual(s.displayName, "Sprout")

        let reloaded = CompanionStore(provider: InteractionNoProvider(), clock: { self.now },
                                      fileURL: url, rng: SeededRNG(seed: 4))
        XCTAssertEqual(reloaded.state.active?.nickname, "Sprout", "재기동 후 애칭이 사라졌다")
        XCTAssertEqual(reloaded.displayName, "Sprout")
    }

    /// 비우면 해제 — 종 이름으로 돌아간다. 공백만 입력한 경우도 같다(눈에 안 보이는 이름 금지).
    func testEmptyOrBlankNicknameClearsIt() async {
        let s = store()
        s.setNickname("Sprout")
        s.setNickname("   ")
        XCTAssertNil(s.state.active?.nickname, "공백만 있는 이름은 해제로 다룬다")
        s.setNickname("Sprout")
        s.setNickname(nil)
        XCTAssertNil(s.state.active?.nickname)
    }

    /// 길이 상한은 레이아웃 방어다 — 400pt 패널에 임의 길이 문자열이 오면 카드가 통째로 늘어난다.
    /// **문자 수로 자른다**: 바이트로 자르면 한글·이모지가 반토막 난다.
    func testLongNicknameIsCappedByCharactersNotBytes() async {
        let s = store()
        s.setNickname(String(repeating: "가", count: 100))
        let saved = s.state.active?.nickname ?? ""
        XCTAssertEqual(saved.count, CompanionStore.nicknameMaxLength)
        XCTAssertTrue(saved.allSatisfy { $0 == "가" }, "반토막 난 문자가 없어야 한다")
    }

    /// 애칭은 졸업할 때 도감으로 넘어가야 한다 — 안 넘기면 끝까지 키운 개체에서만 이름이 사라진다.
    func testNicknameCarriesIntoTheDexEntry() throws {
        let entry = DexEntry(nickname: "Sprout", baseID: 10, finalID: 12, chainOrder: [10, 12],
                             rarity: .common, caughtAt: nil)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DexEntry.self, from: data)
        XCTAssertEqual(decoded.nickname, "Sprout", "DexEntry 도 손수 쓴 디코더라 왕복을 확인한다")
    }

    /// 알에는 붙일 개체가 없다.
    func testCannotNameAnEgg() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("egg-\(UUID().uuidString).json")
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":null}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: InteractionNoProvider(), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 4))
        XCTAssertFalse(s.setNickname("Sprout"))
    }

    /// 외부 세이브의 애칭도 경계에서 잘려야 한다 — 앱 내부 경로만 막으면 손편집·다른 기기 세이브가
    /// 그대로 통과해 레이아웃을 깨뜨린다(외부 입력 규칙, defect-log §판정·데이터).
    func testImportedNicknameIsBoundedAtTheBoundary() {
        var mon = MonState(baseID: 10, pathIDs: [10], stageIndex: 0, usedAtStage: 1,
                           rarity: .common, totalForms: 2)
        mon.nickname = String(repeating: "가", count: 5_000)
        var state = CompanionState()
        state.active = mon
        state.boxed = [mon]
        let clean = SaveTransfer.sanitized(state)
        XCTAssertEqual(clean.active?.nickname?.count, CompanionStore.nicknameMaxLength)
        XCTAssertEqual(clean.boxed.first?.nickname?.count, CompanionStore.nicknameMaxLength,
                       "박스 개체도 같은 경계를 통과해야 한다")
    }

    /// [회귀] 폴 사이에 일어난 변화도 **즉시 알려야** 한다.
    ///
    /// Linux 앱은 사용량 폴(기본 2분)에서만 다시 그린다. 폴 *도중*에 일어난 일은 그 틱에 반영되지만,
    /// 진화 라인이 뒤늦게 도착해 진화가 성립하는 경우처럼 폴 **사이**에 일어난 변화는 다음 폴까지
    /// 화면에 안 나온다 — 이전 형태가 꽉 찬 진행 막대 아래 그대로 남는다(직접 겪었다).
    func testCompanionEventFiresOutsideThePollForLateEvolutions() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("evt-\(UUID().uuidString).json")
        // 임계를 이미 넘긴 개체 — 라인이 로딩되는 순간 진화가 성립한다.
        // 1단계 임계(250M)는 넘고, 이월분이 2단계 임계(500M)에는 못 미치는 값 — 진화 한 번에서 멈춘다.
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":300000000,"
            + "\"rarity\":\"common\",\"totalForms\":2}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(mon)}"
        try? json.data(using: .utf8)!.write(to: url)

        let s = CompanionStore(provider: EvolvingLineProvider(), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 8))
        var events = 0
        s.onCompanionEvent = { events += 1 }
        // update() 는 라인 로딩을 **비동기로 예약만** 하고 즉시 돌아온다. 진화는 그 뒤 라인이 도착할 때
        // 성립한다 — 즉 이 틱이 아니라 폴 사이다. 그 창을 재현하려고 update 이후에 기다린다.
        s.update(todayTokensByProvider: ["t": 1], todayDate: "d", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
        XCTAssertEqual(s.state.active?.stageIndex, 0, "update 시점엔 아직 라인이 없어 진화하지 않는다")
        for _ in 0..<2000 where events == 0 { await Task.yield() }

        XCTAssertGreaterThan(events, 0, "폴 없이 일어난 진화가 화면에 알려지지 않았다")
        XCTAssertEqual(s.state.active?.stageIndex, 1, "실제로 진화했어야 한다")
    }

    // MARK: 쓰다듬기

    /// 쓰다듬기는 **게임 상태를 바꾸지 않는다.** 클릭으로 이득이 생기면 상호작용이 아니라 노동이 된다.
    func testPettingChangesNoGameState() async {
        let s = store()
        let growthBefore = s.state.active?.usedAtStage
        let spentBefore = s.state.spentTokens
        let usedBefore = s.state.usedSinceInstall
        s.pet()
        XCTAssertEqual(s.state.active?.usedAtStage, growthBefore)
        XCTAssertEqual(s.state.spentTokens, spentBefore)
        XCTAssertEqual(s.state.usedSinceInstall, usedBefore)
    }

    /// 반응은 상태에 맞아야 한다 — 자는 애가 응원하면 화면이 스스로 모순된다.
    /// 모든 상태가 문구를 갖는지 전수로 확인한다(빠진 상태는 폴백으로 떨어져 무미건조해진다).
    func testEveryDisplayStateHasItsOwnReactions() {
        let l = L(.en)
        for state in [CompanionStateKind.egg, .idle, .working, .focus, .tired, .sleep, .levelUp] {
            XCTAssertFalse(l.petReactions(state: state, name: "X").isEmpty,
                           "\(state) 에 반응 문구가 없다")
        }
        XCTAssertTrue(l.petReactions(state: .sleep, name: "X").contains { $0.contains("asleep") || $0.contains("zzZ") },
                      "자는 상태의 문구가 자는 것처럼 읽혀야 한다")
    }

    /// 같은 roll 이면 같은 문장 — 뷰가 두 번 그려도 말이 바뀌지 않는다.
    func testReactionIsDeterministicForAGivenRoll() {
        let l = L(.en)
        let a = FloatingPetCopy.tapReaction(state: .idle, name: "Sprout", roll: 7, l: l)
        let b = FloatingPetCopy.tapReaction(state: .idle, name: "Sprout", roll: 7, l: l)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("Sprout"), "이름이 문장에 들어가야 한다")
    }

    /// roll 이 배열 길이를 넘어도 안전해야 한다(모듈로) — 인덱스 범위 초과로 죽지 않는다.
    func testHugeRollDoesNotCrash() {
        let l = L(.en)
        for roll in [UInt64.max, UInt64.max - 1, 0, 1] {
            XCTAssertFalse(FloatingPetCopy.tapReaction(state: .working, name: "X", roll: roll, l: l).isEmpty)
        }
    }

    /// [회귀] 반응은 **읽는 순간** 만료돼야 한다.
    ///
    /// 저장값을 그대로 돌려주면 `update()` 가 정리해 줄 때까지 화면에 남는다 — 폴 간격이 기본 2분이라
    /// "3초 창"이라고 적어 두고 실제로는 2분이었다. 창 안/밖을 각각 확인한다(한쪽만 보면 못 잡는다).
    func testReactionExpiresOnReadNotOnlyOnUpdate() async {
        let clock = ClockBoxI(now)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("react-read-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":1,"
            + "\"rarity\":\"common\",\"totalForms\":3}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(mon)}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: InteractionNoProvider(), clock: { clock.now },
                               fileURL: url, rng: SeededRNG(seed: 4))
        s.pet()
        XCTAssertNotNil(s.petReaction, "창 안에서는 보여야 한다")
        clock.now = now.addingTimeInterval(CompanionStore.petReactionWindow + 0.5)
        XCTAssertNil(s.petReaction, "update() 없이도 창이 지나면 사라져야 한다")
    }

    /// 반응은 창이 지나면 사라진다 — 뷰가 자기 타이머를 돌리지 않도록 `update()` 가 정리한다.
    func testReactionExpiresOnTheNextUpdate() async {
        let clock = ClockBoxI(now)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("react-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":1,"
            + "\"rarity\":\"common\",\"totalForms\":3}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(mon)}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: InteractionNoProvider(), clock: { clock.now },
                               fileURL: url, rng: SeededRNG(seed: 4))
        s.pet()
        XCTAssertNotNil(s.petReaction)
        clock.now = now.addingTimeInterval(CompanionStore.petReactionWindow + 1)
        s.update(todayTokensByProvider: ["t": 1], todayDate: "d", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
        XCTAssertNil(s.petReaction, "창이 지난 반응이 남아 있다")
    }
}

private final class ClockBoxI: @unchecked Sendable {
    nonisolated(unsafe) var now: Date
    init(_ d: Date) { now = d }
}
