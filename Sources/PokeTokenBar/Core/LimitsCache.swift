import Foundation

/// 마지막으로 성공한 한도 조회를 디스크에 남겨 **재기동을 건너 살아남게** 한다.
///
/// 없으면: 한도는 메모리에만 있으므로 429 백오프 창(이 계정에서 흔하다 — 2026-08-18~19 에 94회)과
/// 재기동이 겹치면 카드에 **아무 값도 없다.** "일시 제한 중, 재시도합니다"를 보여 주는 것보다
/// 어제의 숫자를 '갱신 지연'으로 보여 주는 편이 낫다 — 사용자가 알고 싶은 건 대략 얼마나 남았나이지
/// 네트워크 상태가 아니다.
///
/// 캐시는 **표시 전용**이다. 되살린 값으로 사탕 지급이나 경고 판정을 하면 안 된다(그건 엣지 트리거라
/// 과거 값으로 다시 발화하면 중복 지급이 된다). `limitsUpdatedAt` 이 함께 복원되므로 기존
/// `claudeLimitsStale` 경로가 자동으로 "오래된 값"으로 표시한다.
struct CachedLimits: Codable, Sendable {
    var fetchedAt: Date
    var status: LimitStatus
    /// `LimitStatus.CodingKeys` 에 없어 인코딩에서 빠지는 주입 필드 — 별도로 싣고 복원 때 되꽂는다.
    /// 안 그러면 되살린 카드에서 플랜 표시("Max 20x")만 조용히 사라진다.
    var subscriptionType: String?
    var rateLimitTier: String?

    /// 되살릴 때 주입 필드를 합쳐 원래 모양으로 되돌린다.
    var restored: LimitStatus {
        var s = status
        s.subscriptionType = subscriptionType
        s.rateLimitTier = rateLimitTier
        return s
    }
}

enum LimitsCache {
    static let fileName = "limits-cache.json"

    /// 너무 오래된 캐시는 안 쓴다. 일주일 지난 사용률은 정보가 아니라 오해다 — 주간 창이 이미 여러 번
    /// 리셋됐을 시간이라, '갱신 지연' 딱지를 달아도 읽는 사람을 잘못된 판단으로 이끈다.
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func save(_ cached: CachedLimits, to directory: URL) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// 디스크의 캐시. 없음·손상·유효기간 초과는 모두 nil — 값이 없는 것과 못 믿는 것을 구분하지 않는다.
    static func load(from directory: URL, now: Date) -> CachedLimits? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let cached = try? JSONDecoder().decode(CachedLimits.self, from: data) else { return nil }
        let age = now.timeIntervalSince(cached.fetchedAt)
        guard age >= 0, age <= maxAge else { return nil }
        return cached
    }
}
