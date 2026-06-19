# CLAUDE.md

이 저장소에서 작업할 때의 운영 가이드. 설계 배경·마일스톤은 [`DESIGN.md`](DESIGN.md) 참조.

## 무엇인가
**한 SwiftPM 패키지 안의 두 개의 macOS 네이티브 앱** (Swift + AppKit, 코드는 거의 공유 안 함):
- **PixelEditor** (`Sources/PixelEditorApp`) — 레이어 기반 이미지 편집기. 우리 Core Image/Metal 엔진.
- **PDFEditor** (`Sources/PDFEditorApp`) — 계약서/문서 편집기. **PDFKit 전용**, 우리 모듈 의존 0.

> 제품 방향(확정): **사무/문서 작업 중심.** 로고는 래스터로 충분 — 벡터 노드편집·SVG 임포트는
> 만들지 않는다. PDFEditor가 점점 핵심(서명·도장·텍스트·페이지작업).

## 빌드 · 테스트 · 실행
```bash
swift build                 # 두 타깃 모두
swift test                  # 핵심 로직 보장(색 왕복·좌표·페인트·벡터·성능 베이스라인)
./scripts/make-app.sh       # PixelEditor.app + PDFEditor.app 조립 (NSDocument는 Info.plist 번들 필요)
open PixelEditor.app
open -a "$(pwd)/PDFEditor.app" some.pdf   # 파일 지정 실행
```
- **NSDocument 기능(저장/Undo/문서타입)은 `.app` 번들로 실행해야 동작.** 맨 바이너리 실행은 데모용만.
- 코드사인 안 된 개발 빌드라 Finder 더블클릭 기본연결은 안 잡힘(`open -a`/"다음으로 열기"는 됨).
- GUI 검증은 못 하므로: **로직은 헤드리스(테스트/`swift` 스니펫)로 먼저 증명**하고, 빌드→번들→
  `open`으로 띄운 뒤 사용자가 눈으로 확인하는 흐름.

## 모듈 구조 (의존 방향)
```
Core(leaf) ← ColorPipeline ← Rendering          # 공통 라이브러리
        ↖ PixelEditorApp (Core, ColorPipeline, Rendering 의존)
PDFEditorApp (의존 없음 — PDFKit/AppKit만)
```
- `Core`: 값 모델·좌표계·도구·페인트·벡터·텍스트 데이터 (순수, Codable/Sendable, 의존성 없음)
- `Rendering`: Core Image 재귀 합성기(`Compositor`) + 벡터/텍스트 CG 래스터화
- 두 앱은 같은 패키지일 뿐 **코드 공유 거의 없음**. PDFEditor에 우리 모듈 import 추가하지 말 것.

## 반드시 지키는 규약
- **Undo는 NSDocument의 `UndoManager`로.** 자체 스택으로 우회 금지(dirty/저장/Versions 깨짐).
  - 슬라이더 등 라이브 값: `dragStartModel` 캡처 → `commitLive(from:)`로 드래그 1회=undo 1회.
  - 페인트: 타일 before/after 델타. PDF 주석: `registerUndo`에 역연산(자기대칭).
- **PixelEditor 모델은 값타입.** `enum LayerNode`(raster/adjustment/group/vector/text), Codable.
  픽셀은 모델이 아니라 `ResourceStore`가 소유(핸들 UUID로 참조). (M3 actor화는 보류.)
- **좌표계**: document space = 좌하단 원점(CI/AppKit과 일치). 페인트 버퍼만 좌상단(`imageCoord`로 Y 플립).
  줌은 **device-pixel 기준**(레티나 정확). 틀리면 도구 전체 재작성 → 바꾸기 전 테스트 확인.
- **색**: 작업공간 = linear Display-P3. premultiply는 linear에서. `CAMetalLayer.colorspace` 명시.
  `Tests/ColorPipelineTests`가 왕복(≤1/255)을 잠금 — 깨지면 멈출 것.

## 함정 노트 (피로 배운 것들)
- **EPS는 macOS 26이 네이티브로 못 엶**(`NSEPSImageRep` 14.0부터 생성 불가). **Ghostscript 필수**
  (`/opt/homebrew/bin/gs`, 설치됨). PixelEditor가 EPS→PDF로 셸아웃 후 래스터화. ImageMagick 불필요.
- **PDFKit 캐시**:
  - 커스텀/주석 **삭제가 본문에 반영 안 됨**(내부 페이지 캐시). → 삭제 직전 `ann.bounds = .zero`로
    이전 영역을 무효화(깜빡임 없음). bounds 변경은 즉시 재렌더되는 성질 이용.
  - `pdfView.document = doc.pdf`에 **같은 객체 재할당은 무시됨** → 강제 리로드는 `nil` 후 재할당.
  - 커스텀 `ImageStampAnnotation`(draw 오버라이드)은 macOS 26 저장 시 외형 보존됨(검증함).
  - freeText는 박스 리사이즈해도 폰트 고정 → 오버레이에서 폰트를 함께 스케일(`setTextFrame`).
- **AppKit/SwiftUI 경계**: 캔버스·오버레이는 AppKit(이벤트/렌더), 패널·인스펙터는 SwiftUI
  (`NSHostingView`). 인라인 텍스트 편집 후 포커스 복귀는 `DispatchQueue.main.async`로(동기 호출은
  진행 중 포커스 변경에 덮임).
- **메뉴 단축키 vs keyDown**: 메뉴 keyEquivalent가 먼저 가로챔. ⌫를 도장 삭제에 쓰려고 페이지
  삭제의 ⌫를 제거함.

## 검증 보조 (헤드리스로 증명한 것들)
색 왕복, 좌표 변환, 페인트/플러드필, 벡터 bbox, 텍스트/PDF 주석 렌더·저장 왕복 등은 `swift` 스니펫·
테스트로 확인 후 UI를 붙였다. 새 PDF/렌더 기능은 **먼저 헤드리스로 저장 왕복·픽셀 확인**할 것.
