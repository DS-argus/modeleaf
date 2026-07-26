# Modeleaf 설정 가이드

[한국어 README](README.md) · [English configuration reference](../CONFIG.md) · [English README](../README.md)

선택 사항인 사용자 설정 파일은 `~/.config/modeleaf/config.toml`에 둡니다. 파일이 없으면 완전한 내장 기본 설정을 사용합니다. 설정은 선언형 데이터만 허용하며 액션, 매크로, 스크립트, 셸 명령, 플러그인을 정의할 수 없습니다.

## 불러오기와 활성화

- 앱은 설정 파일을 자동으로 만들지 않습니다. 사용자 설정이 필요할 때 아래의 생성된 예시를 복사하세요.
- 입력은 UTF-8이어야 하며 크기는 256 KiB 이하여야 합니다. 크기 검사는 TOML 파싱보다 먼저 실행됩니다.
- 어댑터는 파싱된 TOML 트리 전체를 재귀적으로 검사합니다. 알 수 없는 섹션, 키, 중첩된 leaf, 배열 요소, 비어 있는 알 수 없는 노드는 모두 오류입니다.
- 입력된 값은 sparse 모델로 디코딩하고 검증한 뒤 타입이 지정된 기본값 위에 덮어씁니다. 완성된 effective 설정도 다시 검증합니다.
- 활성화는 원자적입니다. 오류가 하나라도 있으면 모든 사용자 값을 버리고 완전한 내장 기본값을 활성화합니다. 파싱이 가능한 범위에서는 진단을 모아서 표시합니다. 경고만 있는 경우에는 fallback하지 않습니다.
- `PDFReaderCore.BuiltInDefaults`가 유일한 런타임 기본값 원천입니다. 번들 `DefaultConfig.toml`과 이 문서의 TOML은 생성된 예시이며 fallback 입력으로 사용되지 않습니다.

## TOML 스키마

다음 섹션과 값 형태만 허용합니다. 모든 필드는 선택 사항이며 생략한 필드는 타입이 지정된 기본값을 유지합니다.

```toml
[keymap]
"action.id" = ["key-sequence", "alternate"]

[navigation]
small_scroll_points = 48.0
large_scroll_viewport_fraction = 0.8
zoom_factor = 1.1

[input]
prefix_timeout_ms = 800

[theme]
built_in = "catppuccin-mocha"

[theme.overrides]
accent = "#89B4FA"
```

## 키 문법

- 출력 가능한 Unicode 문자는 논리 키로 사용합니다: `j`, `G`, `/`, `한`.
- 다중 키 시퀀스는 토큰을 이어 씁니다: `gg`, `zx`, `g12`.
- 이름 있는 키와 조합 키는 `<Esc>`, `<CR>`, `<S-CR>`, `<D-o>`, `<D-1>`, `<D-F12>`처럼 꺾쇠괄호를 사용합니다.
- modifier 순서는 `D`(Command), `C`(Control), `A`(Option), `S`(Shift) 순으로 정규화됩니다.
- 지원하는 이름 있는 키: Esc, CR, BS, Del, Tab/Backtab, 방향키, Home/End, PageUp/PageDown, Space, Backtick, LT/GT, Plus/Minus/Equal/Slash, F1…F24.
- Fn, Globe, 미디어 키, 전원 키, raw key code, 액션 체인, 일반적인 Vim 숫자 count는 문법에 포함되지 않습니다.
- 빈 배열은 해당 액션의 바인딩을 해제합니다. 빈 시퀀스 문자열은 잘못된 값입니다.
- `prompt.commit`과 `prompt.cancel`을 모두 해제할 수는 있지만 사용성 경고가 발생합니다. 화면의 프롬프트 버튼은 계속 사용할 수 있습니다.

## 입력 컨텍스트

