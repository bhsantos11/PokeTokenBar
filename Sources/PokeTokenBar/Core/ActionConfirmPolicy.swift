import Foundation

/// 상점 구매·가방 사용이 커밋되기 전에 통과해야 하는 확인 단계.
///
/// 규칙을 Core 에 두는 이유는 **프론트엔드가 둘**이기 때문이다. macOS 팝오버는 이 사다리를 SwiftUI
/// `@State` 로, GTK 패널은 저장된 `pendingConfirm` 으로 만든다. 규칙이 뷰 안에만 있었을 때 Linux
/// 포트는 확인 단계를 통째로 빠뜨린 채 나갔고, 알 구매 버튼 한 번에 10시간 키운 동행이 사라졌다
/// (2026-08-19). 뷰마다 다시 구현하는 한 같은 부류가 또 난다 — 사다리는 여기 한 곳에만 있다.
///
/// macOS 뷰(`ShopView`/`BagView`)는 아직 같은 사다리를 손으로 들고 있다. 맥에서 빌드·검증할 수 있을
/// 때 이 타입으로 옮긴다 — 그때까지는 `ActionConfirmPolicyTests` 가 두 구현이 같은 답을 내는지 잠근다.
enum ActionConfirmPolicy {
    /// 한 단계 = 사용자가 한 번 더 눌러야 하는 프롬프트.
    enum Step: Equatable, Sendable {
        case confirm        // "X 를 놓아주고 Y 로 바꿀까요?" / "X 를 살까요?" / "X 에게 쓸까요?"
        case shinyWarning   // "⚠️ 이로치예요! 정말 놓아줄까요?" — 되돌릴 수 없는 손실이라 한 단계 더
    }

    /// 상점 구매의 확인 사다리. 알은 활성 포켓몬을 폐기하므로 이로치면 한 단계가 더 붙는다.
    /// 아이템 구매는 토큰만 쓰고 잃는 게 없어 한 단계.
    static func steps(buying entry: ShopEntry, currentIsShiny: Bool) -> [Step] {
        switch entry {
        case .item:
            return [.confirm]
        case .egg:
            // 알 구매는 더 이상 개체를 파괴하지 않는다(박스로 간다) → 이로치 경고 단계는 **거짓말**이 됐다.
            // 되돌릴 수 없는 손실이 없는 곳에 "정말 놓아줄까요?"를 남겨 두면 진짜 위험한 곳에서 그 경고가
            // 갖는 무게가 사라진다. 지출(1B~4B)은 여전히 한 번 묻는다.
            return [.confirm]
        }
    }

    /// 가방 사용의 확인 사다리. 보유형(이로치 부적)은 누를 것 자체가 없어 빈 배열.
    static func steps(using kind: ItemKind) -> [Step] {
        kind.isPassive ? [] : [.confirm]
    }

    /// 되돌릴 수 없는 손실을 동반하는가 — **이제 어디에도 없다.**
    ///
    /// 박스(2026-08-19) 이전에는 알 구매가 활성 개체를 영구 폐기했고 도감에도 안 남았다. 지금은
    /// `buyEgg` 가 개체를 박스에 넣으므로 되돌릴 수 있다. 이 판정은 UI 의 destructive 스타일(빨간 버튼)이
    /// 읽는 값이라, true 로 남겨 두면 안전한 동작이 위험해 **보인다**.
    /// 타입을 지우지 않고 남기는 이유: 되돌릴 수 없는 동작이 다시 생기면 여기가 붙일 자리다.
    static func discardsCompanion(_ entry: ShopEntry) -> Bool { false }

    /// **누를 수 있는 모든 액션은 첫 클릭에서 커밋되지 않는다.** 회귀가 난 바로 그 불변식 —
    /// 버튼이 그려지는 액션(보유형 제외)은 확인 단계가 최소 하나 있어야 한다.
    static func commitsOnFirstClick(buying entry: ShopEntry, currentIsShiny: Bool) -> Bool {
        steps(buying: entry, currentIsShiny: currentIsShiny).isEmpty
    }

    static func commitsOnFirstClick(using kind: ItemKind) -> Bool {
        !kind.isPassive && steps(using: kind).isEmpty
    }
}
