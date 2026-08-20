import Foundation
import Observation

/// 게임 상태의 출처. 설치 이후 토큰 사용량으로 포켓몬을 진화시키고, 최종체 + 추가 임계 도달 시
/// 도감(라인 전체)에 보존 + 새 알. 진화 트리/희귀도/이름은 PokeProviding 으로 런타임 주입.
@MainActor
@Observable
final class CompanionStore {
    private(set) var state = CompanionState()
    private(set) var displayState: CompanionStateKind = .egg
    private(set) var currentLine: EvoLine?
    private(set) var isHatching = false
    private var isRevealingDitto = false   // 메타몽 리빌 비동기 중복 방지(isHatching 자매)
    private(set) var justEvolvedTo: String?     // 이름(연출/문구)
    private(set) var justGraduated: String?
    private var eventUntil: Date?

    /// 부화/진화 연출 트리거 — seq 증가로 UI 가 감지, 팝오버가 닫혀 있었어도 다음 오픈에 1회 재생.
    enum Celebration: Equatable { case hatch(shiny: Bool), evolve, dittoReveal(shiny: Bool) }
    private(set) var celebration: Celebration?
    private(set) var celebrationSeq = 0
    private func fireCelebration(_ c: Celebration) {
        celebration = c
        celebrationSeq += 1
        onCompanionEvent?()
    }

    /// Something visibly happened to the companion — hatch, evolution, Ditto reveal, graduation.
    ///
    /// The Linux app repaints on its usage poll, which is every two minutes by default. That covers
    /// events that happen *during* a poll, but not the ones that land between them: an evolution
    /// triggered when the evolution line finally downloads, or a Ditto reveal completing after its
    /// own fetch. Those left the panel showing the previous form under a full progress bar until the
    /// next poll happened along. The frontends set this to repaint immediately.
    var onCompanionEvent: (() -> Void)?
    /// 연출 재생 후 UI 가 호출(1회성 보장).
    func consumeCelebration() { celebration = nil }

    /// 사탕 사용 시 "+XP" 순간 표시 — 진화 없이 부분 진행일 때도 피드백. seq 증가로 CompanionHeader 감지.
    private(set) var candyFeedbackSeq = 0
    private(set) var candyFeedbackAmount = 0
    /// "+XP" 표시 1회성 보장 — CompanionHeader 가 재생 후 호출한다. 소비하지 않으면 다른 탭에 갔다
    /// 홈으로 재진입할 때(CompanionHeader 재마운트) @State 가 초기화돼 같은 값이 다시 떠오른다(회귀).
    func consumeCandyFeedback() { candyFeedbackAmount = 0 }

    /// 민트 사용 시 "성격이 X로" 순간 표시 — 사탕 피드백과 동일 1회성 패턴(seq + consume).
    private(set) var mintFeedbackSeq = 0
    private(set) var mintFeedbackNature: PokemonNature?
    func consumeMintFeedback() { mintFeedbackNature = nil }

    private let provider: any PokeProviding
    private let clock: () -> Date
    private let fileURL: URL
    private var rng: any RandomNumberGenerator
    private let dittoDisguiseRollingEnabled: Bool
    /// 세션 내 활성 개체 교체 감지용. await 뒤 이전 개체의 결과가 새 개체를 덮지 않게 한다.
    /// 활성 개체 세대. 비동기 작업(부화·라인 로드·메타몽 리빌)은 await 전에 이 값을 캡처하고 돌아와서
    /// 다시 비교해, 다르면 자기 결과를 버린다. 읽기를 열어 둔 이유는 **박스 교대가 이 값을 올린다는
    /// 계약을 테스트가 확인해야 하기 때문**이다 — 안 올리면 날아오던 응답이 방금 꺼낸 개체를 덮어쓴다.
    private(set) var activeGeneration = 0

    init(provider: any PokeProviding = PokeAPIClient.shared,
         clock: @escaping () -> Date = Date.init,
         fileURL: URL? = nil,
         rng: any RandomNumberGenerator = SystemRandomNumberGenerator(),
         dittoDisguiseRollingEnabled: Bool = AppEnv.isProductionInstall) {
        self.provider = provider
        self.clock = clock
        self.fileURL = fileURL ?? Self.defaultURL()
        self.rng = rng
        self.dittoDisguiseRollingEnabled = dittoDisguiseRollingEnabled
        load()
        if state.active != nil { displayState = .idle }
    }

    static func defaultURL() -> URL {
        // 상태 파일 위치. 기본은 Application Support/PokeTokenBar. `PTB_STATE_DIR` 환경변수가 있으면
        // 그 디렉토리를 쓴다 — 개발/QA 격리용(실제 companion 상태를 건드리지 않고 데모 상태로 실행).
        // 프로덕션은 이 변수가 없어 무영향.
        // 공백만 있는 값은 무시(URL(fileURLWithPath:)가 CWD 상대경로로 해석되는 것 방지).
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir: URL
        if !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = PlatformPaths.appDirectory()
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("companion-state.json")
    }

    // MARK: 파생값 (UI)

    var language: AppLanguage { state.language }
    func setLanguage(_ lang: AppLanguage) {
        state.language = lang
        resolvedSpeciesNames = [:]   // 이전 언어로 확인한 이름이 남으면 화면이 두 언어로 섞인다
        save()
    }
    /// 앱 전체 UI 문자열 — language 변경 시 자동 재렌더.
    var l: L { L(language) }

    /// The one-line mood text under the companion.
    ///
    /// Lives here rather than in a view because both frontends show it, and the mapping from state
    /// to sentence is a product decision, not a layout one — duplicating it is how the two
    /// platforms end up disagreeing about what the same state says.
    var statusLine: String {
        switch displayState {
        case .egg:     return l.statusEgg
        case .idle:    return l.statusIdle
        case .working: return l.statusWorking
        case .focus:   return l.statusFocus
        case .tired:   return l.statusTired
        case .sleep:   return l.statusSleep
        case .levelUp: return justEvolvedTo.map { l.statusEvolved($0) } ?? l.statusGrew
        }
    }

    var hasActive: Bool { state.active != nil }
    var rarity: Rarity? { state.active?.rarity }
    var currentIsShiny: Bool { state.active.map(Self.displayShiny) ?? false }

    /// 개체의 **표시용** 이로치 여부 — 위장 중인 메타몽은 리빌 전까지 숨긴다.
    /// 활성 전용이던 판정을 개체 단위로 올린 이유: 박스 화면이 `isShiny` 를 직접 읽으면 위장한 메타몽의
    /// 정체를 리빌 전에 흘려 연출이 통째로 죽는다. 판정은 여기 한 곳만 본다.
    static func displayShiny(_ mon: MonState) -> Bool {
        if mon.dittoDisguise != nil && !mon.dittoRevealed { return false }
        return mon.isShiny
    }
    var currentNature: PokemonNature? { state.active?.nature }

    // 알 인큐베이션 (active 없을 때)
    var isEgg: Bool { state.active == nil }
    var eggStarted: Bool { state.eggUsage > 0 }
    var eggProgress: Double { min(1, max(0, Double(state.eggUsage) / Double(PokemonBalance.eggHatchThreshold))) }
    var eggTokensToHatch: Int { max(0, PokemonBalance.eggHatchThreshold - state.eggUsage) }

    var displayName: String {
        guard let a = state.active else { return "Token Egg" }
        if let nickname = a.nickname, !nickname.isEmpty { return nickname }
        // 라인이 아직 안 왔으면(재기동 직후·오프라인) 종 번호로라도 보여 준다. 예전엔 "Token Egg" 로
        // 떨어져서, 스프라이트는 포켓몬인데 이름만 알이라 화면이 스스로 모순됐다.
        guard let line = currentLine else { return "#\(a.currentID)" }
        return line.localizedName(a.currentID, state.language)
    }

    /// 종 이름(애칭 무시) — 이름 바꾸기 화면이 "원래 이름"을 보여 줄 때 쓴다.
    var speciesDisplayName: String {
        guard let a = state.active else { return "Token Egg" }
        guard let line = currentLine else { return "#\(a.currentID)" }
        return line.localizedName(a.currentID, state.language)
    }