전체 컨텍스트는 `navigation`, `pagePrompt`, `searchPrompt`, `searchResults`입니다. `document.open`과 `app.quit`만 global 액션입니다. 컨텍스트 액션은 활성 컨텍스트가 서로 겹치지 않을 때만 같은 시퀀스를 재사용할 수 있습니다.

## 안정적인 V1 액션과 기본값

| Action ID | 기본 키 | 컨텍스트 | 반복 |
|---|---|---|---|
| `document.open` | `<D-o>` | global | `suppressed` |
| `document.close` | `<D-w>` | `navigation`, `searchResults` | `suppressed` |
| `app.quit` | `<D-q>` | global | `suppressed` |
| `tab.next` | `N` | `navigation`, `searchResults` | `suppressed` |
| `tab.previous` | `P` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.1` | `<D-1>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.2` | `<D-2>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.3` | `<D-3>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.4` | `<D-4>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.5` | `<D-5>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.6` | `<D-6>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.7` | `<D-7>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.8` | `<D-8>` | `navigation`, `searchResults` | `suppressed` |
| `tab.select.9` | `<D-9>` | `navigation`, `searchResults` | `suppressed` |
| `scroll.left` | `h` | `navigation`, `searchResults` | `allowed` |
| `scroll.down` | `j` | `navigation`, `searchResults` | `allowed` |
| `scroll.up` | `k` | `navigation`, `searchResults` | `allowed` |
| `scroll.right` | `l` | `navigation`, `searchResults` | `allowed` |
| `scroll.largeDown` | `d` | `navigation`, `searchResults` | `allowed` |
| `scroll.largeUp` | `u` | `navigation`, `searchResults` | `allowed` |
| `page.next` | `n` | `navigation`, `searchResults` | `allowed` |
| `page.previous` | `p` | `navigation`, `searchResults` | `allowed` |
| `page.first` | `gg` | `navigation`, `searchResults` | `suppressed` |
| `page.last` | `G` | `navigation`, `searchResults` | `suppressed` |
| `page.prompt` | `g` | `navigation`, `searchResults` | `suppressed` |
| `prompt.commit` | `<CR>` | `pagePrompt`, `searchPrompt` | `suppressed` |
| `prompt.cancel` | `<Esc>` | `pagePrompt`, `searchPrompt` | `suppressed` |
| `search.prompt` | `/` | `navigation`, `searchResults` | `suppressed` |
| `search.next` | `<CR>` | `searchResults` | `allowed` |
| `search.previous` | `<S-CR>` | `searchResults` | `allowed` |
| `search.cancel` | `<Esc>` | `searchResults` | `suppressed` |
| `view.zoomIn` | `=` | `navigation`, `searchResults` | `allowed` |
| `view.zoomOut` | `-` | `navigation`, `searchResults` | `allowed` |
| `view.zoomReset` | unbound | `navigation`, `searchResults` | `suppressed` |
| `view.fitWidth` | `w` | `navigation`, `searchResults` | `suppressed` |
| `view.fitPage` | `f` | `navigation`, `searchResults` | `suppressed` |
| `pane.splitRight` | `<C-b>|` | `navigation`, `searchResults` | `suppressed` |
| `pane.splitDown` | `<C-b>-` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusLeft` | `<C-h>` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusDown` | `<C-j>` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusUp` | `<C-k>` | `navigation`, `searchResults` | `suppressed` |
| `pane.focusRight` | `<C-l>` | `navigation`, `searchResults` | `suppressed` |
| `pane.unsplit` | `<C-b>o` | `navigation`, `searchResults` | `suppressed` |

## 내장 값

- 작은 스크롤: `48 pt` (허용 범위 `1...512`)
- 큰 스크롤: `0.8 × viewport` (허용 범위 `0.1...2.0`)
- 확대·축소 배율: `1.10` (허용 범위 `1.01...2.0`)
- prefix timeout: `800 ms` (허용 범위 `100...2000`)
- 초기 테마: `catppuccin-mocha`
- 테마: `catppuccin-mocha`, `tokyo-night`, `gruvbox-dark`, `nord`

