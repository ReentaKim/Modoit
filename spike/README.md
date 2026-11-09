# Modoit v2 스파이크 (Swift 네이티브)

[v2 아키텍처 검토안](../docs/dev/architecture-v2.md)을 확인하려고 만든 시험판입니다. 제품 코드가 아닙니다.

## 구성

| 경로 | 내용 |
|---|---|
| `macos/Sources/ModoitCore` | `vault.rs` 일부를 옮긴 Swift 코어(경로 검증, 원자적 쓰기, frontmatter·sticky, 제목·파일 이름, 첨부, 목록) |
| `macos/Tests/ModoitCoreTests` | `vault.rs` 테스트 13개를 같은 이름으로 옮김 + frontmatter 보존 2개 |
| `macos/Sources/ModoitSpike` | SwiftUI 3단 화면, WKWebView 편집기 브리지, NSPanel 스티키(공개 API만) |
| `editor-host/` | `src/editor`(TipTap)를 그대로 번들. Tauri API 두 곳만 shim으로 교체 |
| `build-app.sh` · `measure.sh` · `bench.sh` | 앱 빌드, 메모리 측정 |

```bash
spike/build-app.sh                      # → spike/build/ModoitSpike.app
spike/build/ModoitSpike.app/Contents/MacOS/ModoitSpike --vault <폴더> --sticky-kind web|native
swift test --package-path spike/macos    # 코어 테스트
spike/bench.sh                           # v0.3 vs v2 메모리 비교 (창이 잠깐씩 뜬다)
```

`editor-host` 번들은 빌드 산출물이라 저장소에 넣지 않습니다. `swift build` 전에 `build-app.sh`를 한 번 실행해야 합니다.

스파이크에서 뺀 것: 3-way 병합, 제목에 맞춘 파일 이름 변경, 파일 감시, 이동 시 링크 재작성, HTML 엔티티 제목 처리, 폴더 순서(layout.json), 설정 화면. frontmatter 판정은 YAML 파서 없이 근사합니다(본 구현에서는 파서 사용).

## 측정 결과 (2026-11-09)

환경: Apple Silicon, macOS 26.6.2, Xcode 27.2. 테스트 폴더는 메모 20개 + 열린 스티키 N개입니다(각 메모에 체크리스트·표·인용 포함).
메모리는 `footprint`의 phys footprint로 쟀습니다. 앱 프로세스와, 실행 뒤 새로 생긴 WebKit 프로세스(WebContent·Networking·GPU)를 더했습니다.

| 스티키 | v0.3 Tauri | v2 웹 스티키 (v2.0안) | v2 네이티브 스티키 (v2.x안) |
|---|---|---|---|
| 0개 | 176 MB | 145~167 MB | 142~166 MB |
| 5개 | 780 MB | 593~623 MB | 184~186 MB |
| 10개 | **1,391 MB** | 906~1,134 MB | **152~202 MB** |
| 스티키 1개당 | 약 120 MB | 약 75~100 MB | 약 5 MB |
| WebKit 프로세스 (10개일 때) | 13개 | 13개 | 3~4개 (메인 편집기 것만) |

v2의 실행부터 준비까지 걸린 시간(메인 편집기와 스티키 전부를 그릴 때까지)은 다음과 같습니다.

| 스티키 | v2 웹 | v2 네이티브 |
|---|---|---|
| 0개 | 433~869 ms | 400~429 ms |
| 5개 | 577 ms | 499~561 ms |
| 10개 | 804 ms | 509 ms |

- v0.3은 준비 신호를 낼 수 없어 실행 시간을 재지 않았습니다(12초 기다린 뒤 메모리만 잼).
- 같은 조건에서도 실행할 때마다 10~20% 차이가 납니다. 범위는 두 번 잰 값입니다.
- 앱 크기: v0.3 15 MB(universal) / 스파이크 1.4 MB(arm64만, 편집기 번들 포함). 아키텍처가 달라 직접 비교는 어렵습니다.

## 해석

1. **스티키를 웹으로 두면 Swift로 바꿔도 메모리 이득이 작습니다.** 스티키 1개당 비용이 120 MB에서 75~100 MB로 줄 뿐이고, WebContent 프로세스 수는 같습니다.
2. **스티키를 네이티브로 바꾸면 1개당 약 5 MB입니다.** 10개를 띄워도 v0.3의 약 1/7~1/9 수준입니다. ADR-13(스티키부터 네이티브)의 근거입니다.
3. 메인 창과 웹 스티키에서 TipTap이 v0.3처럼 그려집니다(표, 체크리스트). 열기만 해서는 파일을 쓰지 않는다는 규칙도 지켰습니다(스모크 테스트에서 diff 없음). 다만 **입력한 뒤 저장되는 Markdown은 아직 시험하지 않았습니다.** 같은 `ModoitEditor`와 `tidyMarkdown`을 쓰므로 같을 것으로 예상하지만, 확인이 필요합니다.
4. 코어 규칙은 Rust 테스트를 그대로 옮겨 Swift에서도 통과했습니다. 주의할 점이 하나 나왔습니다. Swift는 `\r\n`을 글자 하나로 다룹니다. 줄 단위 처리를 옮길 때마다 테스트로 확인해야 합니다.

## 남은 확인 (수동)

- **저장 결과**: 메인 창과 웹 스티키에서 입력·이미지 붙여넣기를 하고, 파일 내용이 v0.3에서 같은 조작을 했을 때와 같은지 비교합니다. 붙여넣은 이미지는 `attachments/`에 저장되고 상대 링크로 들어가야 합니다.

- **한글 입력(G-14)**: 같은 메모를 메인 창과 스티키에 띄웁니다. 스티키에서 한 줄을 쓰고, 이어서 메인 창에서 한글을 계속 칩니다. 이것을 웹 스티키와 네이티브 스티키(`--sticky-kind native`)에서 각각 확인합니다. 스파이크에는 파일 감시가 없어서, 다른 창의 변경은 메모를 다시 고를 때 반영됩니다.
- 네이티브 스티키는 지금 Markdown 원문을 그대로 편집합니다. 체크리스트와 굵게 같은 서식을 보이게 하려면 TextKit 2 작업이 필요합니다(v2.x 범위).
