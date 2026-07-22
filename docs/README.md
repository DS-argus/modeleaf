# PDF Reader

Vim 스타일의 간결한 명령 체계, 독립적인 탭, 엄격한 TOML 사용자 설정을 제공하는 macOS 네이티브 읽기 전용 PDF 뷰어입니다.

[English README](../README.md) · [설정 가이드](CONFIG.md) · [Configuration reference](../CONFIG.md)

상호작용 설계는 [Sioyek](https://github.com/ahrm/sioyek)의 한 가지 장점, 즉 짧은 다중 키 시퀀스를 활용하는 설정 가능한 키보드 중심 탐색에서 영감을 받았습니다. 하지만 Sioyek의 복제품은 아닙니다. V1은 읽기에 필요한 흐름만 남기고 macOS 네이티브 탭과 절제된 AppKit UI를 더해 PDF 콘텐츠가 항상 화면의 중심이 되도록 설계했습니다.

## 주요 기능

- 앱 내부, Finder의 **다음으로 열기**, 기본 `⌘O` 단축키로 로컬 PDF 열기
- 여러 문서를 서로 독립된 탭으로 관리
- 스크롤, 페이지 이동, 페이지 번호 직접 이동, 확대·축소, 화면 맞춤
- 탭별 검색 상태와 강조 표시를 사용하는 PDF 내장 텍스트 검색
- 모든 앱 명령을 하나의 안정적인 액션 레지스트리로 처리
- 모든 뷰어 액션, 탐색 수치, UI 테마를 TOML로 변경
- 저장이나 편집 경로를 노출하지 않는 읽기 전용 경계로 원본 파일 보존

기본 키 바인딩은 의도적으로 작게 유지합니다.

| 동작 | 기본 키 |
|---|---|
| 조금 스크롤 | `h` `j` `k` `l` |
| 크게 아래/위로 스크롤 | `d` / `u` |
| 다음/이전 페이지 | `n` / `p` |
| 첫/마지막 페이지 | `gg` / `G` |
| 12페이지로 이동 | `g12` 입력 후 `Enter` |
| 다음/이전 탭 | `gt` / `gT` |
| 검색 | `/` 입력 후 `Enter` |
| 다음/이전 검색 결과 | `Enter` / `Shift-Enter` |
| 검색 종료 | `Esc` |
| 확대/축소/초기화 | `+` / `-` / `=` |
| 너비/페이지 맞춤 | `w` / `f` |

27개 액션 전체 목록, 키 토큰 문법, 검증 규칙, 수치 범위, 기본 TOML은 [한국어 설정 가이드](CONFIG.md)에서 확인할 수 있습니다.

## V1 범위

V1은 북마크, 사용자 주석·하이라이트, 마크, 포털, 스마트 점프, 명령 팔레트, 외부 명령, 스크립트, 플러그인, 매크로, OCR, 인쇄, 내보내기, 세션 저장, 썸네일 사이드바, 연구 라이브러리 기능을 제공하지 않습니다. 검색 강조는 일시적인 뷰어 상태일 뿐 PDF 파일에 기록되지 않습니다.

이는 미완성 메뉴가 아니라 의도적인 제품 제약입니다. 추후 기능을 확장하더라도 안정적인 액션 경계, 엄격한 선언형 설정, 탭별 세션 격리, 읽기 전용 PDFKit 어댑터를 유지해야 합니다.

## 요구사항과 기술 스택

- macOS 14 이상
- Swift 6 언어 모드와 완전한 strict concurrency 검사
- 앱 셸과 responder chain을 위한 AppKit
- 네이티브 렌더링과 내장 텍스트 검색을 위한 PDFKit
- 액션, 키, 설정, 탭, 테마 상태를 담당하는 Foundation 전용 `PDFReaderCore`
- 앱 경계에 정확히 0.4.5로 고정된 `TOMLDecoder`
- Swift Testing, XCTest, XCUITest 타깃

기본 다크 테마는 **Catppuccin Mocha**, **Tokyo Night**, **Gruvbox Dark**, **Nord** 네 가지입니다. 테마는 앱 UI, PDF 주변 캔버스, 프롬프트, 상태 표시줄, 일시적인 검색 강조에 적용되며 PDF 페이지 픽셀 자체는 변경하지 않습니다.

## 빌드와 실행

### Xcode 앱

```sh
python3 Tools/generate_xcode_project.py
python3 Tools/validate_xcode_project.py
open PDFReader.xcodeproj
```

공유 `PDFReader` scheme을 선택하고 **My Mac**에서 실행합니다. 생성된 프로젝트는 macOS 14 이상을 대상으로 하며 앱, 코어, 테스트 지원, 단위·통합·UI 테스트 타깃을 포함합니다.

### SwiftPM 개발용 실행

```sh
swift package resolve
swift build -c debug
swift run PDFReader
```

`Build of product 'PDFReader' complete!`가 표시된 뒤에는 GUI 앱이 실행되는 동안 터미널이 명령을 계속 점유합니다. 이는 정상입니다. **PDF Reader** 창은 자동으로 열려야 하며, `⌘O`로 PDF를 선택하고 `⌘Q`로 정상 종료할 수 있습니다. 개발 프로세스를 터미널에서 바로 중단하려면 `Control-C`를 누릅니다.

Swift 패키지는 동일한 프로덕션 소스를 결정론적으로 빌드하고 테스트하기 위한 명령줄 실행 경로입니다. 유일한 서드파티 의존성은 `Package.resolved`에 고정되어 있습니다.

## 설정

앱은 시작할 때 다음 경로의 설정을 한 번 읽습니다.

```text
~/.config/pdf-reader/config.toml
```

앱이 이 파일을 자동으로 생성하거나 덮어쓰지는 않습니다. 사용자 설정을 시작하려면 다음 명령을 실행합니다.

```sh
mkdir -p ~/.config/pdf-reader
cp PDFReaderApp/Resources/DefaultConfig.toml ~/.config/pdf-reader/config.toml
```

예시:

```toml
[keymap]
"scroll.down" = ["j", "<Down>"]
"scroll.up" = ["k", "<Up>"]
"page.next" = ["n"]
"page.previous" = ["p"]
"tab.next" = ["gt"]
"tab.previous" = ["gT"]

[navigation]
small_scroll_points = 56.0
large_scroll_viewport_fraction = 0.85
zoom_factor = 1.12

[input]
prefix_timeout_ms = 600

[theme]
built_in = "tokyo-night"

[theme.overrides]
accent = "#7DCFFF"
```

설정은 순수한 선언형 데이터입니다. 알 수 없는 키, 잘못된 액션 ID, 프롬프트에서 안전하지 않은 바인딩, 충돌, 타입 오류, 허용 범위를 벗어난 값이 하나라도 있으면 사용자 파일 전체를 거부합니다. 이 경우 완전한 기본 설정이 원자적으로 활성화됩니다. 상태 표시줄은 모든 오류와 경고를 요약하며 툴팁과 접근성 도움말에서 전체 진단을 볼 수 있습니다. 파일이 없는 것은 정상이며 오류 없이 기본값을 사용합니다.

설정 변경 후 앱을 다시 시작해야 합니다. 실시간 다시 불러오기는 V1 범위에 포함되지 않습니다.

자세한 내용은 [설정 가이드](CONFIG.md)를 참고하세요.

## 아키텍처

```text
PDFReaderCore          Foundation 전용 정책과 결정론적 상태 머신
        ↑
PDFReaderApp           AppKit/PDFKit 어댑터와 composition root
        ↑
ReaderSessionStore     탭별 독립 세션의 유일한 수명 소유자
```

- 메뉴, 키 바인딩, 프롬프트 버튼, 테스트는 동일한 `ActionID`를 dispatch합니다.
- 창 범위 responder 경로가 키 입력을 소유하며 프롬프트는 네이티브 텍스트, dead key, IME 동작을 유지합니다.
- 각 탭은 하나의 `PDFDocument`, 하나의 `PDFView`, 하나의 직렬화된 검색 coordinator를 소유합니다.
- 잘못된 설정은 일부만 활성화되지 않습니다.
- PDFKit의 변경, 인쇄, 링크 액션, 상속된 편집 기능은 앱 경계에서 차단되고 회귀 테스트로 보호됩니다.

결정론적인 Xcode 그래프는 `Tools/generate_xcode_project.py`로 생성합니다. `PDFReader.xcodeproj/project.pbxproj`를 직접 수정하지 마세요.

## 검증

```sh
python3 Tools/generate_xcode_project.py
python3 Tools/validate_xcode_project.py
swift package resolve
swift build -c debug
swift build -c release
swift test
swift test -Xswiftc -warnings-as-errors
```

최종 검증에는 소스·인터페이스 범위 감사, 원본 PDF 해시 검사, 읽기 전용 폼·주석 검사, 15개 GUI 워크플로 정의, 네 가지 테마와 여섯 UI 상태를 조합한 24개 이미지 시각 검증이 포함됩니다. 기계 판독 가능한 요약은 [`artifacts/verification/final/verification-summary.json`](../artifacts/verification/final/verification-summary.json)에 있습니다.

## 타깃 구성

- `PDFReaderCore` — 액션, 키, 설정, 탭, 테마 상태
- `PDFReaderApp` — AppKit/PDFKit 앱과 어댑터
- `PDFReaderTestSupport` — 테스트에서만 사용하는 PDF fixture 생성 코드
- `PDFReaderCoreTests` — 순수 Swift Testing 테스트
- `PDFReaderAppTests` — AppKit/PDFKit 통합 및 결정론적 시각 테스트
- `PDFReaderUITests` — 서명된 GUI XCUITest 테스트

테마 팔레트 출처는 [`PDFReaderApp/Theme/ThemeAttributions.md`](../PDFReaderApp/Theme/ThemeAttributions.md)에 정리되어 있습니다.
