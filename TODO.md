# TODO — PixelEditor 추가 기능 백로그

> 사무/문서 워크플로 중심(=[[CLAUDE.md]] 제품 방향). 위에서부터 하나씩: **작은 단위 구현 →
> 헤드리스로 로직 증명 → 빌드·번들·`open`으로 띄워 사용자 검증.** 각 항목 1개 = 1 커밋 단위.

## 추천 진행 순서 (쉽고 가치 큰 것부터)
1. ~~클립보드 붙여넣기~~ ✅ → 2. ~~회전 핸들~~ ✅ → 3. ~~자르기~~ ✅ → 4. ~~내보내기 옵션~~ ✅ →
5. ~~색조/노출~~ ✅ → 6. ~~커브/레벨~~ ✅ → 7. ~~블러/샤픈~~ ✅ → 8. ~~그라디언트~~ ✅ → 9. ~~브러시 개선~~ ✅ → 10. ~~레이어 마스크~~ ✅

> 진행 현황(2026-06-19): **백로그 1~10 전부 완료.** 조정 마스킹도 레이어 마스크로 해결됨.
> 모든 신규 보정은 `Adjustment` enum + `Compositor` + (패널 −1…1 슬라이더 | 인스펙터 전용 UI) 패턴.

---

## 생산성
- [x] **클립보드 붙여넣기 (⌘V)** — 파일/스크린샷을 새 래스터 레이어로. (파일 URL 우선 → 아이콘 아닌 원본)
  - `AppDelegate`(편집 메뉴), `PixelEditorDocument.pasteImage`/`pasteboardCGImage`.
- [x] **내보내기 옵션** — 포맷(PNG/JPEG) + 배율(100/75/50/25%, Lanczos) + JPEG 품질.
  - `ExportOptionsAccessory.swift`, `PixelEditorDocument.flattenedCGImage(scale:)`/`exportImage`.
- [x] **브러시 개선** — 패널 브러시 옵션(크기·경도·간격·플로우 슬라이더). 브러시/지우개 도구 선택 시 표시.
  - `BrushSettings.spacing`(Core), 브러시/도구 상태를 VM 단일소유(`DocumentViewModel.brush/currentTool`,
    컨트롤러는 통과 접근), `LayerPanelView.BrushOptionsView`. 간격은 `continueStroke`의 dab 샘플링에 반영.

## 편집 도구
- [x] **회전 핸들** — 선택 레이어 중심 회전(anchor=center 재매개화). Shift=15° 스냅.
  - `SelectionOverlayView`(회전 핸들), `PixelEditorDocument.beginRotate/updateRotate/commitRotate`,
    `layerDocumentQuad`(회전 포함 4코너). 회전 레이어 리사이즈는 비활성(왜곡 방지).
- [x] **자르기(Crop)** — 포토샵/사진식 조절 프레임(핸들 8 + 바깥 어둡게 + 3분할). C → 조절 → Enter.
  - `ToolKind.crop`, `CanvasView`(프레임 상태/핸들), `applyCrop`(translation −= origin), undo.
- [x] **그라디언트 도구** — ⇧G, 드래그 A→B **라이브 미리보기** → 놓으면 단일 undo. (정상 동작 확인)
  - `PaintCanvas.fillGradient`/`allTileIndices`, `beginGradient`/`updateGradient`/`commitGradient`, overlay 가이드 선.
  - **사용 팁**: 한쪽 끝→반대쪽 끝으로 **길게** 끌어야 부드럽다. 짧게 끌면 시작점 바깥이 단색이라 "채우기"처럼 보임(포토샵 동일).
  - follow-up: 2색 그라디언트(현재 색→투명만).
- [x] **레이어 마스크** — 비파괴 가리기(흰=보임/검정=숨김). 모든 레이어 타입 + 조정 레이어(조정 영역 제한).
  - `CommonLayerProps.maskHandle`(캔버스 크기 그레이스케일 paint canvas), `Compositor` 커버리지=마스크 R채널:
    콘텐츠=CIMultiplyCompositing, 조정=CIBlendWithMask. 패널 추가/제거/편집 토글, 브러시=숨김·지우개=보임.
  - *한계: 마스크는 캔버스 정렬(레이어 이동 시 따라가지 않음=unlinked). 소프트 엣지는 감마 약간 치우침(하드 마스크는 정확).*

## 보정 (조정 레이어 확장)
- [x] **색조/노출** — `Adjustment.hue`(CIHueAdjust)/`.exposure`(CIExposureAdjust). 패널 −1…1 슬라이더.
- [x] **커브/레벨** — `Adjustment.levels`(5파라미터 CI 체인) + `.curve`(단조3차 LUT→CIColorCurves).
  - 인스펙터 전용 UI: 레벨 5슬라이더 · `CurveEditor.swift`(그래프 점 편집). `ToneCurve.sample`(Core).
- [x] **블러/샤픈** — `Adjustment.blur`(CIGaussianBlur, extent clamp)/`.sharpen`(CISharpenLuminance).
  - 인스펙터 0…1 단일 슬라이더(`InspectorKind.radius`).

---
*참고: 보정은 `Adjustment` enum + `Compositor` + 인스펙터 슬라이더 패턴이 이미 있어서 case 추가가
대부분. 커브만 전용 UI 필요. 색관리(linear P3)·undo(라이브 코얼레스)·테스트 습관은 [[CLAUDE.md]] 따를 것.*
