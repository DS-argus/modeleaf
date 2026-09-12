<div align="center">
  <img src="../Assets/AppIcon/AppIcon-1024.png" alt="Modeleaf 앱 아이콘" width="160">
  <h1>Modeleaf</h1>
</div>

키보드만으로 빠르게 읽고 이동할 수 있는 macOS용 PDF 뷰어입니다. 원본 파일은 건드리지 않으며, 화면은 문서에 최대한 집중할 수 있게 간결하게 구성했습니다.

[English](../README.md)

## 이런 앱입니다

- **원본은 그대로 둡니다.** 주석, 편집, 저장 기능 없이 PDF를 읽는 데만 집중합니다.
- **키보드로 빠르게 움직입니다.** [Sioyek](https://github.com/ahrm/sioyek), [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf), [Vimium](https://github.com/philc/vimium), 그리고 Markdown TUI [Leaf](https://github.com/RivoLink/leaf)의 좋은 점을 참고해 읽기에 필요한 기능만 담았습니다.
- **내 방식대로 바꿀 수 있습니다.** 대부분의 단축키와 읽기 동작은 TOML 파일에서 설정할 수 있습니다.

## 주요 기능

- 키보드로 페이지 이동, 검색, 링크 열기, PDF 내장 목차 탐색
- macOS 네이티브 탭과 최근 문서 열기
- 명령 팔레트와 7가지 테마
- 화면 맞춤, 확대·축소, 회전, 이동 기록, 시스템 프린트
- TOML로 단축키와 읽기 동작 설정

## 설치

```sh
brew tap DS-argus/tap
brew trust DS-argus/tap
brew install --cask modeleaf
```

macOS 14 Sonoma 이상에서 사용할 수 있습니다.

> 아직 Apple 공증을 받지 않은 ad-hoc 서명 빌드입니다. 처음 실행할 때 차단되면 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**에서 한 번 허용해 주세요.

## 명령줄

Homebrew cask가 앱과 함께 `modeleaf` 명령을 설치합니다.

```sh
modeleaf                         # Modeleaf 실행 또는 활성화
modeleaf document.pdf            # 기존 앱에서 PDF 열기
modeleaf *.pdf                   # 여러 PDF를 탭으로 열기
modeleaf --new document.pdf      # 별도 앱 인스턴스에서 열기
modeleaf update                  # Homebrew를 통해 업데이트
modeleaf remove                  # 설정을 유지하고 제거
modeleaf --version               # 또는: modeleaf -v
modeleaf --help
```

glob은 Modeleaf에 전달되기 전에 셸에서 확장됩니다. 경로가 하이픈으로 시작하거나 명령 이름과 같다면 `modeleaf open -- <경로>`를 사용하세요.

## 업데이트

설치된 CLI와 cask를 함께 최신 상태로 맞추려면 Modeleaf의 업데이트 명령을 사용하세요.

```sh
modeleaf update
```

GitHub에 새 릴리스가 있는데 Homebrew가 이미 최신이라고 표시하면 메타데이터를 갱신한 뒤 다시 실행합니다.

```sh
brew update --force
modeleaf update
```

Modeleaf는 실행할 때 [GitHub Releases](https://github.com/DS-argus/modeleaf/releases)에서 새 버전만 확인합니다. 업데이트를 자동으로 설치하지는 않습니다.

## 기본 단축키

| 동작 | 키 |
|---|---|
| 스크롤 / 크게 스크롤 | `h` `j` `k` `l` / `d` `u` |
| 이전 / 다음 페이지 | `p` / `n` |
| 첫 페이지 / 마지막 페이지 | `gg` / `G` |
| 원하는 페이지로 이동 | `g`, 숫자, `Enter` |
| 뒤로 / 앞으로 | `Ctrl+o` / `Ctrl+i` |
| 목차 열기 / 항목 이동 / 바로 가기 | `t` / `J` `K` / 숫자 |
| 검색 / 다음 결과 / 이전 결과 | `/` / `Enter` / `Shift-Enter` |
| 링크 힌트 / 도착 위치 표시 설정 | `f` / `I` |
| 폭 맞춤 / 페이지 맞춤 | `w` / `F` |
| 확대·축소 / 회전 | `=` `-` / `[` `]` |
| PDF 전체 경로 복사 / Finder에서 보기 | `yy` / `of` |
| 열기 / 닫기 / 프린트 / 종료 | `⌘o` / `⌘w` / `⌘p` / `⌘q` |
| 이전 탭 / 다음 탭 | `P` / `N` |
| 패널 나누기 / 포커스 이동 | `Ctrl-b \|` `Ctrl-b -` / `Ctrl-h/j/k/l` |
| 테마 / 명령 팔레트 / 도움말 | `T` / `:` / `?` |

## 설정

원하면 다음 경로에 TOML 설정 파일을 만들 수 있습니다.

```text
~/.config/modeleaf/config.toml
```

키 표기에는 `D`(Command), `C`(Control), `A`(Option), `S`(Shift)를 사용합니다. 기본 설정 작성, 다시 불러오기, 초기화는 명령 팔레트에서 실행할 수 있습니다. 전체 명령과 기본값, 설정 규칙은 [CONFIG.md](../CONFIG.md)에 정리되어 있습니다.

## 직접 빌드하기

```sh
APP=$(Tools/build_release_app.sh | tail -n 1)
open "$APP"
```

개발 중에는 `swift run Modeleaf`로 실행할 수 있습니다. PR을 올리기 전에는 `Tools/verify.sh full`로 전체 검증을 실행합니다.

## 릴리스 준비 (관리자)

각 릴리스에는 `v` 접두사를 제외한 버전으로 `release-notes/<version>.txt` 파일을 추가합니다(예: `release-notes/0.13.0.txt`). 직전 릴리스의 실제 변경 사항을 바탕으로 2-5개의 간결한 영어 사용자용 bullet을 작성하세요. 비어 있지 않은 각 줄은 `- `로 시작하는 Markdown bullet이어야 하며 placeholder는 허용되지 않습니다.

일치하는 `v<version>` tag만 push하면 됩니다(예: `v0.13.0`). Workflow가 tag를 확인하고 테스트와 패키징을 거쳐 GitHub 생성 상세 내용 앞에 `## Highlights`를 하나만 넣은 draft를 만든 뒤 Homebrew를 갱신하고 publish합니다. 같은 tag를 다시 실행하면 draft만 갱신하며 생성된 상세 내용은 유지하고, 이미 publish된 release는 다시 쓰지 않습니다.

## 라이선스

Modeleaf는 [MIT License](../LICENSE)로 배포됩니다.

테마 색상 출처: [ThemeAttributions.md](../PDFReaderApp/Theme/ThemeAttributions.md)