    /// 애칭 설정 — 공백만 있거나 비우면 해제(종 이름으로 되돌아간다).
    /// 길이 상한은 레이아웃 방어다: 400pt 패널에 임의 길이 문자열이 들어오면 카드가 통째로 늘어난다.
    /// 자르는 기준은 문자 수(`count`)다 — 바이트로 자르면 한글·이모지가 반토막 난다.
    @discardableResult
    func setNickname(_ raw: String?) -> Bool {
        guard state.active != nil else { return false }
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.nicknameMaxLength))
        let changed = newName != state.active!.nickname
        state.active!.nickname = newName
        // 이름을 지운 것은 사건이 아니다 — 일지에 "이름을 없앴어요"가 남으면 읽는 재미가 없다.
        if changed, newName != nil { chronicle(.renamed, mon: state.active) }
        save()
        return true
    }

    /// 애칭 길이 상한(문자 수). `nonisolated` 인 이유: 세이브 정규화(`SaveTransfer.sanitized`)가
    /// MainActor 밖에서 같은 상한을 써야 하고, 두 벌로 두면 한쪽만 바뀌어 갈라진다.
    nonisolated static let nicknameMaxLength = 24

    // MARK: 일지 기록

    /// 사건 하나를 일지에 남긴다. **저장은 호출부가 이미 하는 save() 에 맡긴다** — 여기서 또 쓰면
    /// 한 사건에 디스크 쓰기가 두 번 난다.
    private func chronicle(_ kind: ChronicleEntry.Kind, mon: MonState?, to: Int? = nil) {
        let at = clock()
        let entry = ChronicleEntry(at: at, kind: kind,
                                   speciesID: mon?.currentID, toSpeciesID: to,
                                   nickname: mon?.nickname, rarity: mon?.rarity,
                                   isShiny: mon.map(Self.displayShiny) ?? false,
                                   hour: Calendar.current.component(.hour, from: at))
        state.chronicle = Chronicle.appending(entry, to: state.chronicle)
        // 여정의 시작은 **첫 사건이 일어난 날**이고, 그 뒤로 움직이지 않는다. 일지에서 매번 계산하면
        // 상한(200)이 시작점을 밀어내는 순간 여정이 짧아진다 — 오래 쓸수록 신참이 되는 셈이다.
        // Stamping `at` here would reset an established journey to day zero on the first event
        // after upgrading, because a save from before this field has no start recorded. Take the
        // oldest event still on record instead — the entry just prepended is included, so a genuinely
        // new save gets `at` anyway.
        if state.journeyStartedAt == nil {
            state.journeyStartedAt = state.chronicle.map(\.at).min() ?? at
        }
    }

    var chronicleEntries: [ChronicleEntry] { state.chronicle }

    // MARK: 없는 동안 있었던 일

    /// 화면에 보여 줄 요약. `markPanelOpened()` 가 기준점을 옮기기 전에 읽어야 한다.
    private(set) var awaySummary = AwaySummary()

    /// 패널이 열렸다 — 요약을 확정하고 기준점을 지금으로 옮긴다.
    ///
    /// 요약을 **먼저 확정**하는 순서가 중요하다. 기준점을 먼저 옮기면 방금 놓친 사건들이 요약에서
    /// 사라져, 여는 순간 항상 "아무 일도 없었음"이 된다.
    func markPanelOpened() {
        awaySummary = Away.summary(chronicle: state.chronicle, since: state.lastOpenedAt)
        state.lastOpenedAt = clock()
        save()
    }

    /// 패널이 닫혔다 — 여기서부터가 다음 "없는 동안"이다.
    ///
    /// 열 때만 기준점을 옮기면 **패널이 열려 있는 동안 일어난 일까지 다음에 "그동안 있었던 일"로
    /// 보고된다.** 눈앞에서 진화하는 걸 보고 닫았는데 다시 열면 "당신이 없는 동안 1마리 진화"가 뜬다.
    func markPanelClosed() {
        state.lastOpenedAt = clock()
        save()
    }

    // MARK: 트레이너 카드

    var trainerName: String? { state.trainerName }
    var trainerStats: TrainerStats { TrainerCard.fullStats(state: state, now: clock()) }

    var earnedAchievements: [Achievement] { Achievements.earned(state: state, stats: trainerStats) }
    var lockedAchievements: [Achievement] { Achievements.locked(state: state, stats: trainerStats) }
    /// 업적 판정에 쓰이는 "이미 달성한 것" 집합 — 화면과 같은 값을 쓰도록 노출한다.
    var recordedAchievements: Set<String> { state.earnedAchievements }
    func achievementProgress(_ a: Achievement) -> (current: Int, target: Int)? {
        a.progress(stats: trainerStats)
    }

    /// 새로 달성한 업적을 한 번만 알린다. `update()` 가 매 틱 부른다.
    ///
    /// 소급 적용이라 **첫 실행에서 과거분이 한꺼번에 달성된다** — 그때 알림을 12개 쏘면 축하가 아니라
    /// 폭격이다. 그래서 기록이 비어 있으면(이 기능을 처음 보는 세이브) 알림 없이 기록만 심는다.
    /// 사탕 지급의 `candyFeatureSeeded` 와 같은 처리다.
    private func announceNewAchievements() {
        let stats = trainerStats
        let newly = Achievements.newlyEarned(state: state, stats: stats)
        // 첫 시드는 한 번만 일어난다 — 이후에는 달성한 게 없어도 플래그가 서 있어야 하므로
        // `newly` 가 비어도 여기서 빠져나가지 않는다.
        let seeding = !state.achievementsSeeded
        state.achievementsSeeded = true
        guard !newly.isEmpty else { return }
        // 알릴 대상 판정은 `Achievements.announcement` 가 한다 — 알림은 설치본에서만 나가므로
        // 규칙을 여기 두면 테스트가 폭탄 구현과 정상 구현을 구별하지 못한다.
        let announced = Achievements.announcement(newly: newly, seeding: seeding)
        state.earnedAchievements.formUnion(newly.map(\.rawValue))
        guard let announced else { return }
        notifyCompanionEvent(l.achievementsTitle, l.achievementName(announced))
    }

    /// 트레이너 이름 설정. 비우면 해제 — 애칭과 같은 규칙을 쓴다(공백만도 해제, 문자 수로 자름).
    func setTrainerName(_ raw: String?) {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        state.trainerName = trimmed.isEmpty ? nil : String(trimmed.prefix(TrainerCard.nameMaxLength))
        save()
    }

    /// 일지 표시용 한 줄 — 사건 + 그날의 시각 + 그때의 이름으로 문장을 만든다.
    func chronicleLine(_ entry: ChronicleEntry) -> String {
        // 기록된 시각을 쓰고, 없을 때만(구버전 기록) 현재 달력으로 추정한다.
        let hour = entry.hour ?? Calendar.current.component(.hour, from: entry.at)
        let when = l.dayPart(DayPart.of(hour: hour))
        let name = entry.nickname ?? entry.speciesID.map(speciesName) ?? l.dexIndividualUnnamed
        return l.chronicleLine(entry.kind, when: when, name: name,
                               to: entry.toSpeciesID.map(speciesName), shiny: entry.isShiny)
    }

    /// 종 번호 → 이름(알고 있으면). 활성 라인 → 도감 저장분 → 세션 캐시 → 번호 순으로 본다.
    func speciesName(_ id: Int) -> String {
        if let line = currentLine, let name = line.names[id],
           let resolved = state.language.resolveName(name) { return resolved }
        for entry in state.dex {
            if let names = entry.names?[id], let resolved = state.language.resolveName(names) {
                return resolved
            }
        }
        return resolvedSpeciesNames[id] ?? "#\(id)"
    }

    // MARK: 쓰다듬기 (클릭 반응)

    /// 마지막 쓰다듬기 반응. 뷰가 말풍선으로 띄운다. **창이 지나면 읽는 즉시 nil** 이다.
    ///
    /// 저장값을 그대로 돌려주면 `update()` 가 정리해 줄 때까지(기본 2분) 화면에 남는다 — 3초 창이라고
    /// 적어 두고 실제로는 2분이었다. 판정을 읽기 시점으로 옮기면 무엇이 다시 그리든 시간이 맞는다.
    var petReaction: String? {
        guard let until = petReactionUntil, clock() < until else { return nil }
        return storedPetReaction
    }
    private var storedPetReaction: String?
    /// 반응이 **갱신됐다**는 신호. 같은 문장이 연속으로 뽑혀도 뷰가 새 반응임을 알 수 있게 한다
    /// (문자열 비교로 판단하면 같은 말이 두 번 나올 때 두 번째가 안 보인다).
    private(set) var petReactionSeq = 0
    private var petReactionUntil: Date?

    /// 반응이 화면에 남는 시간. 부화·진화 연출(4~6초)보다 짧게 — 쓰다듬기는 가벼운 상호작용이라
    /// 축하 연출을 밀어내면 안 된다.
    static let petReactionWindow: TimeInterval = 3

    /// 동행을 쓰다듬는다. 게임 상태는 **아무것도** 바꾸지 않는다 — 성장도, 재화도, 확률도.
    /// 클릭으로 이득이 생기면 그 순간 클릭은 상호작용이 아니라 노동이 된다.
    @discardableResult
    func pet() -> String {
        let line = FloatingPetCopy.tapReaction(state: displayState, name: displayName,
                                               roll: rng.next(), l: l)
        storedPetReaction = line
        petReactionSeq += 1
        petReactionUntil = clock().addingTimeInterval(Self.petReactionWindow)
        return line
    }

    var currentSpeciesID: Int? { state.active?.currentID }
    var isFinalStage: Bool {
        guard let a = state.active, let line = currentLine else { return false }
        return line.tree.node(withID: a.currentID)?.children.isEmpty ?? true
    }
    var stageText: String {
        guard let a = state.active else { return "" }
        return isFinalStage ? l.finalForm : l.stage(a.stageIndex + 1, a.totalForms)
    }
    var threshold: Int {
        guard let a = state.active else { return 1 }
        return PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: a.stageIndex)
    }
    var progress: Double {
        guard let a = state.active, threshold > 0 else { return 0 }
        return min(1, max(0, Double(a.usedAtStage) / Double(threshold)))
    }
    /// 다음 단계까지 남은 **실제 토큰**.
    ///
    /// `usedAtStage` 는 성격 배율이 이미 적용된 값이라 그 차이를 그대로 보여 주면 거짓말이 된다:
    /// 느린 성격(0.9배)은 "100M 남음"이라 적어 두고 실제로는 111M 을 써야 한다. 화면이 약속하는
    /// 단위는 사용자가 실제로 쓰는 토큰이므로, 여기서 배율을 되돌린다.
    var tokensToNext: Int {
        guard let a = state.active else { return 0 }
        let remainingXP = max(0, threshold - a.usedAtStage)
        let multiplier = a.nature?.growthMultiplier ?? 1.0
        return multiplier == 1.0 ? remainingXP : Int((Double(remainingXP) / multiplier).rounded())
    }

    /// 진화 라인 표시용: 실현된 경로 + 다음 단계 미리보기.
    /// 유일하게 이어지는 단계 뒤에 분기가 있으면, 그 확정 접두어와 하나의 미지 항목을 함께 보여 준다.
    /// 분기 후보는 부화 시 계획됐더라도 실제 진화 전까지 하나의 미지 항목으로 숨긴다.
    var lineNodes: [EvoLineItem] {
        guard let a = state.active, let line = currentLine else { return [] }
        var out = Self.realizedLineItems(pathIDs: a.pathIDs, stageIndex: a.stageIndex)
        if let current = line.tree.node(withID: a.currentID) {
            var node = current
            var guaranteedPrefix: [EvoNode] = []
            while node.children.count == 1, let child = node.children.first {
                guaranteedPrefix.append(child)
                node = child
            }

            if node.children.count > 1 {
                out += guaranteedPrefix.map { EvoLineItem(.species($0.speciesID), .future) }
                out.append(EvoLineItem(.mystery, .future))
            } else {
                out += guaranteedPrefix.map { EvoLineItem(.species($0.speciesID), .future) }
            }
        }
        return out
    }

    static func realizedLineItems(pathIDs: [Int], stageIndex: Int) -> [EvoLineItem] {
        pathIDs.enumerated().map { i, id in
            EvoLineItem(.species(id), i == stageIndex ? .current : .done)
        }
    }
    /// 도감에는 영구 보존된 졸업 개체와 현재 키우는 포켓몬을 함께 표시한다.
    /// 현재 개체는 영속 dex 에 중복 저장하지 않고 화면용 항목으로 합성한다. 졸업 시 active 가 사라지고
    /// 같은 개체의 영구 DexEntry 가 추가되므로 목록 개수는 그대로 유지된다.
    private var activeDexEntry: DexEntry? {
        state.active.map { raisingDexEntry($0, id: "active-\($0.baseID)-\($0.currentID)", line: currentLine) }
    }

    /// 박스에 든 개체들의 화면용 항목.
    ///
    /// 없으면 **박스에 넣는 순간 보유 종이 화면에서 사라진다** — 도감은 졸업분과 활성만 합성해 왔기
    /// 때문이다. 개체를 잃지 않으려고 만든 기능이 "도감에서 사라짐"으로 보이면 같은 불안을 준다.
    /// id 에 인덱스를 넣는 이유는 같은 종을 여러 마리 넣어 둘 수 있어서다(종만으론 키가 겹친다).
    /// 라인은 로딩돼 있지 않으므로 이름은 없고, 포획 로그가 행 단위로 조회해 채운다(구버전 항목과 같은 경로).
    private var boxedDexEntries: [DexEntry] {
        state.boxed.enumerated().map { index, mon in
            raisingDexEntry(mon, id: "boxed-\(index)-\(mon.baseID)-\(mon.currentID)", line: nil)
        }
    }

    /// 아직 키우는 중인 개체(활성·박스)의 화면용 도감 항목. 두 곳이 갈라지지 않게 한 곳에서 만든다.
    private func raisingDexEntry(_ mon: MonState, id: String, line: EvoLine?) -> DexEntry {
        DexEntry(
            id: id,
            nickname: mon.nickname,
            baseID: mon.baseID,
            finalID: mon.currentID,
            chainOrder: mon.pathIDs,
            rarity: mon.rarity,
            caughtAt: nil,
            isShiny: Self.displayShiny(mon),   // 위장 메타몽은 리빌 전까지 이로치를 숨긴다(판정 단일 소스)
            nature: mon.nature,
            names: line.map { l in
                Dictionary(uniqueKeysWithValues:
                    mon.pathIDs.compactMap { id in l.names[id].map { (id, $0) } })
            }
        )
    }

    var dexEntries: [DexEntry] {
        state.dex + boxedDexEntries + (activeDexEntry.map { [$0] } ?? [])
    }

    /// 합성된 현재 포켓몬 항목인지 판별한다. caughtAt 이 없는 구버전 졸업 항목과 혼동하지 않는다.
    func isActiveDexEntry(_ entry: DexEntry) -> Bool {
        entry.id == activeDexEntry?.id
    }

    /// 아직 **키우는 중**인 개체의 합성 항목인가 — 활성이거나 박스에 든 것. 포획 로그의 "키우는 중"
    /// 표식이 읽는 값이다.
    ///
    /// `isActiveDexEntry` 만 쓰면 박스 개체가 **졸업한 영구 기록처럼** 보인다. 실제로는 아직 안 끝난
    /// 개체라, 로그에서 둘을 구별 못 하면 "졸업한 줄 알았는데 아니었다"가 된다.
    /// 합성 항목은 `caughtAt == nil` 이지만 그것만으로는 판별할 수 없다 — 이름 없던 구버전 졸업 항목도
    /// `caughtAt` 이 없다(`dexEntriesSorted` 주석 참조). 그래서 id 접두사로 판별한다.
    func isRaisingDexEntry(_ entry: DexEntry) -> Bool {
        entry.id == activeDexEntry?.id || entry.id.hasPrefix("boxed-")
    }

    /// 포획 로그 표시 순서 — 현재 키우는 포켓몬을 맨 앞에 고정하고, 졸업 항목은 **기록 시각 최신순**.
    ///
    /// 과거에는 희귀도 내림차순이 먼저였다(종 단위 도감의 규칙). 로그는 시간순 기록이라 희귀도로
    /// 먼저 묶으면 방금 졸업한 개체가 며칠 전에 잡은 상위 희귀도 밑에 묻힌다. 희귀도로 좁히는 일은
    /// 이제 필터 캡슐과 도감이 담당한다.
    ///
    /// caughtAt 이 없는 구버전 항목은 .distantPast 로 묶여 맨 뒤에 온다(그들끼리의 순서는 미정).
    var dexEntriesSorted: [DexEntry] {
        let graduated = state.dex.sorted {
            ($0.caughtAt ?? .distantPast) > ($1.caughtAt ?? .distantPast)
        }
        // 지금 키우는 것들이 먼저 — 활성, 그다음 박스, 그다음 졸업분. 박스는 아직 진행 중인 개체라
        // 시간순 졸업 기록 사이에 섞으면(caughtAt 이 없어 맨 뒤로 간다) 찾을 수 없게 된다.
        return (activeDexEntry.map { [$0] } ?? []) + boxedDexEntries + graduated
    }

    /// 희귀도별 포획 로그 개수(요약 헤더용) — 개체 수 기준. 도감(종 단위)은 dexSpecies 를 쓴다.
    func dexCount(_ rarity: Rarity) -> Int { dexEntries.lazy.filter { $0.rarity == rarity }.count }

    /// 도감 한 칸 — 종 1개로 접힌 수집 기록. 같은 라인을 여러 번 키워도 종은 한 칸이다.
    /// **종 정보만 담는다** — 성격·획득 횟수처럼 개체에 딸린 것은 포획 로그가 개체 단위로 보여준다.
    struct DexSpecies: Identifiable, Sendable {
        let id: Int                     // speciesID = 도감 번호(정렬 키)
        let name: String
        let rarity: Rarity
        let isShiny: Bool               // 이 종을 이로치로 보유한 적이 있는가
        /// 이 칸의 근거가 **지금 키우는 개체뿐**이다 — 졸업 기록이 없어 아직 확정이 아니다.
        /// 알을 새로 사면 개체가 폐기되고(dex 미변경) 이 칸은 사라지며, 메타몽이 리빌하면 위장했던
        /// 종이 빠진다. 영구 기록과 같은 모양으로 두면 종 수가 줄어드는 게 결함으로 보이므로 뷰가 표식을 단다.
        let isRaising: Bool
    }

    /// 종 하나가 모으는 것 — 누적 전용. 병렬 딕셔너리를 여러 개 두면 키 집합이 서로 어긋날 수 있고
    /// (한쪽에만 써서 그 종이 조용히 사라지거나), 읽는 쪽에 도달 불가한 기본값이 생긴다. 하나로 묶어
    /// 두 여지를 함께 없앤다.
    private struct DexAccumulator {
        /// 첫 발견 때 확정 — 같은 종은 항상 같은 base 라인에서 오므로 갱신할 값이 없다.
        let rarity: Rarity
        var names: [String: String]?
        var isShiny = false
        /// 졸업 기록에서 온 적이 있는가 — 한 번이라도 true 면 이 종은 영구 보존분이라 사라지지 않는다.
        /// 같은 라인을 다시 키우는 중이어도(현재 개체와 겹쳐도) 표식 대상이 아니다.
        var isGraduated = false
    }

    /// 도감 목록 — 보유 종만, 도감 번호 오름차순.
    ///
    /// 포함 종 = 졸업분 `chainOrder` ∪ 현재 개체의 **도달분** `pathIDs[0...stageIndex]`.
    /// `plannedPathIDs`(사전 선택된 전체 경로)는 미도달 단계를 포함하므로 절대 쓰지 않는다 — 쓰면
    /// 아직 진화하지 않은 종이 보유로 잡힌다.
    var dexSpecies: [DexSpecies] {
        // 종별 누적을 한 번에 훑는다(뷰가 body 에서 1회 소비 — 메모이즈 없이 충분).
        var acc: [Int: DexAccumulator] = [:]
        for entry in state.dex {
            for id in entry.chainOrder {
                var a = acc[id] ?? DexAccumulator(rarity: entry.rarity)
                if let n = entry.names?[id] { a.names = n }   // 이름 없는 구버전 항목이 덮어쓰지 않게
                if entry.isShiny { a.isShiny = true }
                a.isGraduated = true
                acc[id] = a
            }
        }
        // 활성과 박스는 같은 규칙이다 — 둘 다 "아직 키우는 중"이라 종은 보유로 잡히고 졸업 표식은 안 붙는다.
        // 박스를 빼면 넣는 순간 그 종이 격자에서 사라진다(졸업 기록이 따로 없는 한).
        for mon in ([state.active].compactMap { $0 } + state.boxed) {
            // 도달분만 — stageIndex 가 pathIDs 범위 안임은 두 입구가 보장한다:
            // MonState.init(from:) 의 clamp, 그리고 SaveTransfer 의 가져오기 정규화.
            for id in mon.pathIDs.prefix(mon.stageIndex + 1) {
                var a = acc[id] ?? DexAccumulator(rarity: mon.rarity)
                // 이름은 로딩된 라인이 있을 때만 — 박스 개체는 라인이 없어 기존 값(졸업분)을 유지한다.
                if mon.baseID == state.active?.baseID, let n = currentLine?.names[id] { a.names = n }
                if Self.displayShiny(mon) { a.isShiny = true }   // 위장 중 숨김 규칙 재사용
                acc[id] = a
            }
        }
        return acc.sorted { $0.key < $1.key }.map { id, a in
            DexSpecies(
                id: id,
                name: a.names.flatMap { state.language.resolveName($0) }
                    ?? resolvedSpeciesNames[id] ?? "#\(id)",
                rarity: a.rarity,
                isShiny: a.isShiny,
                isRaising: !a.isGraduated)
        }
    }

    /// 이름이 없는 구버전 졸업 항목의 체인 이름을 채운다(도감 격자 진입 시 1회).
    ///
    /// 격자는 저장된 이름만 읽으므로 백필이 없으면 칸이 종 번호(`#41`)로 남는다. 포획 로그는 행이
    /// 뜰 때 행 단위로 같은 일을 해 왔지만, 로그를 한 번도 안 열면 격자는 계속 번호다.
    /// 라인 조회는 `PokeAPIClient` 가 base 단위로 캐시하므로 같은 라인이 여러 항목이어도 네트워크는 1회.
    /// 오프라인이면 `dexResolveChainNames` 가 저장 없이 폴백만 돌려주므로 다음 진입에서 다시 시도한다.
    func backfillMissingDexNames() async {
        for entry in state.dex where entry.names == nil {
            _ = await dexResolveChainNames(entry)   // 성공분만 내부에서 state.dex 에 저장
        }
    }

    /// 도감 항목 진화 체인 각 종의 이름(speciesID → 현재 언어 이름). 저장돼 있으면 즉시(네트워크 0),
    /// 없으면 nil(뷰가 async 조회로 폴백).
    func dexStoredChainNames(_ entry: DexEntry) -> [Int: String]? {
        guard let names = entry.names, !names.isEmpty else { return nil }
        return names.compactMapValues { state.language.resolveName($0) }
    }

    /// 이름 미저장(구버전) 항목용 — line 을 1회 조회해 체인 전 종의 다국어 이름을 얻고 항목에 백필한다
    /// (다음부터 네트워크 0). 저장돼 있으면 그대로(fetch 없음). 오프라인이면 종 번호(#id)로 폴백.
    /// 반환은 chainOrder 전 종을 채운 [speciesID: 현재 언어 이름].
    /// 이번 세션에 조회로 확인한 종 이름(speciesID → 현재 언어 이름).
    ///
    /// 박스 개체는 저장된 이름이 없다 — 라인은 활성 개체만 로딩하고, `MonState` 에는 이름 필드가
    /// 없기 때문이다. 그래서 도감 격자와 박스가 종 번호(`#25`)를 그대로 보여 줬다. 어차피 포획 로그가
    /// 라인을 조회하므로, 그 결과를 여기 모아 두면 추가 네트워크 없이 두 화면이 이름을 되찾는다.
    /// 영속하지 않는다 — 언어를 바꾸면 통째로 다시 조회하는 편이 잘못된 언어로 굳는 것보다 낫다.
    private(set) var resolvedSpeciesNames: [Int: String] = [:]

    func dexResolveChainNames(_ entry: DexEntry) async -> [Int: String] {
        if let stored = dexStoredChainNames(entry) { return stored }
        guard let line = try? await provider.line(baseSpeciesID: entry.baseID) else {
            return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { ($0, "#\($0)") })
        }
        let chainNames = Dictionary(uniqueKeysWithValues:
            entry.chainOrder.compactMap { id in line.names[id].map { (id, $0) } })
        if !chainNames.isEmpty, let idx = state.dex.firstIndex(where: { $0.id == entry.id }) {
            state.dex[idx].names = chainNames   // 백필 저장
            save()
        }
        // 확인된 이름만 세션 캐시에 모은다("#25" 같은 폴백은 담지 않는다 — 담으면 그 번호가 굳는다).
        for (id, names) in chainNames {
            if let resolved = state.language.resolveName(names) { resolvedSpeciesNames[id] = resolved }
        }
        return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { id in
            (id, chainNames[id].flatMap { state.language.resolveName($0) } ?? "#\(id)")
        })
    }

    // MARK: 갱신 (AppDelegate 가 UsageStore 값으로 호출)

    /// `circadian` 이 **nil 이면 "이 프론트엔드는 아직 리듬을 안 넘긴다"** 는 뜻이고, 그 호출부는
    /// 종전 동작 그대로다(macOS 델리게이트가 여기 해당한다 — 이 기기에서 빌드·검증할 수 없다).
    /// `.steady` 를 기본값으로 두지 않는 이유: 그러면 "안 넘긴 호출부"와 "정말 중간 구간"이 같은
    /// 값이 되어, 날짜 기반 규칙을 언제 꺼야 하는지 판단할 수 없다.
    func update(todayTokensByProvider: [String: Int], todayDate: String, monthTotal: Int,
                burnTier: BurnTier, limitWarning: Bool, hasUsageData: Bool,
                circadian: CircadianPhase? = nil) {
        let todayTokens = todayTokensByProvider.values.reduce(0, +)
        // `hasUsageData`는 표시용 snapshot 존재 여부이고, 이 map은 오늘 날짜가 확인된
        // provider 데이터만 담는다. stale snapshot이나 today == nil carrier만 있는 refresh는
        // ledger의 기준점을 움직일 수 있는 관측으로 취급하지 않는다.
        let hasCurrentProviderData = hasUsageData && !todayTokensByProvider.isEmpty
        if !state.installBaselineSet {
            // 설치 기준선 — 실제 데이터가 도착한 시점의 today 를 baseline 으로(이전 사용량 미카운트).
            // 데이터 도착 전(기동 직후 빈 새로고침)에는 잡지 않는다.
            guard hasCurrentProviderData else {
                // 세이브 불러오기가 baseline 판정을 이 경로에 넘겼을 수 있다(SaveTransfer.rebasedForThisDevice).
                // 그 경우 개체는 이미 들어와 있으므로 알로 표시하면 안 되고, 진화 라인 로드도 계속 재시도해야
                // 한다 — 새 Mac 은 AI CLI 를 처음 쓸 때까지 hasUsageData 가 false 라 여기서 막히면 그날 내내
                // 알로 보인다(재시작해도 동일).
                displayState = state.active == nil ? .egg : .idle
                kickLineLoadIfNeeded()
                return
            }
            state.installBaselineSet = true
            state.claimedTodayTokensByProvider = todayTokensByProvider
            state.lastDate = todayDate
            save()
        } else {
            // `today == nil` carrier만 남거나 파싱이 실패한 refresh는 현재 map이 비어 있을 수
            // 있다. 그런 관측으로 날짜·ledger를 움직이면 다음 정상 snapshot을 당일 전체 신규
            // 사용량으로 오인할 수 있으므로, 유효한 사용량이 있는 refresh만 ledger를 갱신한다.
            if hasCurrentProviderData {
                let dateChanged = todayDate != state.lastDate
                if state.claimedTodayTokensByProvider == nil {
                    // 구버전 세이브에는 aggregate high-water mark만 있어 프로바이더별로 분해할 수 없다.
                    // 첫 유효 관측을 새 장부의 기준점으로만 저장해 과거 사용량을 소급 지급하지 않는다.
                    state.claimedTodayTokensByProvider = todayTokensByProvider
                    state.lastDate = todayDate
                    AppLog.write("companion provider ledger seeded date=\(todayDate) providers=\(todayTokensByProvider.keys.sorted().joined(separator: ","))")
                } else if dateChanged {
                    // 일자별 snapshot은 서로 비교할 수 없다. 새 날짜에는 이전 날짜의 ledger를
                    // 기준으로 삼지 않고, 현재 날짜의 누적값 전체를 새 날짜 사용량으로 적립한다.
                    // 단, 위의 nil migration 경로는 구버전 aggregate를 분해할 수 없으므로 seed만 한다.
                    //
                    // 이전 날짜에 이미 알려진 provider가 첫 새로고침에서 빠질 수 있다(오늘 데이터
                    // 없음, stale 응답, 일시 실패). 그 provider를 아예 ledger에서 제거하면 같은
                    // 날짜에 복구될 때 현재 누적값을 "이미 적립한 값"으로 seed해 사용량이 누락된다.
                    // 이전 날짜의 숫자는 비교에 사용할 수 없으므로, 알려진 provider의 새 날짜 기준을
                    // 0으로 열어 둔다. 이후 복구된 현재 날짜 값은 그 날짜의 실제 사용량으로 적립되고,
                    // 같은 날짜의 부분 응답에서는 이 기준을 그대로 보존한다.
                    state.lastDate = todayDate
                    var newLedger = Dictionary(uniqueKeysWithValues:
                        state.claimedTodayTokensByProvider!.keys.map { ($0, 0) })
                    for (providerID, current) in todayTokensByProvider {
                        newLedger[providerID] = current
                    }
                    state.claimedTodayTokensByProvider = newLedger
                    let delta = todayTokensByProvider.values.reduce(0, +)
                    if delta > 0 {
                        state.usedSinceInstall += delta
                        if state.active == nil {
                            state.eggUsage += delta
                        } else {
                            applyUsage(delta)
                        }
                    }
                } else {
                    var ledger = state.claimedTodayTokensByProvider ?? [:]
                    var delta = 0
                    for (providerID, current) in todayTokensByProvider {
                        guard let previous = ledger[providerID] else {
                            // 새로 관측된 프로바이더의 과거 로그를 소급하지 않는다. 이후 refresh부터
                            // 해당 프로바이더의 증가분을 추적할 수 있도록 현재 값을 seed한다.
                            ledger[providerID] = current
                            continue
                        }
                        if current < previous {
                            // 전체 합계가 아니라 해당 프로바이더의 line만 rebase한다. 다른 프로바이더가
                            // 이번 refresh에서 보고하지 않았거나 carrier snapshot만 남은 경우에는 map에
                            // line 자체가 없으므로 기존 기준값을 건드리지 않는다.
                            ledger[providerID] = current
                            AppLog.write("companion usage regression provider=\(providerID) date=\(todayDate) previous=\(previous) current=\(current) drop=\(previous - current) — rebased provider ledger")
                            continue
                        }
                        delta += current - previous
                        ledger[providerID] = current
                    }
                    state.claimedTodayTokensByProvider = ledger
                    if delta > 0 {
                        state.usedSinceInstall += delta
                        if state.active == nil {
                            state.eggUsage += delta   // 알 인큐베이션 누적
                        } else {
                            applyUsage(delta)
                        }
                    }
                }
            }
        }
        announceNewAchievements()
        // 쓰다듬기 반응 만료 — 이벤트 창과 같은 자리에서 정리한다. 뷰가 자기 타이머를 돌리지 않게
        // 하는 것이 핵심이다: 상시 표시 UI 의 타이머는 에너지 규칙(defect-log §에너지)에 걸린다.
        if let until = petReactionUntil, clock() > until { storedPetReaction = nil; petReactionUntil = nil }
        // 이벤트(진화/졸업/부화) 창 만료 — .levelUp 창이 끝날 때 문구 플래그를 함께 정리한다.
        // justEvolvedTo 는 여기(창 만료)에서만 지운다: 과거엔 매 update() 초입에 무조건 nil 로 밀어,
        // 진화 후 4초 창 도중 update 틱이 끼면 "…(으)로 진화했어요"→"성장했어요"로 되돌아갔다(회귀 #4).
        if let until = eventUntil, clock() > until {
            justGraduated = nil; justEvolvedTo = nil; eventUntil = nil
        }
        // 알 상태 프리패칭 — 종 pre-roll + 라인/스프라이트 예열(부화 순간 딜레이 제거).
        // 성공할 때까지 매 update 틱마다 재시도(성공 후엔 no-op).
        if state.active == nil, state.installBaselineSet, !isHatching {
            Task { await ensureEggPrefetch() }
        }
        // 알이 부화 임계에 도달하면 부화
        if state.active == nil, state.eggUsage >= PokemonBalance.eggHatchThreshold, !isHatching {
            Task { await hatchIfNeeded() }
        }
        // active 인데 라인 미로딩(앱 재시작) → 로드
        if state.active != nil, currentLine == nil, !isHatching {
            Task { await loadCurrentLine() }
        }
        // 위장 메타몽이 첫 진화 임계 도달 → 리빌(재시작 등 applyUsage 킥을 못 탄 경우 백업 트리거)
        if let a = state.active, a.dittoDisguise != nil, !a.dittoRevealed, currentLine != nil,
           !isHatching, !isRevealingDitto,
           a.usedAtStage >= PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: 0) {
            Task { await revealDitto() }
        }
        displayState = computeState(burnTier: burnTier, limitWarning: limitWarning,
                                    hasUsageData: hasUsageData, today: todayTokens,
                                    circadian: circadian)
        save()
    }

    /// 성격 보정을 적용한 성장량. 음수 델타는 들어오지 않지만(사용량은 단조 증가), 0 과 반올림
    /// 경계를 여기 한 곳에서 정해 호출부가 각자 반올림하지 않게 한다.
    ///
    /// 반올림은 **버림이 아니라 반올림**이다: 버림이면 0.9 배율이 작은 델타마다 0 이 되어 느린 성격이
    /// 영영 안 크는 극단이 생긴다. 반올림이면 delta=1 도 round(0.9)=1 이라 하한을 따로 둘 필요가 없다.
    ///
    /// **알려진 한계**: 정수 반올림이라 결과가 폴링 간격에 조금 의존한다(1토큰 델타 10회 = 10,
    /// 10토큰 델타 1회 = 9). 실사용 델타는 수십만~수백만이라 오차는 무시할 수준이고, 나머지를
    /// 이월하려면 개체마다 상태를 하나 더 들고 다녀야 해서 그 값에 비해 비싸다.
    nonisolated static func grownAmount(_ delta: Int, nature: PokemonNature?) -> Int {
        guard delta > 0, let nature, nature.growthMultiplier != 1.0 else { return max(0, delta) }
        return Int((Double(delta) * nature.growthMultiplier).rounded())
    }

    /// 토큰 증분을 현재 포켓몬에 적용 — 임계 도달 시 진화/졸업.
    /// 라인 미로딩(재시작 직후·오프라인)이어도 사용량은 항상 적립한다 — 여기서 드롭하면
    /// 프로바이더별 ledger 는 이미 전진해 델타가 영구 유실된다. 진화 판정만 라인 로드 후로 미룬다.
    /// - Parameter scaledByNature: 성격 배율을 적용할지. 기본은 true(실사용 토큰).
    ///   이상한 사탕처럼 **값이 고정된 아이템**은 false 로 넣는다 — 산 물건의 가치가 그걸 누구에게
    ///   쓰느냐로 달라지면 소모품이 아니라 조견표가 되고, "+100M" 피드백도 거짓이 된다.
    func applyUsage(_ delta: Int, scaledByNature: Bool = true) {
        guard state.active != nil else { return }
        // 성격이 성장 속도를 바꾼다(±10%). **성장에만** 건다 — `usedSinceInstall` 과 오늘/주/월 합계는
        // 실사용 통계라 게임 보정이 섞이면 숫자가 거짓이 된다. 성격이 없는 구버전 개체는 정확히 1.0.
        let scaled = scaledByNature ? Self.grownAmount(delta, nature: state.active!.nature) : max(0, delta)
        state.active!.usedAtStage += scaled
        guard let line = currentLine else { save(); return }
        var guardCount = 0
        while state.active != nil, guardCount < 50 {
            guardCount += 1
            let a = state.active!
            let thr = PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: a.stageIndex)
            guard a.usedAtStage >= thr else { break }
            guard let node = line.tree.node(withID: a.currentID) else { break }
            // 위장체는 부화 때는 다형태지만, 에셋 정규화/마이그레이션 뒤 leaf가 될 수 있다.
            // 따라서 terminal 졸업보다 먼저 리빌해야 위장 종이 도감으로 잘못 졸업하지 않는다.
            if a.dittoDisguise != nil, !a.dittoRevealed {
                if !isRevealingDitto { Task { await revealDitto() } }
                break
            }
            if node.children.isEmpty {
                graduate(); break
            } else {
                let nextIndex = a.stageIndex + 1
                let next: EvoNode
                if a.plannedPathIDs.indices.contains(nextIndex),
                   let planned = node.children.first(where: { $0.speciesID == a.plannedPathIDs[nextIndex] }) {
                    next = planned
                } else {
                    next = pickPlannedChild(node, baseID: a.baseID)
                    let fallbackRoute = [node.speciesID] + makeEvolutionPlan(from: next, baseID: a.baseID)
                    let repaired = Self.repairedPlan(realizedPath: a.pathIDs, stageIndex: a.stageIndex,
                                                     fallbackRoute: fallbackRoute)
                    state.active!.plannedPathIDs = repaired
                    state.active!.totalForms = repaired.count
                    AppLog.write("evolve: repaired invalid planned path for base \(a.baseID)")
                }
                state.active!.pathIDs = Array(a.pathIDs.prefix(a.stageIndex + 1)) + [next.speciesID]
                state.active!.stageIndex += 1
                state.active!.usedAtStage = a.usedAtStage - thr   // 초과분 이월
                let newName = line.localizedName(next.speciesID, state.language)
                // 진화 **전** 종을 주인공으로 남긴다 — "이상해씨가 이상해풀로 진화했어요" 가 되도록.
                chronicle(.evolved, mon: a, to: next.speciesID)
                justEvolvedTo = newName
                fireCelebration(.evolve)
                // 짧은 levelUp 창 — 진화 순간 "…(으)로 진화했어요" 문구 노출(hatch/graduate 와 동일 패턴).
                // 이게 없으면 computeState 가 .levelUp 을 안 내 statusEvolved 가 도달 불가(dead code)였다.
                eventUntil = clock().addingTimeInterval(4)
                notifyCompanionEvent(l.notifEvolveTitle, l.notifEvolveBody(newName))
            }
        }
        save()
    }

    private func pickPlannedChild(_ node: EvoNode, baseID: Int) -> EvoNode {
        let fresh = node.children.filter { ch in
            ch.finalIDs.contains { !state.collectedFinals.contains("\(baseID):\($0)") }
        }
        let pool = fresh.isEmpty ? node.children : fresh
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    private func makeEvolutionPlan(from root: EvoNode, baseID: Int) -> [Int] {
        var plan = [root.speciesID]
        var node = root
        while !node.children.isEmpty {
            let next = pickPlannedChild(node, baseID: baseID)
            plan.append(next.speciesID)
            node = next
        }
        return plan
    }

    static func repairedPlan(realizedPath: [Int], stageIndex: Int, fallbackRoute: [Int]) -> [Int] {
        guard !realizedPath.isEmpty else { return fallbackRoute }
        let currentIndex = min(stageIndex, realizedPath.count - 1)
        let prefix = Array(realizedPath.prefix(currentIndex + 1))
        guard fallbackRoute.first == prefix.last else { return prefix }
        return prefix + fallbackRoute.dropFirst()
    }

    /// 루트부터 실제로 이어지는 가장 긴 ID 경로와 마지막 유효 노드. 첫 ID가 루트와 다르면 루트로 복구한다.
    private func longestValidPath(_ ids: [Int], from root: EvoNode) -> (path: [Int], lastNode: EvoNode) {
        var path = [root.speciesID]
        var node = root
        guard ids.first == root.speciesID else { return (path, node) }
        for id in ids.dropFirst() {
            guard let child = node.children.first(where: { $0.speciesID == id }) else { break }
            path.append(id)
            node = child
        }
        return (path, node)
    }

    /// 저장된 실제 경로와 계획을 현재 에셋 트리에 맞춘다. 완전한 계획만 재사용해 재시작 시 RNG를 소비하지 않는다.
    private func normalizedEvolutionState(_ saved: MonState, from root: EvoNode) -> MonState {
        var normalized = saved
        let realized = longestValidPath(saved.pathIDs, from: root)
        let candidate = longestValidPath(saved.plannedPathIDs, from: root)
        let canReusePlan = candidate.path == saved.plannedPathIDs
            && candidate.path.starts(with: realized.path)
            && candidate.lastNode.children.isEmpty
        let plan: [Int]
        if canReusePlan {
            plan = candidate.path
        } else {
            let suffix = makeEvolutionPlan(from: realized.lastNode, baseID: saved.baseID)
            plan = realized.path + suffix.dropFirst()
        }
        normalized.pathIDs = realized.path
        normalized.plannedPathIDs = plan
        normalized.stageIndex = realized.path.count - 1
        normalized.totalForms = plan.count
        return normalized
    }

    private func graduate() {
        guard let a = state.active else { return }
        let finalID = a.currentID
        state.collectedFinals.insert("\(a.baseID):\(finalID)")
        state.dex.append(DexEntry(nickname: a.nickname, baseID: a.baseID, finalID: finalID,
                                  chainOrder: a.pathIDs, rarity: a.rarity, caughtAt: clock(),
                                  isShiny: a.isShiny, nature: a.nature,
                                  names: currentLine.map { line in   // 체인 각 종의 다국어 이름 저장(표시 즉시)
                                      Dictionary(uniqueKeysWithValues:
                                          a.pathIDs.compactMap { id in line.names[id].map { (id, $0) } })
                                  }))
        chronicle(.graduated, mon: a)
        let name = currentLine?.localizedName(finalID, state.language) ?? ""
        justGraduated = name
        notifyCompanionEvent(l.notifGraduateTitle, l.notifGraduateBody(name))
        eventUntil = clock().addingTimeInterval(6)
        state.active = nil
        activeGeneration += 1
        currentLine = nil
        state.eggUsage = 0   // 새 알은 처음부터 인큐베이션
        // 박스에서 꺼낸 개체가 그대로 졸업하면 활성 자리가 비면서 **보류해 둔 알이 갈 곳을 되찾는다.**
        // 여기서 복원하지 않으면 `active == nil` 인데 `heldEgg` 가 남은 상태로 저장되고, 다음 기동의
        // `sanitized` 가 그걸 손상으로 보고 지운다 — 1B~4B 주고 산 알이 졸업 축하와 함께 사라진다.
        if let held = state.heldEgg {
            state.eggUsage = held.usage
            state.eggTier = held.tier
            state.pendingHatchID = held.pendingHatchID
            state.heldEgg = nil
            AppLog.write("graduate: resumed held egg usage=\(held.usage) tier=\(held.tier?.rawValue ?? "none")")
        }
        // eggTier 는 손대지 않는다 — 여기 도달했다는 건 활성 포켓몬이 있었다는 뜻이라 보증은 이미 nil 이다
        // (부화가 소비, 디스크/불러오기는 sanitized 가 정규화). 소비 지점은 hatchCore 한 곳으로 유지한다.
        // "알을 받는 순간" 즉시 프리패칭 시작 — 다음 부화의 종·라인·스프라이트 예열.
        Task { await self.ensureEggPrefetch() }
        // 졸업에는 자체 `Celebration` 케이스가 없지만(팝오버는 `justGraduated` 를 본다) 눈에 보이는
        // 변화이므로 다시 그려야 한다. **전이가 끝난 뒤에** 부른다 — 중간에 부르면 콜백이 아직 남아
        // 있는 옛 활성 개체와 아직 안 세팅된 졸업 상태를 보고, 그 값으로 스프라이트를 캐싱한다.
        onCompanionEvent?()
    }

    // MARK: 인벤토리 / 이상한 사탕

    var rareCandyCount: Int { itemCount(.rareCandy) }
    func itemCount(_ kind: ItemKind) -> Int { state.inventory[kind.rawValue] ?? 0 }
    /// 이로치 부적 보유 여부 — 보유형이라 개수>0 = 소유(부화 shiny 분모를 낮춘다).
    var ownsShinyCharm: Bool { itemCount(.shinyCharm) > 0 }

    /// 소유 아이템(개수>0) — 가방 목록. 정렬은 ItemKind.allCases 순서.
    var ownedItems: [(kind: ItemKind, count: Int)] {
        ItemKind.allCases.compactMap { k in
            let c = itemCount(k)
            return c > 0 ? (k, c) : nil
        }
    }

    /// 이상한 사탕 사용 가능 — 활성 포켓몬 + 라인 로딩 완료 + 재고>0.
    /// 라인 미로딩(재시작 직후·오프라인)이면 비활성 — 사탕이 진화 없이 적립만 되는 것 방지.
    var canUseRareCandy: Bool { hasActive && currentLine != nil && rareCandyCount > 0 }

    /// 사탕 사용 결과 — UI 피드백 분기용.
    enum CandyUseResult: Equatable { case evolved, graduated, progressed, unavailable }

    /// 이상한 사탕 1개 사용 — 현재 포켓몬에 +RareCandy.xp. applyUsage 재사용으로 이월·진화·졸업·연출 자동.
    /// 사탕 XP 는 usedAtStage(진화 진행)에만 반영 — usedSinceInstall/오늘 토큰(실사용 통계)엔 안 잡힌다.
    @discardableResult
    func useRareCandy() -> CandyUseResult {
        guard canUseRareCandy else { return .unavailable }
        state.inventory[ItemKind.rareCandy.rawValue] = rareCandyCount - 1
        let beforeStage = state.active?.stageIndex ?? 0
        // 진화 안 될 때(부분 진행)도 즉시 "+XP" 피드백 — CompanionHeader 가 연출과 별개로 표시.
        candyFeedbackAmount = RareCandy.xp
        candyFeedbackSeq += 1
        // 성격 배율을 태우지 않는다 — 위 `candyFeedbackAmount` 가 약속한 값과 실제 적립이 갈리면 안 된다.
        applyUsage(RareCandy.xp, scaledByNature: false)   // 내부에서 save() 수행(인벤토리 감소 포함 영속)
        if state.active == nil { return .graduated }
        if state.active!.stageIndex > beforeStage { return .evolved }
        return .progressed
    }

    // MARK: 민트 (성격 랜덤 재설정)

    /// 민트 사용 가능 — 활성 포켓몬 + 재고>0. 성격은 MonState 에만 있어 진화 라인 로딩과 무관하다
    /// (사탕과 달리 currentLine 조건 없음 — 재시작 직후·오프라인에도 사용 가능).
    var canUseMint: Bool { hasActive && itemCount(.mint) > 0 }

    /// 민트 1개 사용 — 현재 포켓몬 성격을 '현재와 다른' 무작위 성격으로 교체(반드시 바뀐다). 성장·shiny·
    /// 종·usedAtStage·통계 전부 무관(순수 코스메틱). 사용 불가면 nil(무소모). 바뀐 성격을 반환(피드백용).
    @discardableResult
    func useMint() -> PokemonNature? {
        guard canUseMint, state.active != nil else { return nil }
        let cur = state.active!.nature
        let pool = PokemonNature.allCases.filter { $0 != cur }   // cur=nil(구버전 개체)이면 25종 전체
        let new = pool[Int(rng.next() % UInt64(pool.count))]
        state.active!.nature = new
        state.inventory[ItemKind.mint.rawValue] = itemCount(.mint) - 1
        mintFeedbackNature = new
        mintFeedbackSeq += 1
        save()
        return new
    }

    // MARK: 상점 (재화 = 사용한 토큰)

    /// 상점에서 쓸 수 있는 토큰(재화) = 실사용 누적 − 상점 지출 누적. 성장 미터(usedSinceInstall)는
    /// 여기선 읽기만 — 구매는 spentTokens 만 올려 잔액을 깎는다(진화 진행·오늘/주/월 통계 무영향).
    var availableTokens: Int { max(0, state.usedSinceInstall - state.spentTokens) }

    /// 지갑 요약 — 잔액이 어디서 왔는지. 큰 숫자 하나만 보여 주면 그게 "번 것"인지 "남은 것"인지
    /// 알 수 없고, 무언가를 산 뒤 숫자가 줄면 성장까지 되감긴 것처럼 보인다(실제로는 안 줄어든다).
    var walletEarned: Int { state.usedSinceInstall }
    var walletSpent: Int { state.spentTokens }

    /// 지금 잔액으로 살 수 있는 것 중 **가장 비싼 것**, 그리고 못 사는 것 중 **가장 싼 것**.
    ///
    /// 목록을 훑어 값을 비교하는 일을 사람에게 시키지 않으려는 것이다 — 상점의 실제 질문은
    /// "지금 뭘 할 수 있나"와 "다음 목표가 얼마나 남았나" 두 개뿐이다.
    var bestAffordable: ShopEntry? {
        shopEntries.filter { $0.price <= availableTokens }.max { $0.price < $1.price }
    }
    var nextGoal: (entry: ShopEntry, remaining: Int)? {
        guard let cheapest = shopEntries.filter({ $0.price > availableTokens })
            .min(by: { $0.price < $1.price }) else { return nil }
        return (cheapest, cheapest.price - availableTokens)
    }

    /// 상점 판매 아이템 — shopPrice 있는 것만. 가격 저렴한 순, 단 구매 완료한 보유형은 맨 아래로.
    var purchasableItems: [ItemKind] {
        ItemKind.allCases
            .filter { $0.shopPrice != nil }
            .sorted { a, b in
                // 구매 완료한 보유형(이로치 부적 등)은 맨 아래로 — 재구매 불가라 위에 있을 이유가 없다.
                let aDone = a.isPassive && itemCount(a) > 0
                let bDone = b.isPassive && itemCount(b) > 0
                if aDone != bDone { return !aDone }
                return (a.shopPrice ?? 0) < (b.shopPrice ?? 0)   // 나머지는 가격 저렴한 순
            }
    }

    /// 상점 표시 순서 — 판매 아이템 + (활성 포켓몬 있을 때) 알 3종을 하나의 가격 오름차순 목록으로 병합.
    /// 정렬 규칙은 purchasableItems 와 동일: 구매 완료한 보유형은 맨 아래, 나머지는 가격 저렴한 순.
    /// 알은 즉시 액션이라 '보유' 개념이 없어 가격 순서에만 참여한다.
    ///
    /// 등급 알끼리 붙여 '티어 사다리'로 묶어 보이게 하는 안도 검토했으나 채택하지 않았다 — 지금의 순수
    /// 가격 오름차순은 "알이 무조건 맨 아래로 append 돼 더 비싼 부적보다 아래에 놓이던" 표시 회귀를
    /// 고치며 들어온 규칙이라(ShopTests 참조), 그룹 배치는 그 회귀를 부분적으로 되살린다. 티어 관계는
    /// 카드의 등급 배지로 읽히게 한다.
    var shopEntries: [ShopEntry] {
        var entries: [ShopEntry] = purchasableItems.map { ShopEntry.item($0) }
        if hasActive { entries += FreshEgg.shopTiers.map { ShopEntry.egg($0) } }
        return entries.sorted { a, b in
            let aDone = isPurchasedPassive(a)
            let bDone = isPurchasedPassive(b)
            if aDone != bDone { return !aDone }
            return a.price < b.price
        }
    }

    /// 구매 완료한 보유형(이로치 부적 등)인지 — shopEntries 정렬에서 맨 아래로 보낼 판정.
    private func isPurchasedPassive(_ entry: ShopEntry) -> Bool {
        guard case .item(let kind) = entry else { return false }   // 알은 즉시 액션 — 보유 개념 없음
        return kind.isPassive && itemCount(kind) > 0
    }

    /// 구매 가능 — 잔액이 그 아이템 가격 이상(상점 미판매면 false). 활성/알 무관(재고는 미리 쌓아둘 수 있음).
    func canBuy(_ kind: ItemKind) -> Bool {
        guard let price = kind.shopPrice else { return false }
        if kind.isPassive && itemCount(kind) > 0 { return false }   // 보유형은 1회만(재구매 불가)
        return availableTokens >= price
    }

    /// 아이템 1개 구매 — 지갑에서 price 차감, 인벤토리 +1. usedSinceInstall(성장·통계)·진화 진행엔
    /// 무영향(지출 원장만 증가). 잔액 부족/미판매면 no-op(false).
    @discardableResult
    func buy(_ kind: ItemKind) -> Bool {
        guard let price = kind.shopPrice, availableTokens >= price else { return false }
        if kind.isPassive && itemCount(kind) > 0 { return false }   // 보유형 중복 구매 방지(방어)
        state.spentTokens += price
        state.inventory[kind.rawValue, default: 0] += 1
        save()
        return true
    }

    // 사탕 전용 래퍼 — 기존 호출부/테스트 호환.
    var canBuyRareCandy: Bool { canBuy(.rareCandy) }
    @discardableResult
    func buyRareCandy() -> Bool { buy(.rareCandy) }

    // MARK: 알 (리롤 — 현재 포켓몬 폐기, 도감·확률 무영향)

    /// 현재 알이 보증하는 등급 하한(UI 표시용). 활성 포켓몬이 있으면 알이 없으므로 nil.
    var eggGuarantee: Rarity? { state.active == nil ? state.eggTier : nil }

    /// 알 구매 가능 — 폐기할 활성 포켓몬이 있고 지갑이 그 티어 가격 이상일 때만.
    /// 알 상태에서도 살 수 있게 하는 안은 채택하지 않았다(기존 새 알과 게이트 통일) — 알끼리 교체하는
    /// 동작을 새로 만들지 않고, 상점의 알은 언제나 "지금 개체를 놓아주고 다시 뽑는다"는 한 가지 의미만 갖는다.
    func canBuyEgg(_ tier: Rarity?) -> Bool {
        // 파는 티어인지 먼저 확인한다 — 만족 불가능한 보증(전설: capture_rate 로 표현 불가)을 사면
        // 두 롤 경로 모두 후보가 0개라 알이 영영 안 깨지고, 부화가 없으니 보증도 안 풀리며,
        // 새 알 구매는 `hasActive` 에 막혀 되돌릴 수단이 없다. 가격만 계산되면 값이 빠져나가므로
        // 판매 목록을 여기서 강제한다(호출부 하나가 실수하면 토큰이 통째로 사라진다).
        guard FreshEgg.shopTiers.contains(tier) else { return false }
        // 보류된 알이 있으면 새 알을 팔지 않는다. 팔면 이미 값을 치른 알(진행·보증)이 조용히 덮어써진다
        // — 값이 사라지는 방향의 동작은 확인 대화상자로 덮을 문제가 아니라 애초에 없어야 한다.
        // 사용자가 할 일은 `returnToHeldEgg()` 로 그 알을 먼저 처리하는 것이고, UI 가 그렇게 안내한다.
        guard state.heldEgg == nil else { return false }
        return hasActive && availableTokens >= FreshEgg.price(guaranteeing: tier)
    }

    /// 알 구매 — 현재 포켓몬을 폐기하고 처음부터 인큐베이션하는 새 알로. 지갑에서 가격 차감.
    /// graduate() 의 알-리셋만 미러링하고 dex/collectedFinals(도감·확률 가중)는 손대지 않는다
    /// → "뽑은 적 없던 것처럼". 성장(usedAtStage)은 소멸(추가 비용).
    ///
    /// 여기서 종을 롤하지 않는다 — 롤에는 네트워크가 필요해서 오프라인이면 토큰만 사라진다. 보증만
    /// 상태(`eggTier`)에 적고, 실제 롤은 프리패치/부화 경로가 그 보증을 읽어 수행한다.
    @discardableResult
    func buyEgg(_ tier: Rarity?) -> Bool {
        guard canBuyEgg(tier) else { return false }
        state.spentTokens += FreshEgg.price(guaranteeing: tier)
        // 폐기가 아니라 **박스로 보낸다**(2026-08-19 이후). 졸업이 아니므로 dex/collectedFinals 는
        // 여전히 안 건드린다 — 도감은 졸업의 기록이고, 박스는 아직 키우는 중인 개체가 사는 곳이다.
        if let active = state.active {
            state.boxed.append(active)
            chronicle(.boxed, mon: active)
        }
        state.active = nil
        state.eggUsage = 0            // 새 알은 처음부터 인큐베이션(재부화에 5M 필요)
        state.eggTier = tier          // 등급 보증(nil = 보증 없음)
        state.pendingHatchID = nil    // 새 보증으로 처음부터 롤(활성 포켓몬이 있는 동안엔 원래 비어 있다)
        beginNewActiveSubject()
        AppLog.write("egg purchased: boxed active, tier=\(tier?.rawValue ?? "none") boxCount=\(state.boxed.count)")
        Task { await self.ensureEggPrefetch() }   // 다음 부화 예열
        save()
        return true
    }

    // MARK: 박스 (PC)

    /// 박스에 든 개체들. 순서는 넣은 순(가장 오래 전에 넣은 것이 앞).
    var boxedMons: [MonState] { state.boxed }

    /// 박스 개체의 표시 이름. 박스 개체는 진화 라인이 로딩돼 있지 않아(활성만 로딩한다) 대개 이름이
    /// 없다 → 도감에 이미 저장된 이름을 먼저 쓰고, 없으면 종 번호로 떨어진다. 번호라도 보여 주는 편이
    /// 빈 칸보다 낫고, 라인 하나를 더 받아오자고 박스 열 때마다 네트워크를 태우지는 않는다.
    func boxedDisplayName(_ mon: MonState) -> String {
        if let nickname = mon.nickname, !nickname.isEmpty { return nickname }
        if mon.baseID == state.active?.baseID, let line = currentLine {
            return line.localizedName(mon.currentID, state.language)
        }
        for entry in state.dex {
            if let names = entry.names?[mon.currentID],
               let resolved = state.language.resolveName(names) {
                return resolved
            }
        }
        if let resolved = resolvedSpeciesNames[mon.currentID] { return resolved }
        return "#\(mon.currentID)"
    }
    var boxCount: Int { state.boxed.count }

    /// 옆으로 치워 둔 알이 있는가 — 있으면 상점에서 새 알을 살 수 없다(아래 참조).
    var hasHeldEgg: Bool { state.heldEgg != nil }
    /// 보류된 알의 인큐베이션 진행도(0…1) — 화면에 "얼마나 품었었나"를 보여주기 위한 값.
    var heldEggProgress: Double {
        guard let held = state.heldEgg else { return 0 }
        return min(1, max(0, Double(held.usage) / Double(PokemonBalance.eggHatchThreshold)))
    }
    var heldEggGuarantee: Rarity? { state.heldEgg?.tier }

    /// 박스에서 꺼낼 수 있는가 — 부화 진행 중에는 막는다.
    /// `isHatching` 은 라인/종을 가져오는 await 구간이라, 그 사이에 활성 개체를 갈아치우면 돌아온
    /// 응답이 **다른 개체**에 적용된다(세대 가드가 잡아 버리긴 하지만, 사용자에겐 "눌렀는데 아무 일도
    /// 안 일어남"으로 보인다). 시작 자체를 막는 편이 정직하다.
    func canWithdraw(at index: Int) -> Bool {
        state.boxed.indices.contains(index) && !isHatching && !isRevealingDitto
    }

    /// 박스에서 개체를 꺼낸다 — **교대**다. 지금 데리고 있는 개체는 박스로 들어가고, 품고 있던 알이
    /// 있었다면 옆으로(`heldEgg`) 치워진다. 성장(`usedAtStage`)은 양쪽 다 그대로 유지된다.
    ///
    /// 넣기만 하는 함수를 따로 두지 않는 이유는 **경제 구멍** 때문이다. 활성 개체를 그냥 박스에 넣어
    /// 비우면 그 자리에 `eggUsage == 0` 인 새 알이 생기고, 그건 아무도 값을 치르지 않은 공짜 알이다
    /// (알을 얻는 정당한 경로는 졸업 750M~6B 또는 구매 1B~4B 두 가지뿐이다). 교대만 허용하면
    /// "알이 시작되는 횟수"가 이 기능 전후로 동일하다. 보류된 알로 **돌아가는** 것만 예외이고,
    /// 그건 `returnToHeldEgg()` 가 별도로 처리한다(이미 값을 치른 알이라 공짜가 아니다).
    /// - Parameter expecting: the individual the caller believes is at `index`, when it has one.
    ///
    /// Same reasoning as `release(at:expecting:)`, though the stakes are lower: taking out the wrong
    /// Pokémon can be undone by taking out the right one. The guard is here anyway so that no
    /// index-based call in this type is the *unsafe* one — a reader should not have to work out
    /// which of two similar APIs checks identity.
    @discardableResult
    func withdraw(at index: Int, expecting: MonState? = nil) -> Bool {
        guard canWithdraw(at: index) else { return false }
        if let expecting, state.boxed[index] != expecting { return false }
        if let active = state.active {
            state.boxed.append(active)
        } else {
            // 알을 품고 있던 중 — 파괴하지 않고 옆으로 옮긴다. 진행·보증·프리롤을 한 묶음으로.
            state.heldEgg = HeldEgg(usage: state.eggUsage, tier: state.eggTier,
                                    pendingHatchID: state.pendingHatchID)
            state.eggUsage = 0; state.eggTier = nil; state.pendingHatchID = nil
        }
        state.active = state.boxed.remove(at: index)
        beginNewActiveSubject()
        chronicle(.withdrawn, mon: state.active)
        AppLog.write("box: withdrew base=\(state.active?.baseID ?? -1) boxCount=\(state.boxed.count) heldEgg=\(state.heldEgg != nil)")
        save()
        Task { await self.loadCurrentLine() }
        return true
    }

    /// 박스에서 개체를 **놓아준다** — 되돌릴 수 없다.
    ///
    /// 박스가 무제한이라 넣기만 하면 영영 쌓인다. 놓아주기가 없으면 "정리"라는 선택지 자체가 없고,
    /// 세이브도 단조 증가한다(가져오기 상한 8MiB 가 실제 벽이다).
    ///
    /// 폐기와 다른 점은 **사용자가 그 개체를 골라서, 확인을 거쳐** 한다는 것이다 — 2026-08-19 의
    /// 사고는 고르지도 확인하지도 않은 폐기였다. 일지에는 남는다: 함께 있었다는 사실까지 지우지는 않는다.
    /// - Parameter expecting: the individual the caller believes is at `index`.
    ///
    /// An index alone is not an identity. The confirmation sits on screen while the Box can change
    /// underneath it — importing a save reorders it wholesale — and confirming would then release
    /// whoever had slid into that position. For an action with no undo, "the index is in range" is
    /// not enough; it has to be the same Pokémon.
    @discardableResult
    func release(at index: Int, expecting: MonState?) -> Bool {
        guard state.boxed.indices.contains(index) else { return false }
        if let expecting, state.boxed[index] != expecting { return false }
        let released = state.boxed.remove(at: index)
        chronicle(.released, mon: released)
        AppLog.write("box: released base=\(released.baseID) boxCount=\(state.boxed.count)")
        save()
        return true
    }

    /// 보류해 둔 알로 돌아간다 — 지금 개체를 박스에 넣고, 치워 뒀던 알을 다시 품는다.
    /// **보류된 알이 있을 때만** 가능하다. 조건 없이 열어 두면 위 `withdraw` 주석의 공짜 알이 된다.
    var canReturnToHeldEgg: Bool {
        state.heldEgg != nil && state.active != nil && !isHatching && !isRevealingDitto
    }

    @discardableResult
    func returnToHeldEgg() -> Bool {
        guard canReturnToHeldEgg, let held = state.heldEgg, let active = state.active else { return false }
        state.boxed.append(active)
        state.active = nil
        state.eggUsage = held.usage
        state.eggTier = held.tier
        state.pendingHatchID = held.pendingHatchID
        state.heldEgg = nil
        beginNewActiveSubject()
        AppLog.write("box: returned to held egg usage=\(held.usage) tier=\(held.tier?.rawValue ?? "none")")
        save()
        Task { await self.ensureEggPrefetch() }
        return true
    }

    /// 활성 개체가 **바뀌었다**는 사실 하나로 묶이는 뒷정리.
    ///
    /// `activeGeneration` 을 올리는 것이 핵심이다 — 진행 중인 부화/라인 로드/메타몽 리빌은 전부
    /// await 후에 이 값을 다시 확인하고 다르면 자기 결과를 버린다. 올리지 않으면 날아오던 응답이
    /// 방금 꺼낸 개체를 덮어쓴다. 나머지(라인·프리패치·연출 플래그)는 이전 개체에 붙어 있던 것이라
    /// 같이 무효화하지 않으면 새 개체에 옛 이름·옛 진화 트리가 그대로 보인다.
    private func beginNewActiveSubject() {
        activeGeneration += 1
        currentLine = nil
        prefetchedLineID = nil
        justGraduated = nil; justEvolvedTo = nil; eventUntil = nil
        displayState = state.active == nil ? .egg : .idle
    }

    // 보증 없는 기본 알 래퍼 — 기존 호출부/테스트 호환.
    var canBuyFreshEgg: Bool { canBuyEgg(nil) }
    @discardableResult
    func buyFreshEgg() -> Bool { buyEgg(nil) }

    /// 지급 판정(순수·엣지 트리거) — 한도 창이 100% 를 새로 넘어선 순간에만 지급.
    /// - 100% 미만 → 맵에서 제거(재무장). resets_at 등 휘발 필드는 key 에 없다(안정 식별자만).
    /// - 이미 지급한 창(tier≥1)은 재지급 안 함. session=1개·weekly=weeklyGrant.
    /// - 부수효과(인벤토리·알림)와 분리해 xctest 가능. (evaluateLimitAlerts 자매)
    static func evaluateCandyGrants(
        windows: [CandyWindow], grantTier: inout [String: Int]
    ) -> [CandyGrant] {
        var grants: [CandyGrant] = []
        for w in windows {
            guard w.utilization >= 100 else { grantTier[w.key] = nil; continue }
            let previous = grantTier[w.key] ?? 0
            guard previous < 1 else { continue }
            grantTier[w.key] = 1
            let count = w.kind == .weekly ? RareCandy.weeklyGrant : 1
            grants.append(CandyGrant(windowKey: w.key, windowName: w.name, count: count))
        }
        return grants
    }

    /// 한도 창 상태로부터 사탕 지급(엣지·영속). AppDelegate 가 매 refresh 완료 시(한도 로드 후) 호출.
    /// - 첫 실행: 현재 100% 창을 지급 없이 tier 시드만 → 이후 "새로 넘어서는" 순간부터 지급(소급 차단).
    /// - limitsReady=false(한도 미로딩)면 시드/지급 모두 대기(다음 refresh 에 재시도).
    func grantCandies(from windows: [CandyWindow], limitsReady: Bool) {
        guard limitsReady else { return }
        if !state.candyFeatureSeeded {
            // 한계(수용): 첫 refresh 에 한 프로바이더 한도만 로드되면 그 프로바이더 창만 시드된다.
            // 이후 다른 프로바이더가 이미 100%인 채 로드되면 소급 지급될 수 있으나, 1회·소수 캔디라
            // 1인 로컬에서 무시(YAGNI). refresh() 는 전 프로바이더 fetch 를 await 후 onRefresh 하므로
            // 정상 경로(둘 다 성공)에선 원자적 시드다.
            for w in windows where w.utilization >= 100 { state.candyGrantTier[w.key] = 1 }
            state.candyFeatureSeeded = true
            save()
            return
        }
        let before = state.candyGrantTier
        let grants = Self.evaluateCandyGrants(windows: windows, grantTier: &state.candyGrantTier)
        for g in grants {
            state.inventory[ItemKind.rareCandy.rawValue, default: 0] += g.count
            // 지급 자체는 알림 여부와 무관(상태 변경). 알림은 "왜 받는지"(그 창 한도를 다 채운 수고) 명시.
            notifyCompanionEvent(l.notifCandyTitle(item: l.itemName(.rareCandy), count: g.count),
                                 l.notifCandyBody(window: g.windowName))
        }
        // 지급이 없어도 재무장(창이 100%→아래로 내려가며 grantTier 에서 제거)은 영속해야 한다 —
        // 안 하면 재시작 시 stale tier=1 로 다음 100% 도달이 "이미 지급"으로 오판돼 지급 누락(회귀).
        if !grants.isEmpty || state.candyGrantTier != before { save() }
    }

    /// companion 이벤트 시스템 알림(.app + 토글 ON 일 때만). 한도 알림과 독립.
    private var notifSeq = 0
    private func notifyCompanionEvent(_ title: String, _ body: String) {
        guard AppEnv.isProductionInstall else { return }
        guard PlatformDefaults.standard.object(forKey: "companionNotifications") as? Bool ?? true else { return }
        notifSeq += 1
        PlatformNotifier.post(
            identifier: "companion-event-\(notifSeq)", title: title, body: body,
            sound: true, critical: false)
    }

    // MARK: 부화

    func hatchIfNeeded() async {
        guard state.active == nil, !isHatching, state.eggUsage >= PokemonBalance.eggHatchThreshold else { return }
        // 프리패치가 "종 롤 중"(pending 미확정)일 때만 대기 — 이중 rng 소비 방지.
        // pending 확정 후의 예열(라인/스프라이트)과는 동시 진행해도 안전하다.
        guard state.pendingHatchID != nil || !prefetchInFlight else { return }
        // isHatching 을 롤~부화 전체에 defer 로 잠근다. 과거엔 chooseBase 후 isHatching 을 잠깐
        // 내렸다가(hatch 자체 가드 통과용) hatch 를 호출해, 그 await 창에서 다른 update 틱이
        // 두 번째 종을 롤하는 경합이 있었다. hatchCore 는 isHatching 을 재검사하지 않으므로
        // 여기서 소유한 락 하나로 롤·부화가 원자적으로 보호된다.
        let generation = activeGeneration
        isHatching = true
        defer { isHatching = false }
        // 프리패칭된 종이 있으면 그대로 사용(라인·스프라이트 예열됨 → 딜레이 ~0), 없으면 지금 롤.
        let base: Int?
        if let pending = state.pendingHatchID {
            base = pending
        } else {
            base = await chooseBase()
        }
        guard let base else { return }   // 네트워크 불안정 → 알 유지, 다음 update 틱에 재시도
        // 세대 검사는 **여기서** 해야 한다. `chooseBase()` 대기 창에서 상태가 통째로 교체되면
        // (세이브 불러오기) 그 뒤에 진입하는 hatchCore 는 *교체 이후*의 세대를 캡처해 자기 가드가
        // 무조건 통과한다 — 옛 롤 결과가 불러온 개체를 덮어쓰고 save() 로 디스크에 박힌다.
        guard activeGeneration == generation, state.active == nil else {
            AppLog.write("hatch: discarded before core — subject replaced during species roll")
            kickLineLoadIfNeeded()
            return
        }
        state.pendingHatchID = nil
        await hatchCore(baseID: base)
    }

    /// 부화가 폐기된 뒤 남은 개체(대개 방금 불러온 개체)의 진화 라인을 다시 로드한다.
    /// `loadCurrentLine` 은 `!isHatching` 을 요구하므로 부화 중에 걸린 로드는 조용히 실패한다 —
    /// 아무도 재시도하지 않으면 다음 update 틱(기본 120초)까지 이름이 "Token Egg" 로 남는다.
    /// Task 본문은 현재 동기 실행(= defer 로 isHatching 해제)이 끝난 뒤 돌므로 락이 이미 풀려 있다.
    private func kickLineLoadIfNeeded() {
        guard state.active != nil, currentLine == nil else { return }
        Task { await loadCurrentLine() }
    }

    // MARK: 알 프리패칭

    private var prefetchInFlight = false
    private var prefetchedLineID: Int?   // 라인·스프라이트 예열 완료한 종(세션 메모리)

    /// 알 상태에서 부화를 미리 준비 — ① 종 pre-roll(pendingHatchID, 영속) ② 진화 라인
    /// fetch(provider 캐시 적재) ③ 스프라이트 예열(정적+애니메이션+shiny 애니메이션).
    /// 전부 성공하면 부화 순간 네트워크 0. 실패 지점부터 다음 update 틱에 이어서 재시도.
    private func ensureEggPrefetch() async {
        guard state.active == nil, !isHatching, !prefetchInFlight else { return }
        let generation = activeGeneration
        prefetchInFlight = true
        defer { prefetchInFlight = false }

        if state.pendingHatchID == nil {
            guard let id = await chooseBase() else { return }   // 오프라인 → 다음 틱 재시도
            // await 사이에 부화가 끝났거나(active != nil) 상태가 통째로 교체됐으면(세이브 불러오기)
            // 이 롤을 버린다 — 안 그러면 불러온 알의 pre-roll 을 남의 롤로 덮어쓴다.
            guard state.active == nil, activeGeneration == generation else { return }
            state.pendingHatchID = id
            save()
        }
        guard let id = state.pendingHatchID, prefetchedLineID != id else { return }
        guard let line = try? await provider.line(baseSpeciesID: id) else { return }   // 라인 예열
        // 스프라이트 예열 — 부화 직후 보일 것들: base 정적+애니메이션, shiny 롤(1/64) 대비 shiny 애니메이션.
        // .app 번들에서만(단위 테스트가 실네트워크에 닿지 않도록 — 알림과 동일한 게이트).
        if AppEnv.isProductionInstall {
            _ = await SpriteStore.shared.data(speciesID: line.baseID, animated: false, shiny: false)
            _ = await SpriteStore.shared.data(speciesID: line.baseID, animated: true, shiny: false)
            _ = await SpriteStore.shared.data(speciesID: line.baseID, animated: true, shiny: true)
        }
        prefetchedLineID = id
    }

    func hatch(baseID: Int) async {
        guard !isHatching else { return }
        isHatching = true
        defer { isHatching = false }
        await hatchCore(baseID: baseID)
    }

    // MARK: 메타몽 위장/리빌

    /// 메타몽 위장 롤 판정(순수) — common·≥2형태만, 미리 뽑은 roll 값으로 1/128. (부수효과 없이 xctest)
    nonisolated static func dittoDisguiseHit(rarity: Rarity, totalForms: Int, roll: UInt64) -> Bool {
        rarity == .common && totalForms >= 2 && roll % PokemonOdds.dittoDisguiseDenominator == 0
    }

    /// 이로치 부화 판정(순수) — 미리 뽑은 roll 값 % 분모(부적 보유 48, 없으면 64)==0. (부수효과 없이 xctest)
    nonisolated static func rollsShiny(roll: UInt64, charmOwned: Bool) -> Bool {
        roll % (charmOwned ? ShinyCharm.shinyDenominator : PokemonOdds.shinyDenominator) == 0
    }

    /// 실제 부화 로직 — isHatching 락은 호출자(hatch / hatchIfNeeded)가 소유·해제한다.
    private func hatchCore(baseID: Int) async {
        let generation = activeGeneration
        guard let line = try? await provider.line(baseSpeciesID: baseID) else {
            AppLog.write("hatch: line fetch failed for base \(baseID) — egg kept, retry next tick")
            return
        }
        // 라인 fetch 창(네트워크) 동안 활성 개체가 교체됐으면 이 부화 결과를 폐기한다. 세이브 불러오기가
        // 그 창에 들어오면, 여기서 멈추지 않는 한 갓 부화한 개체가 방금 불러온 개체를 덮어쓴다.
        // (loadCurrentLine·revealDitto 와 같은 세대 가드 — isHatching 락은 같은 앱 내 중복 부화만 막는다.)
        guard activeGeneration == generation else {
            AppLog.write("hatch: discarded — active subject replaced during line fetch")
            kickLineLoadIfNeeded()
            return
        }
        // 산 보증을 지키는 마지막 관문 — 진짜 등급을 아는 건 여기뿐이다(후보 인덱스엔 capture_rate 만
        // 있고 is_legendary 가 없다). 필터가 어긋났으면(인덱스 stale 등) 낮은 등급을 그냥 내주지 말고
        // 알을 유지한 채 pre-roll 만 버려 다음 틱에 다시 뽑는다 — 사용자는 산 보증을 계속 들고 있는다.
        if let tier = state.eggTier, line.rarity.sortRank < tier.sortRank {
            AppLog.write("hatch: rolled \(line.rarity) below guaranteed \(tier) — discarded, re-roll next tick")
            state.pendingHatchID = nil
            prefetchedLineID = nil
            save()
            return
        }
        currentLine = line
        // 부화 임계 초과분은 부화체 성장에 이월(낭비 없음).
        let overflow = max(0, state.eggUsage - PokemonBalance.eggHatchThreshold)
        state.eggUsage = 0
        state.eggTier = nil   // 보증은 이 부화로 소비된다(다음 알은 다시 무보증)
        // 개체 롤 — shiny(1/64)·성격(25종)은 부화 순간 확정, 진화해도 유지.
        let isShiny = Self.rollsShiny(roll: rng.next(), charmOwned: ownsShinyCharm)
        let nature = PokemonNature.allCases[Int(rng.next() % UInt64(PokemonNature.allCases.count))]
        // 메타몽 위장 롤 — common·≥2형태에 한해 1/128. .app 게이트(&& 단락 → 비앱에선 rng 미소비로
        // 기존 테스트 RNG 시퀀스 무영향). 위장/리빌 로직은 상태 기반으로 별도 테스트한다.
        var dittoDisguise: Int?
        if dittoDisguiseRollingEnabled,
           Self.dittoDisguiseHit(rarity: line.rarity, totalForms: line.totalForms, roll: rng.next()) {
            dittoDisguise = line.baseID
        }
        let evolutionPlan = makeEvolutionPlan(from: line.tree, baseID: line.baseID)
        // 위장 중엔 이로치를 숨긴다 — 부화 알림·연출도 일반체로(정체는 리빌 때 공개).
        let showShiny = isShiny && dittoDisguise == nil
        activeGeneration += 1
        state.active = MonState(baseID: line.baseID, pathIDs: [line.baseID], plannedPathIDs: evolutionPlan,
                                stageIndex: 0, usedAtStage: 0, rarity: line.rarity, totalForms: evolutionPlan.count,
                                isShiny: isShiny, nature: nature, dittoDisguise: dittoDisguise)
        chronicle(.hatched, mon: state.active)
        AppLog.write("hatch: base=\(line.baseID) rarity=\(line.rarity) shiny=\(isShiny) forms=\(evolutionPlan.count) ditto=\(dittoDisguise != nil)")
        let name = line.localizedName(line.baseID, state.language)
        notifyCompanionEvent(showShiny ? l.notifShinyHatchTitle : l.notifHatchTitle,
                             showShiny ? l.notifShinyHatchBody(name) : l.notifHatchBody(name))
        justEvolvedTo = nil        // 새 부화는 "성장" 문구(진화 아님) — 직전 진화명이 남아 표시되지 않게
        displayState = .levelUp
        eventUntil = clock().addingTimeInterval(4)
        if overflow > 0 { applyUsage(overflow) }   // 이월분 즉시 반영(필요 시 진화/리빌까지)
        // 연출은 이월 진화 뒤에 발화 — 이월 evolve 가 shiny 부화 버스트를 덮지 않도록
        // 마지막 이벤트를 hatch 로 유지한다. 이월로 즉시 졸업한 극단 케이스면 생략(이미 도감행).
        if state.active != nil { fireCelebration(.hatch(shiny: showShiny)) }
        save()
    }

    /// 위장 → 리빌: 진화 못 하는 메타몽이 "첫 진화 임계"에서 진화 대신 정체를 드러내는 순간.
    /// Ditto 라인 로드 후 상태 변환(rare·단일형태·초과분 이월, isShiny/nature 유지) + 연출·알림.
    private func revealDitto() async {
        guard let a = state.active, a.dittoDisguise != nil, !a.dittoRevealed, !isRevealingDitto else { return }
        let generation = activeGeneration
        let firstEvoThr = PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: 0)
        guard a.usedAtStage >= firstEvoThr else { return }   // 임계 미달 방어
        isRevealingDitto = true
        defer { isRevealingDitto = false }
        guard let dittoLine = try? await provider.line(baseSpeciesID: PokemonOdds.dittoSpeciesID) else {
            AppLog.write("ditto reveal: line fetch failed — retry next tick"); return
        }
        guard activeGeneration == generation,
              var m = state.active, m.dittoDisguise != nil, !m.dittoRevealed else { return }
        let latestFirstEvoThr = PokemonBalance.phaseThreshold(rarity: m.rarity, totalForms: m.totalForms, stageIndex: 0)
        guard m.usedAtStage >= latestFirstEvoThr else { return }
        let disguiseName = currentLine?.localizedName(m.baseID, state.language) ?? "#\(m.baseID)"
        let carryOver = max(0, m.usedAtStage - latestFirstEvoThr)   // 위장체 첫 진화 초과분 → 메타몽 성장 이월
        // 메타몽으로 전환 — rarity/forms 는 로드한 라인에서, isShiny/nature/dittoDisguise 는 유지.
        m.baseID = dittoLine.baseID
        let evolutionPlan = makeEvolutionPlan(from: dittoLine.tree, baseID: dittoLine.baseID)
        m.pathIDs = [dittoLine.baseID]
        m.plannedPathIDs = evolutionPlan
        m.stageIndex = 0
        m.rarity = dittoLine.rarity
        m.totalForms = evolutionPlan.count
        m.usedAtStage = carryOver
        m.dittoRevealed = true
        let shiny = m.isShiny
        state.active = m
        currentLine = dittoLine
        chronicle(.dittoRevealed, mon: m)
        AppLog.write("ditto reveal: disguise=\(m.dittoDisguise ?? -1) → ditto rarity=\(dittoLine.rarity) shiny=\(shiny)")
        fireCelebration(.dittoReveal(shiny: shiny))
        displayState = .levelUp
        eventUntil = clock().addingTimeInterval(5)
        notifyCompanionEvent(shiny ? l.notifShinyDittoRevealTitle : l.notifDittoRevealTitle,
                             shiny ? l.notifShinyDittoRevealBody(disguiseName) : l.notifDittoRevealBody(disguiseName))
        save()
        applyUsage(0)   // 이월분으로 메타몽 졸업 재평가(rare 3B라 보통 즉시 졸업 아님)
    }

    private func loadCurrentLine() async {
        guard let a = state.active, currentLine == nil, !isHatching else { return }
        let generation = activeGeneration
        isHatching = true
        defer { isHatching = false }
        if let line = try? await provider.line(baseSpeciesID: a.baseID) {
            // await 중 사용량·민트 등 활성 상태는 계속 바뀔 수 있다. 요청 당시 스냅샷을 다시 쓰지 말고
            // 같은 개체가 아직 활성인 경우에만 최신 상태를 정규화한다.
            guard activeGeneration == generation,
                  let latest = state.active, latest.baseID == a.baseID, currentLine == nil else { return }
            state.active = normalizedEvolutionState(latest, from: line.tree)
            currentLine = line
            save()   // 마이그레이션 선택을 사용량 재평가 전에 영속화해 재시작마다 다시 롤리지 않는다.
            applyUsage(0)   // 라인 미로딩 동안 적립된 사용량이 임계를 넘었으면 지금 진화 판정
        }
    }

    /// 부화 종 선정 — 하드코딩 풀 없이 PokéAPI 1~5세대 base 전체(329종)에서 가중 선택.
    ///   ① base 인덱스(id + capture_rate)를 GraphQL 1쿼리로 취득(30일 디스크 캐시 → 보통 0콜)
    ///   ② 가중치 = 공식 capture_rate 그대로(캐터피 255 vs 뮤츠 3 = 85:1, 전설군 ≈ 0.77%)
    ///      단, 이미 수집한 base 는 가중치 ½(미수집 부스트 — 재부화/shiny 사냥은 열어둠)
    ///   ③ 누적 가중치에서 정확히 1롤 — 루프/재롤 없음, 시간 상한 확정적
    /// 인덱스 취득 실패(오프라인 + 캐시 없음) 시 nil → 알 유지, 다음 갱신 틱 재시도.
    private func chooseBase() async -> Int? {
        let tier = state.eggTier
        if let full = try? await provider.baseSpeciesIndex(), !full.isEmpty {
            // 등급 보증 알은 후보를 먼저 좁힌다 — capture_rate 상한이 곧 등급 하한이므로
            // (Rarity.captureRateCeiling) 전설도 자연히 포함된다("희귀 이상"에 전설이 들어가는 게 정상).
            // 좁힌 결과가 비면 보증을 못 지키므로 전체 풀로 폴백하지 말고 알을 유지한다(다음 틱 재시도).
            let index = tier.map { t in full.filter { t.includes(captureRate: $0.captureRate) } } ?? full
            guard !index.isEmpty else {
                AppLog.write("hatch: no candidate for guaranteed \(tier?.rawValue ?? "none") — egg kept, retry next tick")
                return nil
            }
            let weights = index.map { e in
                state.collectedFinals.contains(where: { $0.hasPrefix("\(e.id):") })
                    ? max(1, e.captureRate / 2) : max(1, e.captureRate)
            }
            let total = weights.reduce(0, +)
            var r = Int(rng.next() % UInt64(total))
            for (i, w) in weights.enumerated() {
                r -= w
                if r < 0 { return index[i].id }
            }
            return index.last?.id   // 도달 불가(방어)
        }
        // GraphQL base 인덱스 엔드포인트 장애 → REST 폴백. 부화가 한 엔드포인트에 묶이지 않게.
        AppLog.write("hatch: base index unavailable — REST fallback")
        return await chooseBaseViaREST()
    }

    /// REST 폴백 — animated 에셋 지원 범위에서 무작위 id 를 뽑아 base 인지 확인(rejection sampling).
    /// GraphQL 인덱스가 죽어도 부화가 되게 한다. 가중치(capture_rate)는 생략 — 희귀도는 부화 후
    /// line() 이 실제 capture_rate 로 계산하므로 결과 개체의 등급은 정확하다. 인덱스 복구 시 가중 선택 재개.
    private func chooseBaseViaREST() async -> Int? {
        let tier = state.eggTier
        for attempt in 1...16 {
            let ids = PokemonAssets.animatedSpeciesIDs
            let id = Int(rng.next() % UInt64(ids.count)) + ids.lowerBound
            do {
                if let bs = try await provider.baseSpecies(id: id) {
                    // 등급 보증은 가중 경로와 **같은 기준**으로 여기서도 걸러야 한다 — 이 폴백만 빠지면
                    // GraphQL 인덱스 장애 때 보증이 조용히 깨진다. 못 찾으면 알 유지(구매 소멸 금지).
                    if let tier, !tier.includes(captureRate: bs.captureRate) { continue }
                    AppLog.write("hatch: REST fallback picked base \(id) (cap \(bs.captureRate), \(attempt) tries)")
                    return id
                }
                // nil = base 아님(진화 중간체) → 다음 시도
            } catch {
                AppLog.write("hatch: REST fallback network error — retry next tick: \(error)")
                return nil   // REST 도 불가 → 알 유지, 다음 update 틱 재시도
            }
        }
        AppLog.write("hatch: REST fallback exhausted 16 tries")
        return nil
    }

    private func computeState(burnTier: BurnTier, limitWarning: Bool, hasUsageData: Bool, today: Int,
                              circadian: CircadianPhase?) -> CompanionStateKind {
        if state.active == nil { return .egg }
        if justGraduated != nil || (eventUntil != nil && clock() < eventUntil!) { return .levelUp }
        // 지침: 한도 경고가 먼저다(진짜 위험), 그다음이 작업 구간 후반(피로).
        // `limitWarning` 은 한도 API 에 의존해 429 중엔 항상 false 라 **그것만으로는 `.tired` 가
        // 도달 불가**였다. 로컬 블록 위치를 더해야 네트워크와 무관하게 리듬이 생긴다.
        if limitWarning || circadian == .winding { return .tired }
        // 데이터 자체가 없으면 잔다 — 이건 리듬과 무관한 전제 조건이다.
        if !hasUsageData { return .sleep }
        // 리듬을 넘겨받은 호출부는 **블록만 본다.** 날짜 기준(`today == 0`)을 함께 두면 자정 직후
        // 작업 중인 블록 한가운데서도 자 버려서, 리듬이 없애려던 달력 경계 문제가 그대로 남는다.
        // 리듬이 없는 호출부(nil)는 종전대로 날짜 기준을 쓴다.
        if let circadian {
            if circadian == .asleep { return .sleep }
        } else if today == 0 {
            return .sleep
        }
        switch burnTier {
        case .idle: return .idle
        case .normal: return .working
        case .fast, .blazing: return .focus
        }
    }

    // MARK: 세이브 이전 (기기 교체)

    /// 덮어쓰기 확인에 쓸 "이 기기의 현재 진행" 요약.
    var transferSummary: SaveSummary { SaveSummary(state: state) }

    /// 저장 패널에 채울 기본 파일명. 봉투의 `exportedAt` 과 **같은 시계**에서 뽑는다 — 뷰가 따로
    /// `Date()` 를 부르면 파일명 날짜와 내용의 날짜가 갈릴 수 있다(자정 경계).
    var suggestedExportFileName: String { SaveTransfer.suggestedFileName(date: clock()) }

    /// 내보내기 페이로드. 파일 쓰기는 호출자(UI)가 사용자가 고른 위치에 수행한다.
    func exportedSaveData(appVersion: String, deviceName: String) throws -> Data {
        try SaveTransfer.encode(state: state, appVersion: appVersion, deviceName: deviceName, now: clock())
    }

    /// 검증된 세이브를 이 기기에 적용 — 기존 상태 백업 → 기기 기준 재정렬 → 저장 → 라인 재로딩.
    /// 백업을 못 남기면 **적용하지 않고** throw 한다 — 확인창이 "직전 상태가 남는다"고 약속하므로,
    /// 그 약속을 못 지키는 채로 덮어쓰면 사용자는 되돌릴 수단 없이 진행을 잃는다.
    func applySave(_ envelope: SaveEnvelope, todayTokensByProvider: [String: Int], todayDate: String,
                   hasUsageData: Bool) throws {
        try backupStateBeforeImport()
        state = SaveTransfer.rebasedForThisDevice(envelope.state,
                                                  current: state,
                                                  todayTokensByProvider: todayTokensByProvider,
                                                  todayDate: todayDate,
                                                  hasUsageData: hasUsageData)
        // 이전 개체 기준으로 진행 중이던 비동기·연출을 전부 무효화한다. activeGeneration 을 올리지
        // 않으면 먼저 떠 있던 라인 로드가 완료되며 새로 불러온 개체를 덮어쓴다.
        activeGeneration += 1
        currentLine = nil
        prefetchedLineID = nil
        justEvolvedTo = nil
        justGraduated = nil
        eventUntil = nil
        celebration = nil
        // 이전 개체 기준의 1회성 피드백(사탕 +XP·민트 성격)도 비운다 — 안 비우면 불러온 직후 남의
        // 개체에 대한 "+XP" 가 새 개체 위에 떠오른다.
        candyFeedbackAmount = 0
        mintFeedbackNature = nil
        displayState = state.active != nil ? .idle : .egg
        save()
        if state.active != nil { Task { await loadCurrentLine() } }
        AppLog.write("save imported from \(envelope.sourceDevice): dex=\(state.dex.count) lifetime=\(state.usedSinceInstall)")
    }

    /// 덮어쓰기 직전 현재 상태를 옆에 남긴다 — 잘못 불러왔을 때 되돌릴 수단.
    /// 슬롯을 하나만 쓰면 두 번째 불러오기가 **원본**을 덮어써, "잘못 불러왔으니 되돌린다"는 바로 그
    /// 상황에서 되돌릴 대상이 사라진다. 불러올 때마다 새 슬롯을 쓰고 오래된 것부터 정리한다.
    @discardableResult
    private func backupStateBeforeImport() throws -> URL {
        guard let data = try? JSONEncoder().encode(state) else { throw SaveTransferError.backupFailed }
        let dir = fileURL.deletingLastPathComponent()
        let backup = dir.appendingPathComponent(SaveTransfer.backupFileName(date: clock()))
        do {
            try data.write(to: backup, options: .atomic)
        } catch {
            AppLog.write("save import aborted — backup write failed: \(error)")
            throw SaveTransferError.backupFailed
        }
        pruneImportBackups(in: dir)
        return backup
    }

    /// 최근 N 개만 남기고 오래된 백업을 지운다. 파일명이 `yyyy-MM-dd-HHmmss` 라 사전순 = 시간순이다.
    private func pruneImportBackups(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let backups = names.filter { $0.hasPrefix(SaveTransfer.backupFilePrefix) }.sorted()
        guard backups.count > SaveTransfer.backupsToKeep else { return }
        for stale in backups.dropLast(SaveTransfer.backupsToKeep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(stale))
        }
    }

    // MARK: 영속
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }   // 파일 없음 = 신규 설치
        guard let s = try? JSONDecoder().decode(CompanionState.self, from: data) else {
            // 디코드 실패(전면 손상/미래 스키마) → fresh 로 시작하되, 다음 save() 가 원본을 덮어써 영구
            // 유실되기 전에 .corrupt 로 보존해 수동 복구 여지를 남긴다(도감 per-entry 격리로 못 살린 경우 대비).
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            AppLog.write("companion state decode failed — original backed up to \(backup.lastPathComponent), starting fresh")
            return
        }
        // 불러오기 경계와 같은 정규화를 디스크에서 읽을 때도 건다. 불러오기만 막으면 **이미 저장된**
        // 극단값은 그대로 남아, 앱이 매 기동마다 같은 값을 읽어 산술 트랩으로 죽는 상태를 못 벗어난다
        // (디코드는 *성공*하므로 위의 .corrupt 복구도 발동하지 않는다). 여기서 걸면 자가 복구된다.
        state = SaveTransfer.sanitized(s)
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)   // 부분 쓰기 손상 방지(펫 상태)
    }
}
