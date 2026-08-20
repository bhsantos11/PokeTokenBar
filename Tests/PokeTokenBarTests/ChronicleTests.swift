import XCTest
@testable import PokeTokenBar

// MARK: 일지(Chronicle) — 동행의 삶을 사건으로 기록하고 읽을 때 문장으로 만든다

private struct ChronicleNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class ChronicleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(url: URL? = nil) -> CompanionStore {
        let url = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("chron-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":1,"
            + "\"rarity\":\"common\",\"totalForms\":3}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":9000000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(mon)}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: ChronicleNoProvider(), clock: { self.now },
                              fileURL: url, rng: SeededRNG(seed: 11))
    }

    /// 하루의 구간 나누기. **경계마다** 확인한다 — 한 지점만 보면 off-by-one 을 못 잡는다.
    /// 자정~새벽은 "늦은 밤"으로 묶는다: 사람에게 새벽 2시는 다음 날 아침이 아니라 어젯밤의 연장이다.
    func testDayPartBoundaries() async {
        XCTAssertEqual(DayPart.of(hour: 0), .night)
        XCTAssertEqual(DayPart.of(hour: 4), .night)
        XCTAssertEqual(DayPart.of(hour: 5), .earlyMorning)
        XCTAssertEqual(DayPart.of(hour: 8), .earlyMorning)
        XCTAssertEqual(DayPart.of(hour: 9), .morning)
        XCTAssertEqual(DayPart.of(hour: 11), .morning)
        XCTAssertEqual(DayPart.of(hour: 12), .afternoon)
        XCTAssertEqual(DayPart.of(hour: 17), .afternoon)
        XCTAssertEqual(DayPart.of(hour: 18), .evening)
        XCTAssertEqual(DayPart.of(hour: 22), .evening)
        XCTAssertEqual(DayPart.of(hour: 23), .night)
        // 24시간 전체가 어딘가에 속해야 한다 — 빠진 시각이 있으면 문장이 안 나온다.
        for hour in 0..<24 { XCTAssertNotNil(DayPart.allCases.first { $0 == DayPart.of(hour: hour) }) }
    }

    /// 상한을 넘으면 **오래된 것부터** 버린다. 최신이 앞이라는 순서도 함께 고정한다.
    func testAppendingKeepsNewestAndCapsTheHistory() async {
        var entries: [ChronicleEntry] = []
        for i in 0..<(Chronicle.maxEntries + 25) {
            entries = Chronicle.appending(
                ChronicleEntry(at: now.addingTimeInterval(TimeInterval(i)), kind: .hatched,
                               speciesID: i), to: entries)
        }
        XCTAssertEqual(entries.count, Chronicle.maxEntries)
        XCTAssertEqual(entries.first?.speciesID, Chronicle.maxEntries + 24, "최신이 앞")
        XCTAssertEqual(entries.last?.speciesID, 25, "가장 오래된 25개가 버려져야 한다")
    }

    /// 모든 사건 종류가 문장을 갖는다 — 빠지면 그 사건은 일지에서 빈 줄이 된다.
    func testEveryEventKindRendersASentence() async {
        let l = L(.en)
        for kind in ChronicleEntry.Kind.allCases {   // 새 사건 종류가 늘면 여기서 먼저 걸린다
            let line = l.chronicleLine(kind, when: "one afternoon", name: "Sprout",
                                       to: "Ivysaur", shiny: false)
            XCTAssertFalse(line.isEmpty, "\(kind) 문장 없음")
            XCTAssertTrue(line.contains("Sprout"), "\(kind) 에 이름이 안 들어갔다")
        }
    }

    /// 이로치 부화는 다른 문장이어야 한다 — 같은 문장이면 그 순간의 특별함이 기록에 안 남는다.
    func testShinyHatchReadsDifferently() async {
        let l = L(.en)
        let plain = l.chronicleLine(.hatched, when: "one evening", name: "X", to: nil, shiny: false)
        let shiny = l.chronicleLine(.hatched, when: "one evening", name: "X", to: nil, shiny: true)
        XCTAssertNotEqual(plain, shiny)
        XCTAssertTrue(shiny.lowercased().contains("shiny"))
    }

    // MARK: 기록 지점

    /// 이름을 **붙이면** 기록되고, **지우면** 기록되지 않는다.
    /// 지운 것까지 남기면 일지가 "이름을 없앴어요"로 채워져 읽을 것이 못 된다.
    func testRenamingRecordsButClearingDoesNot() async {
        let s = store()
        s.setNickname("Sprout")
        XCTAssertEqual(s.chronicleEntries.filter { $0.kind == .renamed }.count, 1)
        s.setNickname("Sprout")   // 같은 이름 다시 = 변화 없음
        XCTAssertEqual(s.chronicleEntries.filter { $0.kind == .renamed }.count, 1, "변화 없는 저장은 사건이 아니다")
        s.setNickname(nil)
        XCTAssertEqual(s.chronicleEntries.filter { $0.kind == .renamed }.count, 1, "이름 삭제는 사건이 아니다")
    }

    /// 박스로 보내고 다시 꺼내는 것이 각각 기록된다 — 그때의 이름과 함께.
    func testBoxMovesAreRecordedWithTheNameAtTheTime() async {
        let s = store()
        s.setNickname("Sprout")
        XCTAssertTrue(s.buyFreshEgg())
        let boxed = s.chronicleEntries.first { $0.kind == .boxed }
        XCTAssertNotNil(boxed)
        XCTAssertEqual(boxed?.nickname, "Sprout", "그날의 이름이 남아야 한다")
        XCTAssertTrue(s.withdraw(at: 0))
        XCTAssertNotNil(s.chronicleEntries.first { $0.kind == .withdrawn })
    }

    /// 나중에 이름을 바꿔도 **과거 기록의 이름은 그대로다.** 일기는 그날의 사실을 담는다.
    func testPastEntriesKeepTheNameTheyWereWrittenWith() async {
        let s = store()
        s.setNickname("Sprout")
        XCTAssertTrue(s.buyFreshEgg())          // Sprout 이 박스로
        XCTAssertTrue(s.withdraw(at: 0))
        s.setNickname("Vine")                   // 이름 변경
        let boxed = s.chronicleEntries.first { $0.kind == .boxed }
        XCTAssertEqual(boxed?.nickname, "Sprout", "과거 기록이 새 이름으로 덮어써졌다")
    }

    /// [회귀] 일지는 디스크 왕복을 견뎌야 한다 — `CompanionState` 의 손수 쓴 디코더가 안 읽으면
    /// 저장은 "성공"하면서 다음 기동에 통째로 사라진다(박스·애칭과 같은 함정).
    func testChronicleSurvivesAReloadFromDisk() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chron-persist-\(UUID().uuidString).json")
        let s = store(url: url)
        s.setNickname("Sprout")
        XCTAssertFalse(s.chronicleEntries.isEmpty)

        let reloaded = CompanionStore(provider: ChronicleNoProvider(), clock: { self.now },
                                      fileURL: url, rng: SeededRNG(seed: 11))
        XCTAssertEqual(reloaded.chronicleEntries.count, s.chronicleEntries.count,
                       "재기동 후 일지가 사라졌다")
        XCTAssertEqual(reloaded.chronicleEntries.first?.nickname, "Sprout")
    }

    /// 외부 세이브의 일지도 경계에서 잘려야 한다 — 손편집이 수만 건을 넣으면 화면과 저장이 함께 무거워진다.
    func testImportedChronicleIsBounded() async {
        var state = CompanionState()
        state.chronicle = (0..<(Chronicle.maxEntries * 3)).map {
            ChronicleEntry(at: now.addingTimeInterval(TimeInterval($0)), kind: .hatched,
                           speciesID: 1, nickname: String(repeating: "가", count: 500))
        }
        let clean = SaveTransfer.sanitized(state)
        XCTAssertEqual(clean.chronicle.count, Chronicle.maxEntries)
        XCTAssertEqual(clean.chronicle.first?.nickname?.count, CompanionStore.nicknameMaxLength)
    }
}
