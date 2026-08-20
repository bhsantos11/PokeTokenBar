import Foundation

/// 활성 5시간 블록 안에서의 위치 → 동행의 하루 리듬.
///
/// 블록은 **로컬 사용량 로그에서 계산된다**(`LocalUsageReader.activeBlock`) — 한도 API 가 아니다.
/// 이게 이 기능의 핵심 전제다: 공식 한도 엔드포인트는 429 로 자주 죽고(2026-08-18~19 에만 94회),
/// 그때 `isLimitWarning` 이 항상 false 가 되어 **`.tired` 가 도달 불가능해진다.** 로그는 언제나
/// 읽히므로, 리듬을 로그에 걸면 네트워크가 어떻든 동행은 계속 살아 있다.
enum CircadianPhase: String, Sendable, CaseIterable {
    /// 활성 블록 없음 = 5시간 넘게 조용했다. 사람이 자리를 비운 것이고, 동행도 잔다.
    case asleep
    /// 블록 초반 — 막 일을 시작했다.
    case fresh
    /// 블록 중반.
    case steady
    /// 블록 후반 — 이 작업 구간이 곧 끝난다.
    case winding
}

enum Circadian {
    /// 블록 길이. `LocalUsageReader.blockWindow` 와 같은 값이어야 한다 — 블록의 끝 시각은 그쪽이
    /// 정하고(`start + blockWindow`), 여기서는 그 창 안의 **위치**만 계산한다.
    static let windowSeconds: TimeInterval = 5 * 60 * 60

    /// 경계. 초반 1/3 은 fresh, 마지막 1/5 는 winding, 나머지는 steady.
    static let freshUntil = 1.0 / 3.0
    static let windingFrom = 0.8

    /// 블록 안에서의 진행도(0…1). 블록이 없으면 nil.
    ///
    /// 끝을 넘긴 블록에는 1 을 돌려주지 않고 **nil** 을 준다. 블록이 끝났다는 건 그 작업 구간이
    /// 끝났다는 뜻이고, 그건 "거의 다 왔다"가 아니라 "자리를 비웠다"에 가깝다. 1 로 뭉개면 새로고침
    /// 사이에 잠깐 stale 해진 블록이 영원히 `winding` 으로 굳는다.
    static func progress(block: BlockUsage?, now: Date) -> Double? {
        guard let block, let start = block.startDate else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < windowSeconds else { return nil }
        return elapsed / windowSeconds
    }

    static func phase(block: BlockUsage?, now: Date) -> CircadianPhase {
        guard let p = progress(block: block, now: now) else { return .asleep }
        if p < freshUntil { return .fresh }
        if p < windingFrom { return .steady }
        return .winding
    }
}
