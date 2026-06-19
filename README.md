# LAAF Editors — PixelEditor · PDFEditor

한 SwiftPM 패키지 안의 **macOS 네이티브 앱 두 개**. 사무/문서 작업 중심.
설계 배경·구현 현황은 [`DESIGN.md`](DESIGN.md), 운영 가이드는 [`CLAUDE.md`](CLAUDE.md) 참조.

- **PixelEditor** — 레이어 기반 이미지 편집기 (자체 Core Image/Metal 엔진)
- **PDFEditor** — 계약서/문서 편집기 (PDFKit 전용, 우리 모듈 의존 없음)

> 두 앱은 같은 패키지의 두 실행 타깃일 뿐 코드는 거의 공유하지 않습니다.

## 요구사항
- macOS 14+ (Apple Silicon), Swift 6 / Xcode 26
- (선택) EPS 가져오기엔 Ghostscript: `brew install ghostscript`

## 빌드 · 테스트 · 실행
```bash
swift build                 # 두 타깃 모두
swift test                  # 핵심 로직(색 왕복·좌표·페인트·벡터·마스크·성능) — 39 테스트
./scripts/make-app.sh       # PixelEditor.app + PDFEditor.app 조립 (NSDocument는 Info.plist 번들 필요)
open PixelEditor.app        # 또는  open PDFEditor.app
```
> NSDocument 기능(저장/Undo/문서타입)은 `.app` 번들로 실행해야 동작합니다.

## 배포 (지인 테스트용 .dmg)
```bash
./scripts/make-dmg.sh       # 릴리즈 빌드 → 애드혹 서명 → 아이콘 포함 .dmg 생성
```
미서명(비공증) 빌드라 받는 사람은 첫 실행 시 Gatekeeper를 한 번 통과해야 합니다(.dmg 안 안내문 참고).
정식 배포(경고 없음)는 Apple Developer ID 서명 + 공증이 필요합니다.

## 주요 기능

**PixelEditor** — 도구 팔레트·상단 툴바·색상 웰·줌·레이어 썸네일 패널을 갖춘 표준 편집기 UI
- 열기/붙여넣기(이미지·PDF·EPS, DPI 선택) · 다층 합성(블렌드 5종·불투명도)
- 브러시·지우개·채우기·스포이드·**그라디언트**(라이브 미리보기) · 브러시 옵션(크기/경도/간격/플로우)·커서
- 보정 조정 레이어: 밝기·대비·채도·색조·노출·**레벨**·**커브(그래프 편집)**·블러·샤픈
- 벡터 도형·텍스트(인캔버스 편집) · 이동/리사이즈/회전 · 자르기 · **레이어 마스크**(비파괴, 조정 마스킹 포함)
- 페이지/캔버스/레이어 크기 직접 지정(앵커 그리드) · 페이지 경계·체커보드 배경
- 저장(.pxledit) · 내보내기(PNG/JPEG, 배율·품질)
- **AI(온디바이스 Vision)**: 배경 지우기 · 개체 자동선택→레이어 추출

**PDFEditor** — iLovePDF급 계약서 워크플로
- 다중 페이지 열기·썸네일·삭제/순서/회전/삽입(이미지·PDF)
- 서명(잉크)·도장/이미지·텍스트·화이트아웃 (이동/리사이즈/삭제/undo, 저장 보존)
- **AI(온디바이스 Vision)**: 문서 스캔(경계 감지→원근 보정) · OCR(한/영 텍스트 인식)

## 모듈 구조 (SwiftPM, 순환 차단)
```
Core/          값 모델(LayerNode·Document)·좌표계·타일·페인트·벡터·텍스트  — 의존성 없음
ColorPipeline/ 색공간·왕복 검증                                          — Core 의존
Rendering/     Core Image 재귀 합성 평가기(+레이어 마스크)               — Core, ColorPipeline 의존
PixelEditorApp 이미지 편집기 (MTKView 캔버스, SwiftUI 패널, Vision)
PDFEditorApp   PDF 편집기 (PDFKit/AppKit/Vision만 — 우리 모듈 의존 0)
Tests/         CoreTests · ColorPipelineTests · RenderingTests (39)
```

## 설계 원칙 (요약)
- 색 왕복(linear Display-P3, ≤1/255)·좌표계(device-pixel 줌)·타일은 테스트로 잠금
- Undo는 NSDocument의 UndoManager로만 · 모델은 값타입, 픽셀은 ResourceStore가 소유
- 로직은 헤드리스로 증명 후 UI 부착 (AI 인식 품질만 실기 확인)
