import XCTest
@testable import PokeTokenBar

/// 회귀 원점: Linux 팝오버의 상점 알 버튼이 **첫 클릭에 곧바로 `buyEgg`** 를 불러, 10시간 키운
/// 동행이 확인 한 번 없이 사라졌다(2026-08-19). 확인 사다리가 macOS 뷰 안에만 있었던 게 원인이라
/// 규칙을 `ActionConfirmPolicy` 로 내렸고, 여기서 그 규칙을 잠근다.
///
/// GTK 위젯 트리는 XCTest 로 못 만든다 — 그래서 테스트 대상은 뷰가 아니라 **뷰가 반드시 따라야 하는
/// 순수 규칙**이다. 뷰가 이 규칙을 안 읽고 자기 사다리를 다시 짜면 여전히 뚫린다는 한계는 남는다.
final class ActionConfirmPolicyTests: XCTestCase {

    /// 결함 그 자체 — 누를 수 있는 어떤 액션도 첫 클릭에서 커밋되면 안 된다.
    /// 상점의 모든 티어 × 이로치 여부, 가방의 모든 소모품을 전수로 돈다.
    func testNothingCommitsOnFirstClick() {
        for tier in FreshEgg.shopTiers {
            for shiny in [false, true] {
                XCTAssertFalse(
                    ActionConfirmPolicy.commitsOnFirstClick(buying: .egg(tier), currentIsShiny: shiny),
                    "egg tier=\(tier?.rawValue ?? "none") shiny=\(shiny) 가 확인 없이 커밋된다")
            }
        }
        for kind in ItemKind.allCases {
            for shiny in [false, true] {
                XCTAssertFalse(
                    ActionConfirmPolicy.commitsOnFirstClick(buying: .item(kind), currentIsShiny: shiny),
                    "item \(kind.rawValue) 구매가 확인 없이 커밋된다")
            }
            XCTAssertFalse(ActionConfirmPolicy.commitsOnFirstClick(using: kind),
                           "item \(kind.rawValue) 사용이 확인 없이 커밋된다")
        }
    }

    /// 알 리롤은 이로치든 아니든 **한 단계**다 — 박스(2026-08-19) 이후로 개체가 사라지지 않기 때문이다.
    ///
    /// 예전엔 이로치일 때 "정말 놓아줄까요?"를 한 번 더 물었다. 지금 그 문구는 거짓이다: 이로치는
    /// 박스에서 그대로 기다린다. 없는 위험을 경고하면 **진짜 위험한 곳에서 그 경고의 무게가 사라진다.**
    /// 지출(1B~4B)에 대한 확인 한 단계는 남는다.
    func testEggRerollAsksOnceRegardlessOfShiny() {
        for tier in FreshEgg.shopTiers {
            for shiny in [false, true] {
                XCTAssertEqual(ActionConfirmPolicy.steps(buying: .egg(tier), currentIsShiny: shiny),
                               [.confirm],
                               "박스로 가는데 단계가 더 붙었다 (tier=\(tier?.rawValue ?? "none") shiny=\(shiny))")
            }
        }
    }

    /// 아이템 구매는 이로치 여부와 무관 — 잃는 개체가 없으니 경고 단계가 붙으면 안 된다.
    func testItemPurchaseNeverGetsTheShinyWarning() {
        for kind in ItemKind.allCases {
            XCTAssertEqual(ActionConfirmPolicy.steps(buying: .item(kind), currentIsShiny: true), [.confirm])
        }
    }

    /// 보유형(이로치 부적)은 누를 버튼 자체가 없다 → 물어볼 것도 없다. 여기에 단계를 만들면
    /// 팝오버가 그리지 않는 프롬프트를 기다리는 상태가 생긴다.
    func testPassiveItemsHaveNothingToConfirm() {
        for kind in ItemKind.allCases where kind.isPassive {
            XCTAssertTrue(ActionConfirmPolicy.steps(using: kind).isEmpty)
            XCTAssertFalse(ActionConfirmPolicy.commitsOnFirstClick(using: kind))
        }
        for kind in ItemKind.allCases where !kind.isPassive {
            XCTAssertEqual(ActionConfirmPolicy.steps(using: kind), [.confirm])
        }
    }

    /// 되돌릴 수 없는 손실은 **이제 어디에도 없다** — 박스가 마지막 하나(알 구매)를 없앴다.
    /// 팝오버가 destructive 스타일(빨간 버튼)을 어디에 칠할지 이 답을 쓰므로, true 로 남으면
    /// 되돌릴 수 있는 동작이 위험해 보인다.
    func testNothingInTheShopDiscardsTheCompanion() {
        for tier in FreshEgg.shopTiers {
            XCTAssertFalse(ActionConfirmPolicy.discardsCompanion(.egg(tier)),
                           "알 구매는 박스로 보낼 뿐이라 파괴가 아니다")
        }
        for kind in ItemKind.allCases {
            XCTAssertFalse(ActionConfirmPolicy.discardsCompanion(.item(kind)))
        }
    }
}
