import Foundation

/// 마지막으로 패널을 연 뒤로 무슨 일이 있었는가.
///
/// 일지(`chronicle`)가 이미 전부 기록하고 있으므로 **새 카운터를 만들지 않는다** — 세어 둔 값과
/// 기록이 어긋나는 순간 어느 쪽이 맞는지 알 수 없게 되기 때문이다(업적과 같은 이유).
/// 여기서는 "언제 이후"만 정하고 나머지는 질의다.
struct AwaySummary: Sendable, Equatable {
    var hatched = 0
    var evolved = 0
    var graduated = 0
    var shinies = 0
    /// 가장 중요한 사건 하나 — 요약을 한 줄로 줄일 때 무엇을 남길지.
    var headline: ChronicleEntry?

    var isEmpty: Bool { hatched == 0 && evolved == 0 && graduated == 0 }
}

enum Away {
    /// 이 시각 이후의 사건만 센다. `since` 가 nil(처음 여는 경우)이면 **아무것도 세지 않는다** —
    /// 첫 실행에서 지난 몇 달을 "당신이 없는 동안"으로 요약하면 그건 요약이 아니라 전체 이력이다.
    static func summary(chronicle: [ChronicleEntry], since: Date?) -> AwaySummary {
        guard let since else { return AwaySummary() }
        let recent = chronicle.filter { $0.at > since }
        var summary = AwaySummary()
        for entry in recent {
            switch entry.kind {
            case .hatched:   summary.hatched += 1
            case .evolved:   summary.evolved += 1
            case .graduated: summary.graduated += 1
            default:         break
            }
            if entry.isShiny, entry.kind == .hatched { summary.shinies += 1 }
        }
        // 중요도 순으로 대표 사건을 고른다: 이로치 부화 > 졸업 > 진화 > 부화.
        // `chronicle` 은 최신이 앞이므로 같은 등급이면 가장 최근 것이 잡힌다.
        summary.headline = recent.first { $0.kind == .hatched && $0.isShiny }
            ?? recent.first { $0.kind == .graduated }
            ?? recent.first { $0.kind == .evolved }
            ?? recent.first { $0.kind == .hatched }
        return summary
    }
}
