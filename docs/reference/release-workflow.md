---
summary: "릴리스 실행 절차 — 문서·에셋 갱신 의무, 스크린샷 재생성 방법, release.sh 게이트의 함정."
read_when:
  - 버전을 배포할 때 (자연어 트리거 포함: "배포해줘", "릴리스 올려줘", "패치 배포")
  - release.sh 가 문서·에셋 경고나 하드 게이트로 중단됐을 때
  - UI 를 바꿔 스크린샷·랜딩을 갱신해야 할 때
---

# 릴리스 실행 절차

버전 결정 규칙과 트리거는 `CLAUDE.md` §릴리스에 있다. 이 문서는 그 다음의 *실행 세부*를 담는다.
체크리스트 원본은 `RELEASE.md`.

## 1. 문서·이미지 갱신 (매 릴리스 필수 — "할까요?" 묻지 말고 무조건 한다)

`./scripts/release.sh --check-only` 로 경고를 확인한 뒤 아래를 모두 반영한다.

- **README.md/ko/ja**: 기능 목록·how-it-works·스크린샷 참조.
- **랜딩(gh-pages orphan 브랜치) — 필수.** `git worktree add /tmp/ptb-ghpages gh-pages` → `index.html`
  기능 카드(f#) + i18n 사전(en/ko/ja 동시·키 정합) 갱신 → 커밋 → `git push origin gh-pages` →
  `git worktree remove`. (Pages 자동 재빌드. 커밋은 gh-pages log 모방 = `landing:` 프리픽스.)
- **스크린샷(`assets/`)**: UI(`Sources/PokeTokenBar/UI/`) 변경 시 재생성. 기존 방식 = **HTML 렌더**
  (팝오버 라이브 캡처 아님) — Chrome `--headless --screenshot --force-device-scale-factor=2` 로 다크
  팝오버를 720px PNG 로 그린다. 애니 GIF(home)는 프레임 합성 후 `gifsicle -O3 --lossy` 로 최적화
  (PIL 재인코딩 단독은 용량 팽창 주의). 언어별 이미지(`settings.png`/`-ko`/`-ja` 등) 각 README 참조.
- homebrew-tap cask caveat.

### Linux 전용 기능의 스크린샷

기존 스크린샷은 **HTML 렌더**(macOS 팝오버를 흉내 낸 마크업)로 만든다. Linux 에만 있는 기능
(박스·일지·업적·트레이너 카드·애칭)은 그 방식으로 만들면 **macOS 에 없는 화면을 macOS 스크린샷처럼**
보여 주게 되므로, 실제 GTK 창을 잡아 `assets/screenshot-linux-*.png` 로 둔다.

캡처 방법은 `.claude/NOTES.md` 의 헤드리스 절차 그대로다 — `.build` 바이너리(단일 인스턴스 lock 회피),
`PTB_STATE_DIR` 로 격리한 세이브, sway 에서 창을 floating 시킨 뒤 보고된 rect 로 `grim`. 패널이 타일링
되면 412pt 가 아니라 화면 전체가 잡혀 레이아웃 판단이 무의미해진다.

세이브를 보기 좋게 심어 두고 찍는다(성장 중간값·박스 두 마리·이로치 하나·일지 며칠치). 빈 상태의
스크린샷은 기능이 뭘 하는지 보여 주지 못한다.

### 게이트의 함정

- `release.sh` 문서검토는 *커밋된* 상태를 비교 → 스크린샷을 스테이징만 하면 경고 프롬프트가
  여전히 뜬다. 미리 커밋하거나 프롬프트에 `y`(스테이징분이 release.sh line 93-94 에서 릴리스 커밋에 함께 담김).
- **신규 기능 = 신규 에셋 (하드 게이트, 프롬프트로 못 넘김).** 직전 태그 이후 `Sources/**/UI/` 를 건드린
  `feat:` 커밋이 있는데 `assets/` 에 **새로 추가된** 파일이 없으면 `release.sh` 가 중단한다
  (**예외 없음** — 통과시키려면 에셋을 만들거나 커밋 타입을 바꿔야 한다). 기존 staleness 검사는 "에셋이 하나라도 바뀌었나"만
  보기 때문에 **기존 스크린샷만 다시 그려도 통과**한다 — 2.5.0 에서 플로팅 펫이 이미지 없이 나간 경로가
  정확히 이것이다(`settings.png` 를 갱신해 둔 탓에 조용히 통과). 갱신(stale)과 커버리지(신규)는 다른 질문이다.

## 2. 실행

릴리스 노트를 작성한 뒤 반드시 `main` 브랜치에서:

```bash
# 직전 릴리스 이후 변경을 요약해 노트 파일 작성
PTB_NOTES_FILE=/tmp/ptb-notes.md ./scripts/release.sh <version>
```

스크립트가 test-gate → 문서검토 → 범프 → 빌드검증 → 커밋·push → GitHub Release → cask → Pages 를
순서대로 수행한다.

## 3. 검증

완료 후 `brew upgrade --cask poke-token-bar` 로 실제 업그레이드 동작을 확인한다.
