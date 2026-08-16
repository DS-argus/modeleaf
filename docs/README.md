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

## 업데이트

```sh
brew upgrade --cask modeleaf
```

새 버전이 있는데도 Homebrew에서 이미 최신이라고 나오면 다음 명령으로 갱신합니다.

```sh
brew update --force
brew upgrade --cask modeleaf
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

## 라이선스

Modeleaf는 [MIT License](../LICENSE)로 배포됩니다.

테마 색상 출처: [ThemeAttributions.md](../PDFReaderApp/Theme/ThemeAttributions.md)
