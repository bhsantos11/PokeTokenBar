import Foundation

/// 트레이너 카드에 실리는 수치 — 지금까지의 여정을 한 화면으로 요약한 것.
///
/// **순수 계산이다.** 상태와 사용량 합계만 받아 값을 내고 저장도 표시도 하지 않는다. 이렇게 두면
/// 화면 없이도 전부 테스트할 수 있고, macOS 가 나중에 같은 카드를 그릴 때 숫자가 갈라지지 않는다.
struct TrainerStats: Sendable, Equatable {
    /// 도감에 오른 종 수(졸업 기준) + 아직 키우는 중까지 합친 "본 적 있는" 종 수.
    var speciesGraduated: Int
    var speciesSeen: Int
    /// 이로치로 보유한 적 있는 종 수.
    var shinySpecies: Int
    /// 졸업시킨 개체 수 — 끝까지 키운 횟수.
    var graduations: Int
    /// 지금 데리고 다니는 개체 + 박스에 있는 개체.
    var inParty: Int
    var inBox: Int
    /// 설치 이후 누적 토큰(성장 미터의 분자)과 상점에서 쓴 토큰.
    var lifetimeTokens: Int
    var spentTokens: Int
    /// 첫 사건(대개 첫 부화)부터 오늘까지의 일수. 기록이 없으면 nil.
    var daysJourneyed: Int?
    /// 가장 많이 키운 종(졸업 기준). 동률이면 도감 번호가 작은 쪽.
    var favouriteSpeciesID: Int?
    /// 가장 희귀한 졸업 등급.
    var rarestGraduated: Rarity?
    /// 카드에 실을 대표 업적 — 가장 **최근에** 달성한 것이 아니라 목록상 마지막 것이다.
    /// 달성 시각을 저장하지 않기 때문이고(업적은 과거 기록 위의 질의라 시각이 없다), 목록 순서는
    /// `Achievement.allCases` 로 고정돼 있어 카드가 열 때마다 바뀌지 않는다.
    var highlightAchievement: Achievement?

    /// 도감 완성도(0…1) — 분모는 1~5세대 base 종 수가 아니라 **본 적 있는 종** 대비 졸업 종이다.
    /// 전체 종 수를 분모로 쓰면 649분의 5 같은 숫자가 나와 아무 의미가 없다.
    var completion: Double {
        speciesSeen > 0 ? Double(speciesGraduated) / Double(speciesSeen) : 0
    }
}

enum TrainerCard {
    /// 트레이너 이름 상한 — 애칭과 같은 이유(레이아웃 방어), 같은 기준(문자 수).
    static let nameMaxLength = 20

    /// 내보낸 카드의 파일명. 초 단위 시각이 들어가 **두 번 저장해도 첫 장을 덮어쓰지 않는다**
    /// (`SaveTransfer.suggestedFileName` 과 같은 이유·같은 형태). 로케일 독립 포맷을 쓰는 이유는
    /// 파일명이 사용자 언어에 따라 달라지면 정렬과 스크립트 처리가 깨지기 때문이다.
    static func exportFileName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "PokeTokenBar-Trainer-\(formatter.string(from: now)).png"
    }

    /// 업적까지 채운 통계. 업적 판정이 `TrainerStats` 를 필요로 해서 두 단계로 나뉜다 —
    /// 한 번에 하려면 서로를 참조하는 순환이 생긴다.
    static func fullStats(state: CompanionState, now: Date) -> TrainerStats {
        var s = stats(state: state, now: now)
        s.highlightAchievement = Achievements.earned(state: state, stats: s).last
        return s
    }

    static func stats(state: CompanionState, now: Date) -> TrainerStats {
        // 졸업 종: 영구 기록의 체인 전체가 "도달한" 종이다.
        var graduatedSpecies = Set<Int>()
        var shiny = Set<Int>()
        var finalCounts: [Int: Int] = [:]
        var rarest: Rarity?
        for entry in state.dex {
            for id in entry.chainOrder {
                graduatedSpecies.insert(id)
                if entry.isShiny { shiny.insert(id) }
            }
            finalCounts[entry.baseID, default: 0] += 1
            if let current = rarest {
                if entry.rarity.sortRank > current.sortRank { rarest = entry.rarity }
            } else {
                rarest = entry.rarity
            }
        }

        // 본 적 있는 종: 졸업분 + 아직 키우는 중인 개체들의 **도달분**(계획된 미래 단계는 제외).
        var seen = graduatedSpecies
        for mon in ([state.active].compactMap { $0 } + state.boxed) {
            for id in mon.pathIDs.prefix(mon.stageIndex + 1) {
                seen.insert(id)
                if mon.isShiny, mon.dittoDisguise == nil || mon.dittoRevealed { shiny.insert(id) }
            }
        }

        // 여정 길이는 일지의 가장 오래된 사건부터 — 설치일이 아니라 **첫 사건**이 시작이다.
        // 일지가 없는(구버전) 세이브는 nil 이고, 화면이 그 줄을 생략한다.
        let days = state.chronicle.map(\.at).min().map { start in
            max(0, Calendar.current.dateComponents([.day], from: start, to: now).day ?? 0)
        }

        let favourite = finalCounts.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }?.key

        return TrainerStats(
            speciesGraduated: graduatedSpecies.count,
            speciesSeen: seen.count,
            shinySpecies: shiny.count,
            graduations: state.dex.count,
            inParty: state.active == nil ? 0 : 1,
            inBox: state.boxed.count,
            lifetimeTokens: state.usedSinceInstall,
            spentTokens: state.spentTokens,
            daysJourneyed: days,
            favouriteSpeciesID: favourite,
            rarestGraduated: rarest,
            highlightAchievement: nil)
    }
}
