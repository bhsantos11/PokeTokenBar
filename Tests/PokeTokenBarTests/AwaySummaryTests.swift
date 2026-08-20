import XCTest
@testable import PokeTokenBar

// MARK: 없는 동안 있었던 일 — 일지 위의 순수 질의

private struct AwayNoProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class AwaySummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 최신이 앞이라는 일지의 순서를 그대로 쓴다.
    private func entries(_ specs: [(ChronicleEntry.Kind, Double, Bool)]) -> [ChronicleEntry] {
        specs.map { kind, agoHours, shiny in
            ChronicleEntry(at: now.addingTimeInterval(-agoHours * 3600), kind: kind,
                           speciesID: 1, isShiny: shiny, hour: 12)
        }
    }

    /// **처음 여는 경우엔 아무것도 요약하지 않는다.** 기준점이 없다고 전체 이력을 "그동안 있었던 일"로
    /// 부르면 그건 요약이 아니라 이력이고, 첫 실행이 몇 달치 사건으로 뒤덮인다.
    func testNoSummaryWithoutAReferencePoint() async {
        let all = entries([(.hatched, 1, false), (.evolved, 2, false)])
        XCTAssertTrue(Away.summary(chronicle: all, since: nil).isEmpty)
    }

    /// 기준 시각 **이후**만 센다 — 경계 양쪽을 각각 확인한다.
    func testCountsOnlyEventsAfterTheReferencePoint() async {
        let all = entries([(.hatched, 1, false), (.evolved, 5, false), (.graduated, 10, false)])
        let summary = Away.summary(chronicle: all, since: now.addingTimeInterval(-6 * 3600))
        XCTAssertEqual(summary.hatched, 1)
        XCTAssertEqual(summary.evolved, 1)
        XCTAssertEqual(summary.graduated, 0, "기준보다 오래된 사건은 세지 않는다")
    }

    /// 아무 일도 없었으면 비어 있다 — 화면이 "아무 일도 없었어요" 카드를 그리지 않게.
    func testEmptyWhenNothingHappened() async {
        let all = entries([(.hatched, 10, false)])
        XCTAssertTrue(Away.summary(chronicle: all, since: now.addingTimeInterval(-3600)).isEmpty)
    }

    /// 이름 바꾸기·박스 이동은 "그동안 있었던 일"이 아니다 — 사용자가 직접 한 일이라 놓칠 수 없다.
    func testUserActionsAreNotCountedAsMissedEvents() async {
        let all = entries([(.renamed, 1, false), (.boxed, 1, false), (.withdrawn, 1, false)])
        XCTAssertTrue(Away.summary(chronicle: all, since: now.addingTimeInterval(-3600)).isEmpty)
    }

    /// 이로치 부화는 따로 센다 — 숫자만으로도 그날의 특별함이 드러나야 한다.
    func testShinyHatchesAreCountedSeparately() async {
        let all = entries([(.hatched, 1, true), (.hatched, 2, false)])
        let summary = Away.summary(chronicle: all, since: now.addingTimeInterval(-6 * 3600))
        XCTAssertEqual(summary.hatched, 2)
        XCTAssertEqual(summary.shinies, 1)
    }

    /// 대표 사건은 **중요도 순**이다: 이로치 부화 > 졸업 > 진화 > 부화.
    /// 최신순으로만 고르면 방금 일어난 평범한 진화가 어제의 이로치를 가린다.
    func testHeadlinePrefersTheMostNotableEvent() async {
        let all = entries([(.evolved, 1, false), (.graduated, 2, false), (.hatched, 3, true)])
        let since = now.addingTimeInterval(-6 * 3600)
        XCTAssertEqual(Away.summary(chronicle: all, since: since).headline?.kind, .hatched,
                       "이로치 부화가 최우선")

        let noShiny = entries([(.evolved, 1, false), (.graduated, 2, false)])
        XCTAssertEqual(Away.summary(chronicle: noShiny, since: since).headline?.kind, .graduated)

        let onlyEvolve = entries([(.evolved, 1, false), (.hatched, 2, false)])
        XCTAssertEqual(Away.summary(chronicle: onlyEvolve, since: since).headline?.kind, .evolved)
    }

    /// [핵심] 패널을 열면 **요약을 먼저 확정하고** 기준점을 옮긴다. 순서가 뒤집히면 여는 순간
    /// 방금 놓친 사건이 전부 기준점 이전이 되어 항상 "아무 일도 없었음"이 된다.
    func testOpeningFreezesTheSummaryBeforeMovingTheReferencePoint() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-\(UUID().uuidString).json")
        let past = now.addingTimeInterval(-86_400).timeIntervalSinceReferenceDate
        let event = now.addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        let entry = "{\"id\":\"e1\",\"at\":\(event),\"kind\":\"evolved\",\"speciesID\":1,"
            + "\"toSpeciesID\":2,\"isShiny\":false,\"hour\":12}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":1000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":null,\"lastOpenedAt\":\(past),\"chronicle\":[\(entry)]}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: AwayNoProvider(), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 2))

        s.markPanelOpened()
        XCTAssertEqual(s.awaySummary.evolved, 1, "여는 순간의 요약이 비어 있다 — 순서가 뒤집혔다")

        // 두 번째로 열면 같은 사건이 다시 요약되면 안 된다(기준점이 옮겨졌으므로).
        s.markPanelOpened()
        XCTAssertTrue(s.awaySummary.isEmpty, "같은 사건이 두 번 요약됐다")
    }

    /// 0인 항목은 문장에서 빠진다 — "부화 0" 같은 말을 만들지 않는다.
    func testZeroCountsAreOmittedFromTheSentence() async {
        let l = L(.en)
        let line = l.awayCounts(hatched: 0, evolved: 2, graduated: 0, shinies: 0)
        XCTAssertFalse(line.contains("0"))
        XCTAssertTrue(line.contains("2"))
    }
}
