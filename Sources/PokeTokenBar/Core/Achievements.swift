import Foundation

/// 업적 — 지금까지의 여정에서 **이미 일어난 일**로만 판정한다.
///
/// 별도의 카운터를 새로 들고 다니지 않는 것이 설계의 핵심이다. 일지(`chronicle`)와 도감이 이미
/// 무슨 일이 있었는지 알고 있으므로, 업적은 그 위의 순수 질의다. 카운터를 따로 두면 두 진실이
/// 생기고(집계와 기록), 어긋나는 순간 어느 쪽이 맞는지 알 수 없게 된다.
///
/// 그래서 **소급 적용된다**: 이 기능이 생기기 전에 이로치를 부화시킨 사람도 즉시 그 업적을 갖는다.
/// 과거를 인정하지 않는 업적은 오래 쓴 사람에게 벌을 주는 셈이다.
enum Achievement: String, Sendable, CaseIterable {
    case firstHatch, firstGraduate, shinyFound, legendaryRaised
    case nightOwl, earlyBird
    case collector, dedicated
    case secondChance, namer, transformed, bigSpender

    /// 달성 여부. 순수 — 상태와 "지금"만 본다.
    func isEarned(state: CompanionState, stats: TrainerStats) -> Bool {
        // 한 번 달성한 업적은 **다시 잠기지 않는다.**
        //
        // 판정은 일지 위의 질의인데 일지는 200개에서 오래된 것부터 버려진다. 그래서 오래 쓰면
        // "밤의 사람"·"이름을 지어"처럼 근거가 옛 기록에만 있는 업적이 조용히 풀렸다 — 달성을
        // 되돌리는 건 기록의 유실이지 사실의 변화가 아니다. 기록된 것은 그대로 인정한다.
        if state.earnedAchievements.contains(rawValue) { return true }
        switch self {
        case .firstHatch:
            return state.chronicle.contains { $0.kind == .hatched } || stats.speciesSeen > 0
        case .firstGraduate:
            return stats.graduations >= 1
        case .shinyFound:
            return stats.shinySpecies >= 1
        case .legendaryRaised:
            return state.dex.contains { $0.rarity == .legendary }
        case .nightOwl:
            return state.chronicle.contains { Self.dayPart($0) == .night }
        case .earlyBird:
            return state.chronicle.contains { Self.dayPart($0) == .earlyMorning }
        case .collector:
            return stats.speciesSeen >= 10
        case .dedicated:
            return stats.graduations >= 5
        case .secondChance:
            return state.chronicle.contains { $0.kind == .withdrawn }
        case .namer:
            return state.chronicle.contains { $0.kind == .renamed }
        case .transformed:
            return state.chronicle.contains { $0.kind == .dittoRevealed }
        case .bigSpender:
            return state.spentTokens >= 5_000_000_000
        }
    }

    /// 진행도가 의미 있는 업적의 (현재, 목표). 없으면 nil — 단발성 사건은 진행 막대가 무의미하다.
    func progress(stats: TrainerStats) -> (current: Int, target: Int)? {
        switch self {
        case .collector: return (min(stats.speciesSeen, 10), 10)
        case .dedicated: return (min(stats.graduations, 5), 5)
        default: return nil
        }
    }

    /// 기록된 지역 시각을 우선 쓰고, 없을 때만(구버전 기록) 현재 달력으로 추정한다.
    /// 여기서 추정을 하는 이상 그 판정은 시간대에 따라 달라질 수 있다 — 새 기록에는 해당 없다.
    private static func dayPart(_ entry: ChronicleEntry) -> DayPart {
        DayPart.of(hour: entry.hour ?? Calendar.current.component(.hour, from: entry.at))
    }
}

enum Achievements {
    /// 지금 달성한 것 전부. 순서는 `allCases` 로 고정 — 화면이 열 때마다 달라지지 않게.
    static func earned(state: CompanionState, stats: TrainerStats) -> [Achievement] {
        Achievement.allCases.filter { $0.isEarned(state: state, stats: stats) }
    }

    /// 아직 못 얻은 것.
    static func locked(state: CompanionState, stats: TrainerStats) -> [Achievement] {
        Achievement.allCases.filter { !$0.isEarned(state: state, stats: stats) }
    }

    /// **새로** 달성한 것 = 지금 달성했는데 기록에 없던 것.
    ///
    /// 축하 연출을 한 번만 띄우기 위한 판정이라, 호출부가 결과를 상태에 적어야 다음에 안 뜬다.
    /// (사탕 지급과 같은 엣지 트리거 구조 — 그쪽에서 배운 대로 판정과 부수효과를 분리해 둔다.)
    static func newlyEarned(state: CompanionState, stats: TrainerStats) -> [Achievement] {
        earned(state: state, stats: stats).filter { !state.earnedAchievements.contains($0.rawValue) }
    }

    /// 무엇을 **알릴지** — 아무것도 안 알릴 때는 nil.
    ///
    /// 순수 함수로 떼어 놓은 이유: 알림 자체는 설치본에서만 나가고 테스트에서는 컴파일 아웃되므로,
    /// 스토어 안에 규칙을 두면 "폭탄을 쏘는 구현"과 "안 쏘는 구현"이 테스트에서 **구별되지 않는다**.
    /// 실제로 그렇게 만들었다가 결함을 주입해도 테스트가 통과하는 것을 보고 여기로 옮겼다.
    ///
    /// 규칙: 기록이 비어 있으면(이 기능을 처음 보는 세이브) 소급 달성분이 한꺼번에 쏟아지므로 조용히
    /// 심기만 한다. 그 뒤부터는 새로 달성한 것 중 하나를 알린다 — 여러 개가 동시에 달성돼도 알림은
    /// 하나다(축하가 목적이지 목록 낭독이 목적이 아니다).
    /// - Parameter seeding: 이 세이브가 업적 기능을 **처음 보는** 순간인가.
    ///
    /// 기존에는 "기록이 비었으면 시드"로 판단했는데, 갓 시작한 세이브도 기록이 비어 있다 —
    /// 그래서 신규 사용자의 **첫 업적이 통째로 삼켜졌다**. 두 상태는 다른 것이므로 따로 전달한다.
    static func announcement(newly: [Achievement], seeding: Bool) -> Achievement? {
        guard !seeding else { return nil }
        return newly.first
    }
}
