# Modeleaf

키보드 중심의 Vim 스타일 조작에 진짜 탭과 tmux 방식 패널을 더한 macOS 네이티브 **읽기 전용** PDF 뷰어입니다. 페이지가 항상 화면의 중심이며, 앱은 원본 파일을 절대 건드리지 않습니다.

[English README](../README.md) · [설정 가이드](CONFIG.md) · [Configuration reference](../CONFIG.md)

## 철학

- **언제나 읽기 전용.** 주석·편집·저장이 없습니다. 원본 PDF는 변경되지 않으며, 검색 강조조차 일시적인 UI일 뿐 파일에 기록되지 않습니다.
- **뷰어 우선.** 절제된 AppKit UI가 페이지를 둘러싸며, PDF 픽셀은 다시 칠해지지 않고 읽기 영역이 항상 지배적입니다.
- **키보드 우선.** 짧은 Vim 스타일 키 시퀀스로 모든 것을 조작합니다. [Sioyek](https://github.com/ahrm/sioyek)에서 아이디어를 빌렸지만, 읽기 흐름·네이티브 탭·분할 패널만 남긴 최소주의를 지향합니다.
- **완전한 설정, 엄격한 선언형.** 모든 명령과 수치를 하나의 TOML 파일에서 재설정할 수 있습니다. 설정은 데이터일 뿐 — 스크립트·매크로·플러그인은 없습니다.

## 설치

```sh
brew tap DS-argus/tap
brew trust DS-argus/tap        # Homebrew 6+는 서드파티 탭을 한 번 신뢰하도록 요구합니다
brew install --cask modeleaf
```

이미 설치되어 있다면 `brew upgrade --cask modeleaf`로 업데이트합니다(탭은 자동 갱신되며, 강제하려면 먼저 `brew update`).

macOS 14(Sonoma) 이상이 필요합니다. `⌘o`는 통합 열기 창을 엽니다 — 최근 연 PDF를 파일명 fuzzy 검색으로 고르거나 Browse… 행으로 네이티브 파일 대화상자를 열 수 있습니다. Finder → *다음으로 열기*나 앱에 파일을 끌어놓아도 되며, `⌘n`은 새 창, `⌘q`는 종료입니다.

> 이 빌드는 ad-hoc 서명이며 아직 Apple 공증(notarization)을 받지 않아, 첫 실행 시 macOS Gatekeeper가 차단합니다 — **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**에서 한 번 허용하세요.

### 소스에서 빌드

```sh
APP=$(Tools/build_release_app.sh | tail -n 1)   # 로컬 Release 앱, Apple 계정 불필요
open "$APP"
```

개발용으로 `swift run Modeleaf`도 가능하지만 최적화되지 않은 빌드라 시작이 느립니다.

## 사용법

문서는 탭에 담기고, 화면을 패널로 분할할 수 있으며, 모든 조작은 키보드로 이뤄집니다. 문서를 열면 1페이지가 보이는 영역에 한 페이지 맞춤으로 표시됩니다.

### 기본 키

| 동작 | 키 |
|---|---|
| 스크롤 | `h` `j` `k` `l` |
| 크게 스크롤 | `d` / `u` |
| 다음/이전 페이지 | `n` / `p` |
| 첫/마지막 페이지 | `gg` / `G` |
| 12페이지로 이동 | `g12` 입력 후 `Enter` |
| 링크 힌트 | `f` |
| 폭 맞춤 / 페이지 맞춤 | `w` / `F` |
| 확대/축소 | `=` / `-` |
| 왼쪽 / 오른쪽 회전 | `[` / `]` |
| 검색 | `/` 입력 후 `Enter` — `Esc`로 해제 |
| 새 창 | `⌘n` |
| 열기/닫기/종료 | `⌘o` / `⌘w` / `⌘q` |
| 다음/이전 탭 | `N` / `P` |
| 1…9번 탭 선택 | `⌘1` … `⌘9` |
| 오른쪽/아래로 분할 | `Ctrl-b \|` / `Ctrl-b -` |
| 패널 포커스 이동 | `Ctrl-h` / `Ctrl-j` / `Ctrl-k` / `Ctrl-l` |
| 다른 패널 모두 닫기 | `Ctrl-b o` |
| 테마 선택기 | `Shift-t` |
| 명령 팔레트 | `:` 또는 `⌘⇧P` |
| 설정 리로드 | `Ctrl-b r` |
| 키보드 도움말 | `?` |

`Enter` / `Esc`(프롬프트 확정 / 취소)와 `Enter` / `Shift-Enter`(다음 / 이전 검색 결과)는 **고정 키**로 항상 동작하며 재설정할 수 없습니다.

한 페이지 맞춤 모드에서는 `j`/`d`가 다음 페이지로, `k`/`u`가 이전 페이지로 이동합니다. 확대한 뒤에는 스크롤 키가 페이지가 화면을 넘치는 축으로만 움직이며, 빈 공간으로 밀려나지 않습니다.

### 탭과 패널

각 탭은 문서 하나를 담고, `+` 버튼이나 `⌘o`로 다른 문서를 엽니다. `Ctrl-b |`·`Ctrl-b -`는 포커스된 패널을 tmux 방식으로 제자리 분할합니다 — 최대 4개, 각 패널이 자체 탭과 문서를 가집니다. 분할하면 현재 페이지는 유지하되 작아진 패널에 맞춰 표시합니다. `Ctrl-b o`는 포커스된 패널만 남기고 모두 닫으며, `Ctrl-h/j/k/l`로 방향에 따라 포커스를 옮깁니다.

### 링크

링크는 클릭할 수 있습니다. 문서 내 링크는 뷰어 안에서 이동하고, 외부 URL은 브라우저로 엽니다. 원본 PDF는 절대 수정되지 않습니다.
`f`를 누르면 annotation 링크에 라벨이 표시되고, 라벨을 입력해 이동합니다. 문서 내 링크는 뷰어 안에서 이동하고 URL 링크는 브라우저로 엽니다. `Esc`로 취소합니다. 여러 줄로 감싼 링크에는 힌트가 하나만 표시되며, annotation이 있는 링크만 대상이므로 텍스트로만 인쇄된 URL은 클릭하거나 힌트로 열 수 없습니다. 그런 URL은 선택해 복사하세요. 스크롤하거나 창 크기를 바꾸면 힌트가 닫힙니다.

### 명령 팔레트

`:` 또는 `⌘⇧P`로 fuzzy 명령 검색을 엽니다. 입력하면 모든 리더 명령을 이름으로 필터링하고, `↑`/`↓`(또는 `Ctrl-j`/`Ctrl-k`)로 이동, `Enter`로 실행, `Esc`로 닫습니다. 각 행에 현재 단축키가 표시되며, 현재 맥락에서 실행할 수 없는 명령(문서 없음·단일 pane 등)은 목록에 흐리게 표시됩니다. 읽기 모드에서 `?`를 누르면 전체 단축키를 섹션별로 정리한 도움말 오버레이가 열립니다.

### 테마

내장 테마 6종: 다크 **Tokyo Night**, **Gruvbox Dark**, **Solarized Dark**, **Dracula**, **Everforest**와 라이트 **Catppuccin Latte**. `Shift-t`로 실시간 미리보기 선택기를 엽니다(`Enter` 확정, `Esc` 원복). 선택은 별도로 저장되어 다음 실행에 다시 적용됩니다. 테마는 앱 UI만 칠하며 PDF 페이지는 건드리지 않습니다.

## 설정

Modeleaf는 실행 시 선택적 파일 하나를 읽고 자동으로 만들거나 덮어쓰지 않습니다. 명시적인 **Write Default Config**와 **Reset Config** 명령 팔레트 명령만 이 파일을 씁니다:

```text
~/.config/modeleaf/config.toml
```

생성된 예시를 복사해 그 사본을 편집하세요:

```sh
mkdir -p ~/.config/modeleaf
cp PDFReaderApp/Resources/DefaultConfig.toml ~/.config/modeleaf/config.toml
```

```toml
[keymap]
"scroll.down" = ["j", "<Down>"]
"page.next"   = ["n"]
"tab.next"    = ["N"]

[navigation]
small_scroll_points = 56.0
zoom_factor = 1.12

[input]
prefix_timeout_ms = 350
prefix = "<C-b>"        # 패널 prefix; 어떤 바인딩이든 <prefix>가 이 값으로 확장됩니다
```

키 표기: `D` = Command, `C` = Control, `A` = Option, `S` = Shift (즉 `<D-o>` = ⌘o, `<C-j>` = Ctrl+j). `<prefix>`는 패널 prefix로 확장되므로 `prefix` 하나만 바꾸면 모든 패널 바인딩이 함께 바뀝니다. 테마는 TOML이 아니라 앱에서 고르며, 예전 `[theme]` 섹션은 경고와 함께 무시됩니다.

설정은 전체 단위로 검증됩니다: 실행 시 알 수 없는 키, 잘못된 바인딩, 충돌, 범위 초과 값이 하나라도 있으면 파일 전체를 거부하고 내장 기본값을 활성화하며, 모든 오류·경고가 상태 표시줄에 나타납니다. 파일이 없는 것은 정상입니다. **Reload Config**로 재시작 없이 유효한 수정 파일을 적용할 수 있으며, 기본 단축키 `Ctrl-b r`은 `prefix` 재바인딩을 따릅니다. 깨진 설정을 런타임에 리로드하면 적용하지 않고 이전 설정을 유지하며 상태 표시줄에 고정 오류를 표시합니다. 명령 팔레트에는 파일이 없을 때 쓸 수 있는 **Write Default Config**와 기존 파일을 `config.toml.bak`으로 백업한 뒤 기본값을 복원하는 **Reset Config**도 있습니다.

전체 액션 레지스트리, 키 토큰 문법, 검증 규칙, 모든 기본값은 **[CONFIG.md](CONFIG.md)**를 참고하세요.

## v1에 없는 것

북마크, 주석, 강조, 외부 명령, 스크립트, 플러그인, 매크로, OCR, 인쇄, 내보내기, 세션 영구 저장, 썸네일 사이드바가 없습니다. 이는 미완성 기능이 아니라 의도된 제품 제약입니다 — Modeleaf는 집중형 리더입니다.

## 기술 구성

macOS 14+ · 완전한 strict concurrency의 Swift 6 · AppKit + PDFKit · 액션·키·설정·탭·테마를 담은 Foundation 전용 코어(`PDFReaderCore`) · 고정 핀 의존성 `TOMLDecoder` 하나. 테마 팔레트 출처: [ThemeAttributions.md](../PDFReaderApp/Theme/ThemeAttributions.md).