테마는 앱 UI, 오버레이, PDF 주변 캔버스에 적용되며 PDF 페이지 픽셀은 변경하지 않습니다.

새 문서는 1페이지를 한 페이지 맞춤 상태로 엽니다. 이 상태에서는 `j`/`d`가 다음 페이지, `k`/`u`가 이전 페이지로 이동합니다. 수동 확대 후에는 페이지가 화면을 넘는 축에서 먼저 페이지 내부를 이동합니다. 세로 경계에서 아래 방향 키를 한 번 더 누르면 다음 페이지 상단으로, 위 방향 키를 한 번 더 누르면 이전 페이지 하단으로 이동합니다. 가로로만 화면을 넘는 경우에는 세로 이동 키가 페이지를 바꾸지 않습니다. 실제 크기는 View 메뉴와 `view.zoomReset` 액션으로 사용할 수 있지만 기본 키는 비어 있습니다.

테마 override에서 사용할 수 있는 semantic token은 `background`(주변 캔버스와 기본 UI), `foreground`, `muted-text`, `border`, `accent`, `active-tab`, `inactive-tab`, `statusline`, `error`, `search-highlight`, `active-search-highlight`, `focus-indicator`입니다. 색상은 `#RRGGBB` 또는 `#RRGGBBAA` 16진수 형식이어야 합니다.

## 프롬프트에서 안전한 바인딩

프롬프트의 텍스트, dead key, IME 조합은 네이티브 텍스트 입력 경로에 남습니다. 프롬프트에서 활성화되는 바인딩은 해제되어 있거나 정확히 하나의 안전한 토큰만 포함해야 합니다. `<CR>`과 `<Esc>`는 프롬프트 lifecycle 액션용으로 예약되어 있으며 그 외 출력 가능한 조합 또는 Command가 없는 modifier 조합은 거부됩니다. 아래 두 생성 테이블은 호환성에 영향을 주는 V1 상수입니다.

<!-- BEGIN GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->
### PromptNativeReservationV1

- `<A-BS>`
- `<A-Del>`
- `<A-Down>`
- `<A-End>`
- `<A-Home>`
- `<A-Left>`
- `<A-PageDown>`
- `<A-PageUp>`
- `<A-Right>`
- `<A-S-BS>`
- `<A-S-Del>`
- `<A-S-Down>`
- `<A-S-End>`
- `<A-S-Home>`
- `<A-S-Left>`
- `<A-S-PageDown>`
- `<A-S-PageUp>`
- `<A-S-Right>`
- `<A-S-Up>`
- `<A-Up>`
- `<BS>`
- `<C-BS>`
- `<C-Del>`
- `<C-Down>`
- `<C-End>`
- `<C-Home>`
- `<C-Left>`
- `<C-PageDown>`
- `<C-PageUp>`
- `<C-Right>`
- `<C-S-BS>`
- `<C-S-Del>`
- `<C-S-Down>`
- `<C-S-End>`
- `<C-S-Home>`
- `<C-S-Left>`
- `<C-S-PageDown>`
- `<C-S-PageUp>`
- `<C-S-Right>`
- `<C-S-Up>`
- `<C-Up>`
- `<D-BS>`
- `<D-Del>`
- `<D-Down>`
- `<D-End>`
- `<D-Home>`
- `<D-Left>`
- `<D-PageDown>`
- `<D-PageUp>`
- `<D-Right>`
- `<D-S-BS>`
- `<D-S-Del>`
- `<D-S-Down>`
- `<D-S-End>`
- `<D-S-Home>`
- `<D-S-Left>`
- `<D-S-PageDown>`
- `<D-S-PageUp>`
- `<D-S-Right>`
- `<D-S-Up>`
- `<D-S-z>`
- `<D-Up>`
- `<D-a>`
- `<D-c>`
- `<D-v>`
- `<D-x>`
- `<D-z>`
- `<Del>`
- `<Down>`
- `<End>`
- `<Home>`
- `<Left>`
- `<PageDown>`
- `<PageUp>`
- `<Right>`
- `<S-BS>`
- `<S-Del>`
- `<S-Down>`
- `<S-End>`
- `<S-Home>`
- `<S-Left>`
- `<S-PageDown>`
- `<S-PageUp>`
- `<S-Right>`
- `<S-Tab>`
- `<S-Up>`
- `<Tab>`
- `<Up>`
<!-- END GENERATED: PROMPT_NATIVE_RESERVATION_V1 -->

