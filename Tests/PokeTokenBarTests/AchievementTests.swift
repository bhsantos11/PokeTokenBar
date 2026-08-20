import XCTest
@testable import PokeTokenBar

// MARK: 업적 — 일지·도감 위의 순수 질의

private struct AchievementNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class AchievementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func stats(_ state: CompanionState) -> TrainerStats {
        TrainerCard.stats(state: state, now: now)
    }
    private func entry(_ kind: ChronicleEntry.Kind, hour: Int = 14) -> ChronicleEntry {
        ChronicleEntry(at: now, kind: kind, speciesID: 1, hour: hour)
    }

    /// 아무것도 안 한 상태에서는 하나도 달성되지 않는다 — "0에서 시작"이 성립하는지부터 본다.
    func testNothingIsEarnedOnAFreshSave() async {
        let state = CompanionState()
        XCTAssertTrue(Achievements.earned(state: state, stats: stats(state)).isEmpty)
        XCTAssertEqual(Achievements.locked(state: state, stats: stats(state)).count,
                       Achievement.allCases.count)
    }

    /// **소급 적용.** 업적 기능이 생기기 전에 이미 이로치를 만난 사람은 즉시 그 업적을 갖는다 —
    /// 일지가 아니라 도감/개체 상태에서도 판정되기 때문이다. 과거를 인정하지 않으면 오래 쓴 사람이 벌을 받는다.
    func testEarnedRetroactivelyWithoutAnyChronicle() async {
        var state = CompanionState()
        state.dex = [DexEntry(baseID: 1, finalID: 2, chainOrder: [1, 2], rarity: .legendary,
                              caughtAt: nil, isShiny: true)]
        let earned = Achievements.earned(state: state, stats: stats(state))
        XCTAssertTrue(earned.contains(.firstGraduate))
        XCTAssertTrue(earned.contains(.shinyFound))
        XCTAssertTrue(earned.contains(.legendaryRaised))
        XCTAssertTrue(earned.contains(.firstHatch), "졸업했다면 부화도 했다")
    }

    /// 시각 기반 업적은 **기록된 지역 시각**을 쓴다. 읽는 시점의 시간대로 다시 계산하면 나라를
    /// 옮긴 사용자의 과거가 통째로 바뀐다.
    func testTimeOfDayAchievementsUseTheRecordedHour() async {
        var night = CompanionState()
        night.chronicle = [entry(.hatched, hour: 2)]
        XCTAssertTrue(Achievements.earned(state: night, stats: stats(night)).contains(.nightOwl))
        XCTAssertFalse(Achievements.earned(state: night, stats: stats(night)).contains(.earlyBird))

        var dawn = CompanionState()
        dawn.chronicle = [entry(.hatched, hour: 6)]
        XCTAssertTrue(Achievements.earned(state: dawn, stats: stats(dawn)).contains(.earlyBird))
        XCTAssertFalse(Achievements.earned(state: dawn, stats: stats(dawn)).contains(.nightOwl))
    }

    /// 사건 기반 업적은 그 사건이 있어야만 달성된다 — 각 종류를 개별로 확인한다.
    func testEventAchievementsRequireTheirOwnEvent() async {
        for (kind, achievement) in [(ChronicleEntry.Kind.withdrawn, Achievement.secondChance),
                                    (.renamed, .namer),
                                    (.dittoRevealed, .transformed)] {
            var state = CompanionState()
            state.chronicle = [entry(kind)]
            XCTAssertTrue(Achievements.earned(state: state, stats: stats(state)).contains(achievement),
                          "\(kind) 로 \(achievement) 가 달성돼야 한다")
            var other = CompanionState()
            other.chronicle = [entry(.boxed)]
            XCTAssertFalse(Achievements.earned(state: other, stats: stats(other)).contains(achievement),
                           "\(achievement) 가 관계없는 사건으로 달성됐다")
        }
    }

    /// 진행형 업적은 경계에서 정확히 달성된다(9종은 아직, 10종이면 달성).
    func testCollectorUnlocksExactlyAtTheThreshold() async {
        func stateWithSpecies(_ count: Int) -> CompanionState {
            var s = CompanionState()
            s.dex = (1...max(1, count)).map {
                DexEntry(baseID: $0, finalID: $0, chainOrder: [$0], rarity: .common, caughtAt: nil)
            }
            return s
        }
        let nine = stateWithSpecies(9)
        XCTAssertFalse(Achievements.earned(state: nine, stats: stats(nine)).contains(.collector))
        XCTAssertEqual(Achievement.collector.progress(stats: stats(nine))?.current, 9)
        let ten = stateWithSpecies(10)
        XCTAssertTrue(Achievements.earned(state: ten, stats: stats(ten)).contains(.collector))
        // 넘어선 뒤에도 진행 표시가 목표를 넘지 않는다(11/10 은 읽는 사람을 헷갈리게 한다).
        let twenty = stateWithSpecies(20)
        XCTAssertEqual(Achievement.collector.progress(stats: stats(twenty))?.current, 10)
    }

    func testBigSpenderUsesSpentTokens() async {
        var state = CompanionState()
        state.spentTokens = 4_999_999_999
        XCTAssertFalse(Achievements.earned(state: state, stats: stats(state)).contains(.bigSpender))
        state.spentTokens = 5_000_000_000
        XCTAssertTrue(Achievements.earned(state: state, stats: stats(state)).contains(.bigSpender))
    }

    /// 새로 달성한 것 = 달성했는데 아직 기록에 없는 것. 기록에 있으면 다시 "새로"가 아니다.
    func testNewlyEarnedIgnoresAlreadyAnnounced() async {
        var state = CompanionState()
        state.spentTokens = 5_000_000_000
        XCTAssertTrue(Achievements.newlyEarned(state: state, stats: stats(state)).contains(.bigSpender))
        state.earnedAchievements = [Achievement.bigSpender.rawValue]
        XCTAssertFalse(Achievements.newlyEarned(state: state, stats: stats(state)).contains(.bigSpender))
    }

    /// [회귀 — Codex 리뷰] **갓 시작한 세이브의 첫 업적이 삼켜지면 안 된다.**
    ///
    /// 예전 규칙은 "기록이 비었으면 시드"였는데 신규 사용자도 기록이 비어 있다 — 그래서 첫 업적이
    /// 조용히 사라졌다. 두 상태는 다르고, 이제 `achievementsSeeded` 로 구별한다.
    func testFirstAchievementOfANewSaveIsAnnounced() async {
        // 소급 시드를 이미 겪은 세이브(seeding=false)에서 첫 업적은 알려야 한다.
        XCTAssertEqual(Achievements.announcement(newly: [.namer], seeding: false), .namer)
        // 기능을 처음 보는 세이브에서만 조용하다.
        XCTAssertNil(Achievements.announcement(newly: [.namer], seeding: true))
    }

    /// [회귀 — Codex 리뷰] 일지가 잘려 근거가 사라져도 **이미 달성한 업적은 풀리지 않는다.**
    ///
    /// 판정이 일지 위의 질의라, 200개 상한을 넘긴 오래된 사용자는 "밤의 사람" 같은 업적이 조용히
    /// 잠겼다. 달성 취소는 사실의 변화가 아니라 기록의 유실이다.
    func testEarnedAchievementsSurviveChronicleEviction() async {
        var state = CompanionState()
        state.chronicle = [entry(.renamed)]
        let earnedBefore = Achievements.earned(state: state, stats: stats(state))
        XCTAssertTrue(earnedBefore.contains(.namer))

        // 기록해 둔 뒤 일지를 비운다 = 오래 써서 밀려난 상황.
        state.earnedAchievements = Set(earnedBefore.map(\.rawValue))
        state.chronicle = []
        XCTAssertTrue(Achievements.earned(state: state, stats: stats(state)).contains(.namer),
                      "근거가 밀려났다고 달성이 취소됐다")
    }

    /// 순서가 고정돼야 한다 — 화면을 열 때마다 목록이 뒤바뀌면 못 읽는다.
    func testOrderIsStable() async {
        var state = CompanionState()
        state.chronicle = [entry(.renamed), entry(.withdrawn, hour: 3)]
        let first = Achievements.earned(state: state, stats: stats(state))
        for _ in 0..<10 {
            XCTAssertEqual(Achievements.earned(state: state, stats: stats(state)), first)
        }
    }

    /// [핵심] **소급 달성분이 첫 실행에 알림 폭탄이 되면 안 된다.**
    ///
    /// 업적은 과거를 인정하므로, 오래 쓴 세이브는 이 기능을 처음 보는 순간 여러 개를 동시에 달성한다.
    /// 그때 전부 알리면 축하가 아니라 폭격이다. 첫 만남에서는 **조용히 기록만** 심고, 그 뒤부터 알린다
    /// (사탕 지급의 `candyFeatureSeeded` 와 같은 처리).
    /// 관측 가능한 계약: 첫 update 이후에는 "새로 달성한 것"이 남아 있지 않다.
    func testFirstRunSeedsQuietlyInsteadOfAnnouncingEverything() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ach-\(UUID().uuidString).json")
        // 이미 많은 일을 겪은 세이브 — 업적 기능은 처음 본다(earnedAchievements 없음).
        let dexEntry = "{\"baseID\":1,\"finalID\":2,\"chainOrder\":[1,2],\"rarity\":\"legendary\","
            + "\"isShiny\":true}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":9000000000,"
            + "\"spentTokens\":6000000000,\"lastDate\":\"d\",\"active\":null,"
            + "\"dex\":[\(dexEntry)]}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: AchievementNoProvider(), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 3))
        XCTAssertFalse(s.earnedAchievements.isEmpty, "소급 달성이 있어야 하는 세이브")
        XCTAssertTrue(s.state.earnedAchievements.isEmpty, "아직 아무것도 기록되지 않은 상태")

        s.update(todayTokensByProvider: ["t": 1], todayDate: "d", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)

        XCTAssertFalse(s.state.earnedAchievements.isEmpty, "첫 틱에 조용히 기록돼야 한다")
        XCTAssertTrue(Achievements.newlyEarned(state: s.state, stats: s.trainerStats).isEmpty,
                      "첫 틱 뒤에 '새로 달성'이 남아 있으면 다음 틱에 또 알린다")
    }

    /// 알림 판정 그 자체. 위 테스트는 **상태만** 보므로 폭탄 구현과 정상 구현을 구별하지 못한다
    /// (결함을 주입했더니 통과해서 알아냈다) — 알림은 설치본에서만 나가 테스트에서 관측할 수 없기
    /// 때문이다. 규칙을 순수 함수로 떼어 여기서 직접 확인한다.
    func testAnnouncementIsSilentWhileSeedingAndSingleAfterwards() async {
        let many: [Achievement] = [.firstHatch, .firstGraduate, .shinyFound, .legendaryRaised]
        XCTAssertNil(Achievements.announcement(newly: many, seeding: true),
                     "첫 만남에서는 소급분을 조용히 심어야 한다 — 여기서 알리면 알림 폭탄")
        XCTAssertEqual(Achievements.announcement(newly: many, seeding: false),
                       .firstHatch, "그 뒤로는 새로 달성한 것 중 하나만")
        XCTAssertNil(Achievements.announcement(newly: [], seeding: false),
                     "새로 달성한 게 없으면 알릴 것도 없다")
    }

    /// 모든 업적에 이름과 설명이 있어야 한다 — 빠지면 화면에 빈 줄이 남는다.
    func testEveryAchievementHasCopy() async {
        let l = L(.en)
        for a in Achievement.allCases {
            XCTAssertFalse(l.achievementName(a).isEmpty, "\(a) 이름 없음")
            XCTAssertFalse(l.achievementDetail(a).isEmpty, "\(a) 설명 없음")
        }
    }
}
