import Foundation

/// 동행의 일지 한 줄.
///
/// **문장이 아니라 사건을 저장한다.** 렌더된 문장을 저장하면 언어를 바꿨을 때 과거가 옛 언어로 굳고,
/// 문구를 고쳐도 지난 기록은 영영 옛 문구로 남는다. 여기엔 무슨 일이 있었는지만 담고, 문장은 읽는
/// 시점에 `ChronicleCopy` 가 만든다.
struct ChronicleEntry: Codable, Sendable, Identifiable, Equatable {
    var id = UUID().uuidString
    var at: Date
    var kind: Kind
    /// 사건의 주인공 종. 진화면 진화 **전** 종.
    var speciesID: Int?
    /// 진화 후 종(진화 사건에만).
    var toSpeciesID: Int?
    /// 그때 붙어 있던 애칭. 나중에 이름을 바꿔도 그날의 기록은 그날의 이름으로 남는다.
    var nickname: String?
    var rarity: Rarity?
    var isShiny = false

    enum Kind: String, Codable, Sendable, CaseIterable {
        case hatched, evolved, graduated, boxed, withdrawn, renamed, dittoRevealed
    }
}

/// 하루 중 언제였는지 — 일지가 로그가 아니라 일기처럼 읽히게 하는 장치.
///
/// `Date` 가 아니라 **시(hour) 정수**를 받는다. 시간대·달력 해석은 호출부(로컬 캘린더)가 하고,
/// 여기는 순수하게 남는다 — 테스트가 실행 환경의 시간대를 전제하지 않게 하는 기존 규칙과 같다.
enum DayPart: String, Sendable, CaseIterable {
    case earlyMorning, morning, afternoon, evening, night

    static func of(hour: Int) -> DayPart {
        switch hour {
        case 0..<5:   return .night          // 자정~새벽 5시: 아직 "어젯밤"의 연장
        case 5..<9:   return .earlyMorning
        case 9..<12:  return .morning
        case 12..<18: return .afternoon
        case 18..<23: return .evening
        default:      return .night
        }
    }
}

enum Chronicle {
    /// 보관 상한. 오래된 것부터 버린다.
    ///
    /// 상한이 필요한 이유는 두 가지다: 세이브 파일이 무한히 자라지 않게, 그리고 화면이 몇 년치 목록을
    /// 그리지 않게. 200은 몇 달치 사건을 담기에 넉넉하면서 세이브를 수십 KB 안에 둔다.
    static let maxEntries = 200

    /// 새 사건을 앞에 붙이고 상한을 적용한다. 순수 — 저장·시계는 호출부가 다룬다.
    static func appending(_ entry: ChronicleEntry, to entries: [ChronicleEntry]) -> [ChronicleEntry] {
        Array(([entry] + entries).prefix(maxEntries))
    }
}