<!-- BEGIN GENERATED: SYSTEM_KEY_RESERVATION_V1 -->
### SystemKeyReservationV1

- `<D-A-Esc>`
- `<D-A-S-q>`
- `<D-A-d>`
- `<D-A-h>`
- `<D-Backtick>`
- `<D-C-Space>`
- `<D-C-f>`
- `<D-C-q>`
- `<D-S-3>`
- `<D-S-4>`
- `<D-S-5>`
- `<D-S-Backtick>`
- `<D-S-Tab>`
- `<D-S-q>`
- `<D-Space>`
- `<D-Tab>`
- `<D-h>`
- `<D-m>`
<!-- END GENERATED: SYSTEM_KEY_RESERVATION_V1 -->

## 완전한 내장 TOML

아래 내용은 `PDFReaderCore.BuiltInDefaults`에서 생성됩니다. 번들 파일을 직접 수정하지 말고 `~/.config/modeleaf/config.toml`로 복사한 뒤 복사본을 수정하세요.

```toml
# Generated from PDFReaderCore.BuiltInDefaults. Do not edit this bundled copy.
# Copy it to ~/.config/modeleaf/config.toml and edit the copy.

[keymap]
"document.open" = ["<D-o>"]
"document.close" = ["<D-w>"]
"app.quit" = ["<D-q>"]
"tab.next" = ["N"]
"tab.previous" = ["P"]
"tab.select.1" = ["<D-1>"]
"tab.select.2" = ["<D-2>"]
"tab.select.3" = ["<D-3>"]
"tab.select.4" = ["<D-4>"]
"tab.select.5" = ["<D-5>"]
"tab.select.6" = ["<D-6>"]
"tab.select.7" = ["<D-7>"]
"tab.select.8" = ["<D-8>"]
"tab.select.9" = ["<D-9>"]
"scroll.left" = ["h"]
"scroll.down" = ["j"]
"scroll.up" = ["k"]
"scroll.right" = ["l"]
"scroll.largeDown" = ["d"]
"scroll.largeUp" = ["u"]
"page.next" = ["n"]
"page.previous" = ["p"]
"page.first" = ["gg"]
"page.last" = ["G"]
"page.prompt" = ["g"]
"prompt.commit" = ["<CR>"]
"prompt.cancel" = ["<Esc>"]
"search.prompt" = ["/"]
"search.next" = ["<CR>"]
"search.previous" = ["<S-CR>"]
"search.cancel" = ["<Esc>"]
"view.zoomIn" = ["="]
"view.zoomOut" = ["-"]
"view.zoomReset" = []
"view.fitWidth" = ["w"]
"view.fitPage" = ["f"]
"pane.splitRight" = ["<C-b>|"]
"pane.splitDown" = ["<C-b>-"]
"pane.focusLeft" = ["<C-h>"]
"pane.focusDown" = ["<C-j>"]
"pane.focusUp" = ["<C-k>"]
"pane.focusRight" = ["<C-l>"]
"pane.unsplit" = ["<C-b>o"]

[navigation]
small_scroll_points = 48.0
large_scroll_viewport_fraction = 0.8
zoom_factor = 1.1

[input]
prefix_timeout_ms = 800

[theme]
built_in = "catppuccin-mocha"
```
