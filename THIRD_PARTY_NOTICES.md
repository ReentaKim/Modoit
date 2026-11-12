# Third-party notices

Modoit에 포함되었거나 Modoit이 사용하는 외부 구성요소와 라이선스입니다.

| 구성요소 | 용도 | 라이선스 |
|---|---|---|
| [Phosphor Icons](https://phosphoricons.com) (`@phosphor-icons/react`) | 앱 아이콘 | MIT |
| [Pretendard](https://github.com/orioncactus/pretendard) | 선택 가능한 본문 글꼴 (앱에 포함) | SIL Open Font License 1.1 |
| [TipTap](https://tiptap.dev) (`@tiptap/*`) | 편집기 | MIT |
| [Tauri](https://tauri.app) 및 플러그인 | 앱 셸 | MIT / Apache-2.0 |
| [tauri-nspanel](https://github.com/ahkohd/tauri-nspanel) | 스티키 플로팅 패널 | MIT / Apache-2.0 |
| [marked](https://marked.js.org) | Markdown 해석 | MIT |
| [yaml](https://eemeli.org/yaml/) | frontmatter 처리 | ISC |
| React | 화면 | MIT |
| notify, trash, window-vibrancy (Rust) | 파일 감시, 휴지통, 반투명 효과 | MIT / Apache-2.0 |

Pretendard는 SIL OFL 1.1에 따라 앱과 함께 배포되며, 글꼴 자체를 따로 판매하지 않습니다. **글꼴 파일은 Modoit의 MIT 라이선스가 아니라 SIL OFL 1.1을 따릅니다.** 원문: [licenses/Pretendard-OFL.txt](licenses/Pretendard-OFL.txt)

## v0.3 추가

| 패키지 | 라이선스 | 용도 |
|---|---|---|
| node-diff3 3.2.1 | MIT | 두 창 동시 편집 줄 단위 병합 |
| @tiptap/extension-details 3.33.0 | MIT | 토글 블록 |
| @tiptap/extension-blockquote 3.33.0 | MIT | 인용(`|` 입력 규칙) |
| @tiptap/extension-text-style 3.33.0 | MIT | extension-details의 peer 의존성 |

## v2.0 추가

| 구성요소 | 라이선스 | 용도 |
|---|---|---|
| [Yams](https://github.com/jpsim/Yams) 5.x | MIT | frontmatter(YAML) 읽기 |
| SF Symbols | Apple 사용 조건 | 화면 안 기호. 앱에 파일을 넣지 않고 시스템이 그린다. 앱 아이콘에는 쓰지 않는다 |

v2.0 앱에는 Tauri, tauri-nspanel, Rust 크레이트가 들어가지 않는다(v0.x에만 해당). 편집기 쪽 구성요소(TipTap, React, marked, Phosphor Icons, Pretendard 등)는 메인 편집기 번들에 그대로 들어간다.
