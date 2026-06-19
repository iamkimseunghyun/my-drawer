# 래스터 우선 레이어 편집기 — 설계 문서 v2

> macOS 네이티브 (Swift + AppKit + Core Image, Metal은 핫패스 한정)
> 래스터 우선 · 벡터는 v2 확장 슬롯으로 설계만 확보
> 작성일: 2026-06-17 · 개정: v1 적대적 교차검토(렌더링/아키텍처/스코프) 반영

---

## 0. 이 문서가 v1과 다른 점 (개정 요약)

v1("Pixelmator류 하이브리드 클론, Metal 직접 구현, 3~4개월")은 세 가지 독립 검토에서
같은 결함으로 수렴했다. v2는 그 결함을 정면으로 수정한다.

| v1의 문제 | v2의 결정 |
|---|---|
| 래스터+벡터 동시 → 솔로 스코프 킬러 | **래스터 우선.** 벡터는 `LayerNode`에 슬롯만 비워두고 v2로 연기 |
| "벡터를 줌 배율로 텍스처화"가 핵심 명제인데 회전/레티나/연속줌에서 깨짐 | 벡터 자체를 MVP에서 제외 → 이 문제를 v2로 이연. 좌표계는 device-pixel 기준으로 처음부터 설계 |
| 합성기를 Metal로 직접 구현 | **v1 합성은 Core Image**(색관리·타일·블렌드 내장). Metal은 브러시 스탬프 핫패스와 최종 flatten에만 |
| `protocol Layer: AnyObject` 클래스 모델 → 직렬화·동시성·undo 모두 깨짐 | **값타입 모델(`enum LayerNode`, Codable, Sendable) + 별도 `ResourceStore`(actor)** 가 GPU 리소스 소유 |
| 자체 Undo 스택으로 `UndoManager` 우회 | **`NSDocument` + 문서의 `UndoManager`** 로 dirty/저장/자동저장/Versions 연동 |
| 색공간·좌표계·타일을 M4에서 "정합성"으로 미룸 | **M0에서 못 박음**(레퍼런스 이미지로 증명) — 이 셋은 틀리면 전면 재작성 |
| 3~4개월 MVP | **래스터 MVP ~3~4개월(경험자 기준)**, 하이브리드는 9~15개월이라 정직하게 명시 |

---

## 1. 제품 정의 (먼저 좁힌다)

### 1.1 한 줄 정의
**레이어 기반 래스터 편집기** — 이미지를 열고, 레이어로 합성하고, 브러시/지우개/채우기로
칠하고, 기본 보정을 하고, 색 정확하게 PNG/JPEG로 내보낸다. **저장 가능한, 끝까지 동작하는
작은 도구**가 1차 목표.

### 1.2 차별점(wedge) — 확정됨
**"어떤 이미지든 쉽고 빠르게 편집·수정·배포한다."** 마찰 없는 속도와 손쉬운 내보내기/공유가
북극성이다. 즉 깊은 기능 수보다 **열기→편집→내보내기까지의 마찰 제거**에 우선 투자한다:
- 어떤 포맷이든 즉시 열림(드래그/더블클릭), 무거운 모달 없음
- 흔한 편집(자르기·보정·텍스트 없는 빠른 수정)이 1~2클릭
- 내보내기/공유가 한 동작(프리셋, 클립보드, 빠른 PNG/JPEG)

> 설계 결정 시 항상 "이게 편집→배포 마찰을 줄이나?"를 기준으로 판단한다.
> 차별점 없는 일반 편집기는 만들지 않는다.

### 1.3 MVP 범위 (할 것)
1. 이미지 열기/보기(HEIC/PNG/JPEG/TIFF), 줌·팬, 레티나 정확
2. 레이어: 추가/삭제/순서/표시/잠금/opacity + **블렌드 모드 5종**(Normal/Multiply/Screen/Overlay/SoftLight)
3. 래스터 도구: **브러시·지우개·채우기·스포이드**, 기본 선택(사각/올가미)
4. 조정: **밝기·대비·채도·커브**(조정 레이어)
5. **저장/열기(자체 포맷) + PNG/JPEG 내보내기** — M2 끝에 이미 동작
6. 색 정확(linear 작업공간) + 타일 기반 — **1일차부터**

### 1.4 비범위 (안 할 것 — 명시적 연기)
벡터(펜/노드편집/SVG) · 텍스트 레이어 · 그룹 blend isolation · 레이어 마스크(피처링) ·
PSD/RAW 가져오기 · GPU 직접 테셀레이션 · 접근성(VoiceOver) · 멀티 윈도우 탭 ·
→ 전부 v2 이후. 단, 모델/아키텍처는 이들을 **나중에 받을 수 있도록** 설계한다(§3.5).

---

## 2. 기술 스택

| 영역 | 선택 | 근거 |
|---|---|---|
| 언어 | Swift (Swift 6 동시성 켜고) | 데이터 레이스를 컴파일 타임에 차단 |
| 문서/앱 골격 | **`NSDocument` 기반 document app** | 저장·dirty·자동저장·Versions·최근파일 무료 |
| 캔버스 뷰 | AppKit `MTKView` 서브클래스 | 줌/팬/저지연 입력 직접 제어 |
| 패널/인스펙터/툴바 | SwiftUI (`@Observable`) | 빠른 UI, 단 캔버스 이벤트는 안 건드림 |
| **합성·필터 (v1)** | **Core Image** | 색관리·타일·GPU 블렌드 내장. MVP를 수개월 단축 |
| 브러시 핫패스/최종 flatten | **Metal** (직접) | 저지연 스탬프, 측정 후 필요한 곳만 |
| 벡터 래스터화 (v2) | Core Graphics → 텍스처 | v2 진입 시. GPU 테셀레이션은 더 나중 |
| 이미지 디코드 | Image I/O | HEIC/PNG/JPEG/TIFF |
| 색 관리 | ColorSync / ICC + CIContext working space | §4 |
| 최소 타깃 | macOS 14+ | `@Observable`, Metal 3, SwiftUI 상호운용 |

### 2.1 왜 Core Image 우선인가 (build-vs-buy)
검토 공통 결론: v1 합성기를 Metal로 직접 짜는 건 거꾸로다. Core Image는 이미 **색관리된
선형 작업공간 + 타일링 + GPU 블렌드 커널 그래프**를 제공한다. `CIFilter`(`CISourceOverCompositing`,
블렌드 모드 필터들, 보정 필터들)로 레이어 합성·조정을 구성하고, `CIContext`의 working color
space를 linear로 고정한다. **직접 Metal은 (a) 브러시 스탬프(저지연이 생명)와 (b) 최종 flatten/
export 경로에만** 둔다. 측정해서 Core Image가 느린 지점이 나오면 그때 Metal로 내린다.

> Skia를 쓰지 않는 이유: Swift 상호운용 비용 + "네이티브" 일관성 훼손. 대신 Apple 프레임워크로
> 같은 가치를 얻는다. PencilKit은 브러시 입력 저지연이 핵심 차별점이 되면 그때 평가.

---

## 3. 문서 모델 — 값타입 + 리소스 분리

v1의 `protocol Layer: AnyObject`는 직렬화(`[any Layer]` Codable 불가), SwiftUI 바인딩,
동시성에서 모두 깨졌다. v2는 **직렬화 가능한 값 모델**과 **GPU 리소스 스토어**를 분리한다.

### 3.1 값 모델 (Codable · Sendable · 스냅샷 가능)

```swift
struct Document: Codable, Sendable {           // 순수 데이터. GPU 리소스 없음
    var canvas: CanvasSettings
    var layers: [LayerNode]                     // z-order, 값 배열 → 스냅샷·diff 용이
    var selection: SelectionRef?                // 픽셀 선택은 핸들로 참조
}

struct CanvasSettings: Codable, Sendable {
    var pixelSize: SIMD2<Int>                   // device pixels 기준
    var dpi: Double                             // 메타데이터 전용(화면 렌더에 영향 없음)
    var workingColorSpace: WorkingColorSpace    // 항상 .linearP3 (§4)
}

// 폴리모픽 레이어를 enum으로 → Codable 자동 처리, 미래 case 추가가 곧 벡터 확장 슬롯
enum LayerNode: Codable, Sendable, Identifiable {
    case raster(RasterNode)
    case adjustment(AdjustmentNode)
    case group(GroupNode)                       // v1은 isolation 없는 단순 그룹만
    // case vector(VectorNode)   ← v2 슬롯 (지금은 비워둠)
    // case text(TextNode)       ← v2 슬롯
    var id: UUID { ... }
}

struct CommonLayerProps: Codable, Sendable {
    var id: UUID
    var name: String
    var transform: DecomposedTransform          // TRS 분해 저장(§3.3), 행렬은 렌더 시 합성
    var opacity: Float
    var blendMode: BlendMode
    var isVisible: Bool
    var isLocked: Bool
}

struct RasterNode: Codable, Sendable {
    var common: CommonLayerProps
    var pixels: TileStoreHandle                  // 실제 픽셀은 ResourceStore가 소유(핸들만 직렬화)
}
```

### 3.2 GPU/픽셀 리소스 스토어 (모델과 분리, actor 격리)

```swift
actor ResourceStore {                            // 모든 무거운 자원의 단일 소유자
    private var tileStores: [TileStoreHandle: TileStore]   // 래스터 픽셀(타일)
    private var ciImages: [UUID: CIImage]                  // 캐시된 합성 결과
    // MTLTexture / CIImage 의 생명주기·메모리압박 eviction 전담 (§8)
}
```

- **직렬화는 핸들(UUID)만.** 픽셀은 `ResourceStore`가 타일로 보관 → undo는 메타데이터의 값
  스냅샷 + 픽셀의 타일 델타로 자연 분리된다.
- 모델 mutation은 `@MainActor`. 렌더러는 **프레임마다 불변 스냅샷**(`Document` 값 복사 = 얕음)을
  받아 `ResourceStore`에서 타일을 읽는다. CPU가 쓰는 동안 GPU가 같은 텍스처를 읽는 레이스 차단.

### 3.3 변환은 분해(TRS)로 저장
`simd_float3x3` 원시 행렬 저장은 직렬화·히트테스트·핸들 UI·누적 오차에 불리. 모델은
`DecomposedTransform { translation, rotation, scale, anchor }`(Double)로 저장하고 **렌더 시점에만**
행렬로 합성. 큰 캔버스(8K)에서 좌표 지터 방지 위해 모델 좌표는 Double, GPU 경계에서만 Float.

### 3.4 선택 영역
`SelectionRef` → `ResourceStore`의 **선형 커버리지 마스크**(안티에일리어싱·서브픽셀, sRGB 아님).
8-bit 하드 마스크는 톱니 생김. v1은 사각/올가미만(피처링은 v2).

### 3.5 벡터 확장 슬롯 (지금 비워두지만 깨지지 않게)
`LayerNode`에 `.vector`/`.text` case를 **추가만 하면** 되도록 합성 평가기(§5)를 처음부터
"노드 → CIImage" 인터페이스로 추상화한다. 래스터는 "타일 → CIImage", 벡터는 나중에
"패스 → (CG 래스터화) → CIImage"로 같은 인터페이스에 꽂힌다. **이 추상화가 v2 확장의 전부.**

---

## 4. 색 관리 — M0에서 못 박는다 (틀리면 전부 재작성)

검토 공통 경고: 색공간을 나중에 "정합성"으로 미루면 그 전에 만든 모든 블렌드/보정/브러시가
미묘하게 틀린 채 쌓인다. **M0에서 레퍼런스 이미지로 왕복을 증명**하고 시작.

### 4.1 파이프라인 규칙
1. **작업 색공간 = linear Display-P3.** 모든 합성/블렌드/필터 수학은 여기서.
2. **입력**: 디코드 시 원본 ICC → linear P3로 변환. sRGB보다 넓은 입력(향후 RAW)은 감마 매핑
   정책 필요(v1은 sRGB/P3 입력만 → clip).
3. **알파**: 저장은 premultiplied지만 **premultiply는 linear 공간에서**. (premultiplied-sRGB를
   linear화하면 틀림 → unpremul → linearize → premul 순서 고정.)
4. **블렌드 수학은 unpremultiplied 색에서.** 비분리 모드(Overlay/SoftLight/Hue/Sat/Color/
   Luminosity)는 premultiplied 값에 직접 적용하면 가장자리 색 틀림. → Core Image 블렌드 필터는
   이걸 올바르게 처리하므로 v1에서 직접 구현 안 함(= Core Image 채택의 또 다른 이득).
5. **마스크는 선형 커버리지**로 샘플(`*_sRGB` 포맷 금지 — GPU가 잘못 감마 디코드).
6. **출력**: 최종에만 linear P3 → 실제 `NSScreen` 프로파일로 ColorSync 변환(감마 적용).
   디스플레이를 P3라고 가정하지 말 것.

### 4.2 드로어블/CIContext 설정 (가장 흔한 색 버그 지점)
- `CAMetalLayer.colorspace` / `pixelFormat` 명시 설정. 인코딩을 셰이더에서 할지 `*_sRGB`
  드로어블에 맡길지 한쪽으로 고정.
- `CIContext(mtlDevice:options:)`에 `workingColorSpace = linear P3`, `outputColorSpace = display`.
- HDR 대비 `wantsExtendedDynamicRangeContent`는 v1 비범위(SDR 고정), 단 16-bit float 중간 버퍼는 유지.

### 4.3 정밀도
- 중간 합성/보정: `RGBA16Float` — 단 **레이어당 풀캔버스로 들지 않는다**(§8 메모리). 합성
  누적 버퍼와 활성 필터 체인에만 16F, 휴면 래스터는 타일로 보관.

---

## 5. 합성 — Core Image 그래프 + 재귀 평가기

### 5.1 평가 구조 (평면 루프 아님)
v1의 back-to-front 평면 루프는 조정 레이어("아래 누적 결과를 읽어 변형")와 그룹을 표현 못 한다.
v2는 **재귀 평가기**: `LayerNode` 트리를 돌며 각 노드를 `CIImage`로 환산.

```
func render(_ nodes: [LayerNode], below: CIImage) -> CIImage
  acc = below (보통 투명/배경)
  for node in nodes (뒤→앞):
    switch node:
      raster:     src = tilesToCIImage(node); acc = blend(node.blendMode, node.opacity, src, over: acc)
      adjustment: acc = node.filter.apply(to: acc)          // acc를 입력으로 → CI가 ping-pong 자동 처리
      group:      sub = render(node.children, below: 투명)   // 그룹은 별 버퍼
                  acc = blend(node.blendMode, node.opacity, sub, over: acc)
  return acc
```

- 조정 레이어가 "아래를 읽어 다시 쓰는" 문제는 Core Image가 필터 그래프로 알아서 처리(직접
  Metal에서 같은 타깃 read+write 금지 문제를 CI가 흡수).
- v1 그룹은 **isolation 없음**(단순 묶음). isolation/클리핑 마스크는 v2.
- 블렌드 모드는 CI 내장 필터(`CIMultiplyBlendMode` 등) 매핑 → 비분리 모드 수학을 직접 안 짬.

### 5.2 좌표계 — M0 확정 (틀리면 전 도구 재작성)
- **document space**(픽셀, 원점/ y축 규약 고정) ↔ **view space**(줌·팬·`backingScaleFactor`).
- 벡터/도구가 받는 좌표는 항상 document space(역변환 후). 줌은 **device pixel = 논리줌 ×
  backingScale**로 계산(레티나·디스플레이 간 이동 대응, `viewDidChangeBackingProperties`).

### 5.3 타일 — M0에 인터페이스 확보 (구현은 점진)
- **인터페이스는 M0부터** 존재(첫 구현은 1타일이어도). 안 그러면 대용량에서 전면 재작성.
- 저장: N개의 개별 `MTLTexture` 금지 → **sparse texture / `MTLHeap` 아틀라스 / 타일 배열**.
- 타일 경계 심 방지: **apron(gutter) 픽셀** 둘러 샘플. 256² 숫자는 브러시 크기·VM 페이지·캐시
  트레이드오프로 재유도(고정 상수로 단정 안 함).
- 휴면 래스터는 sparse — 닿은 타일만 할당.

---

## 6. 도구 시스템 — 입력은 압력까지 받는다

v1 `Tool`의 `mouseDown(_: CanvasPoint)`는 압력/틸트/속도를 받을 수조차 없어 브러시 요구와 모순.

```swift
struct ToolEvent {
    var documentPoint: SIMD2<Double>      // 역변환된 문서 좌표
    var pressure: Float                    // NSEvent.pressure / tabletPoint (Force Touch와 구분)
    var tilt: SIMD2<Float>
    var velocity: SIMD2<Double>
    var timestamp: TimeInterval
    var coalescedSamples: [SIMD2<Double>] // 스트로크 충실도용 합쳐진 샘플
}

protocol Tool {
    mutating func began(_ e: ToolEvent, _ ctx: ToolContext)
    mutating func moved(_ e: ToolEvent, _ ctx: ToolContext)
    mutating func ended(_ e: ToolEvent, _ ctx: ToolContext) -> EditCommand?   // undo 커맨드 반환
}
```

- `NSEvent.tabletPoint`(Wacom)와 트랙패드 Force Touch `pressure`는 별 소스 → 분리 처리.
- 브러시 스탬프: 경로를 간격 샘플 → Metal로 타일에 스탬프(저지연), 닿은 타일만 dirty.
  압력/속도 → 두께/불투명도. coalesced 샘플로 곡선 충실도 확보.

---

## 7. 앱 생명주기 · Undo — NSDocument에 올린다

검토 최우선 지적: 자체 Undo 스택으로 `UndoManager`를 우회하면 dirty/⌘S/자동저장/Versions/
닫기 확인이 전부 끊겨 **무음 데이터 손실**.

### 7.1 3계층 분리
- **`NSDocument`**(모델 + `undoManager` + 선택) — 1개
- **`NSWindowController`** — 윈도우당 N개
- **`CanvasViewModel`** — 뷰당 N개: 줌/팬/활성 도구/호버 (**undo 대상 아님**, 문서 dirty 아님)

> v1처럼 "Document Controller"에 줌·도구까지 넣으면 멀티뷰에서 깨지고 줌이 undo에 섞인다.

### 7.2 Undo
- 변경 = `EditCommand { apply / revert }`를 문서 `undoManager`에 `registerUndo`로 등록 → 동시에
  `updateChangeCount(.changeDone)` 호출(dirty 연동). `UndoManager`는 클로저만 등록하므로
  타일 델타 메모리 전략과 무관 — **우회할 이유 없음.**
- 픽셀: 전체 스냅샷 아닌 **변경 타일의 압축(zstd) before/after 델타**, dirty-rect로 coalesce.
- 브러시 1스트로크 = `beginUndoGrouping`~`endUndoGrouping` 1커맨드(드래그업에 커밋).
- 메타데이터(opacity/순서/그룹): 값 스냅샷이라 저렴. 벡터/텍스트 편집 undo는 v2에서 별 granularity.

### 7.3 저장 포맷 + 안전성
- 자체 패키지(`NSFileWrapper` 디렉터리): `manifest.json`(레이어 트리·메타) + `tiles/`(zstd 타일) +
  `thumbnails/`.
- **내구 문서(버전드·atomic)와 휴면 타일 캐시(앱 caches, mmap, 버전 안 함)를 분리.** 페이지아웃은
  절대 라이브 패키지 안에 쓰지 않음(Versions/iCloud가 불일치 캡처 → 손상).
- 패키지 외부 접근은 `NSFileCoordinator`. 자동저장 granularity는 큰 패키지 통짜 재기록을 피하도록
  설계(증분 child wrapper).

### 7.4 샌드박스 · 권한 (지금 결정)
- 샌드박스 + entitlements(`files.user-selected.read-write`), 외부 참조 리소스는
  **security-scoped bookmark**(manifest에 경로 문자열만 저장하면 재오픈 불가). MAS vs Developer-ID
  배포를 §11에서 확정.

---

## 8. 성능 · 자원

| 문제 | 대책 |
|---|---|
| 8K 다층 메모리 | 레이어당 풀캔버스 16F 금지. sparse 타일 + 16F는 누적/활성필터만. `recommendedMaxWorkingSetSize` 대비 예산 |
| 메모리 압박 | `DispatchSource.makeMemoryPressureSource`(.warning/.critical) → 타일 eviction. `MTLResource.setPurgeableState(.volatile)` / heap. fault-in 경로 정의 |
| 매 프레임 전체 재합성 | dirty 영역만, CI 결과 캐시 |
| 브러시 저지연 | Metal 스탬프, coalesced/predicted 입력, 입력 스레드↔모델↔렌더 스레드 소유 분리 + 트리플 버퍼 + semaphore |
| GPU device loss | 디바이스 변경/외장 디스플레이 이동 관찰 → 전 텍스처 새 디바이스로 재업로드. `drawableSize`/scale 갱신 |
| ProMotion 120Hz | 프레임 예산 8.33ms로 계산, `preferredFramesPerSecond` 설정 |

---

## 9. 로드맵 (정직하게)

> **헤드라인: 래스터 MVP(M0–M3) = 경험자 1인 풀타임 ~3~4개월.** Metal+Cocoa 이미징 경험이 없으면
> 학습세 1.5~2배. 하이브리드(벡터·텍스트·그룹isolation 포함)는 **추가 9~12개월** — 즉 풀 편집기는
> 12~18개월. 일정에 1.5~2배 컨틴전시 적용 권장.

### M0 — 기반 고정 (2~4주) ★틀리면 전면 재작성
- `NSDocument` 골격 + `MTKView` 캔버스 + 줌/팬(device-pixel·레티나 정확).
- **색 왕복 증명**: 테스트 이미지 sRGB→linearP3→display 왕복이 픽셀 정확함을 레퍼런스로 검증.
- **좌표계 확정**, **타일 인터페이스 존재**(1타일 구현 OK), CI working space 설정.

### M1 — 뷰어 + 레이어 합성 (3~4주)
- 이미지 열기 → RasterNode, 다층 합성(opacity + 5 블렌드, Core Image 그래프, 재귀 평가기).
- 레이어 패널(SwiftUI, `@Observable`), 값모델↔리소스스토어 경계 확립.

### M2 — 래스터 편집 + 저장 (4~6주)
- 브러시/지우개(Metal 스탬프, 타일 백킹, `ToolEvent` 압력)·채우기·스포이드.
- 기본 보정(밝기·대비·채도·커브) = 조정 레이어.
- Undo(타일 델타 + `UndoManager` + dirty 연동).
- **저장/열기(자체 포맷) + PNG/JPEG 내보내기** — 여기서 이미 "쓸 수 있는" 도구.

### M3 — 다듬기 + 사용성 (3~4주)
- 선택(사각/올가미), 블렌드 모드 마감, 메모리 압박/타일 eviction, device-loss 처리.
- 성능 예산 달성(목표 FPS·캔버스·GPU 명시), 레퍼런스 이미지 회귀 테스트.
- **여기서 래스터 MVP 완료 → 차별점(§1.2) 검증, 사용자 확보.**

### v2 (별도, 사용자 검증 후) — 벡터·텍스트·그룹isolation·마스크·SVG/PSD
- `LayerNode.vector` case 추가 + Core Graphics 래스터화 → 기존 평가기에 연결.
- 노드 편집 UX(최대 리스크), 텍스트(Core Text), 그룹 isolation/클리핑.

---

## 10. 위험 순위 (솔로가 좌초하는 지점)

1. **벡터 노드 편집 UX 늪** — v1에서 제외해 회피. v2 진입 전 별도 프로토타입으로 위험 격리.
2. **색 관리 두더지잡기** — M0 고정 + 레퍼런스 회귀 테스트로 차단.
3. **M4 절벽**(텍스트+그룹+마스크+포맷+색+성능 동시) — v1엔 없음. 저장을 M2로 앞당겨 분산.
4. **사용자/차별점 부재** — §1.2를 빌드 전에 확정. 이게 기술 문제보다 더 자주 죽인다.

---

## 11. 오픈 이슈 (빌드 전 결정)
1. ~~차별점 확정~~ → **완료(§1.2): "어떤 이미지든 쉽고 빠르게 편집·수정·배포".**
2. **배포 모델** — Mac App Store(샌드박스 강제) vs Developer-ID 직접.
3. **타깃 사용자 1명** 정의 — 누가, 왜 이걸 Pixelmator 대신 쓰는가.
4. v2 진입 조건 — 래스터 MVP가 실사용자 몇 명/어떤 신호일 때 벡터 착수.

---

## 12. 구현 현황

SwiftPM 패키지. `swift build` / `swift test` / `./scripts/make-app.sh && open PixelEditor.app`.

### M0 — 기반 (완료)
| 항목 | 상태 | 위치 |
|---|---|---|
| 값 모델(LayerNode enum, Codable/Sendable) | ✅ | `Sources/Core/Document.swift` |
| 좌표계(device-pixel 줌, 레티나 정확) + 테스트 | ✅ 증명 | `Sources/Core/Geometry.swift` |
| 타일 인터페이스 | ✅ (격자 placeholder) | `Sources/Core/Tile.swift` |
| 색 왕복 sRGB→linearP3→sRGB + 테스트 | ✅ 증명(Δ≤1/255) | `Sources/ColorPipeline` |
| Core Image 재귀 합성 평가기(벡터 확장 슬롯) | ✅ | `Sources/Rendering/Compositor.swift` |
| MTKView 캔버스 + 줌/팬 + CI 렌더 | ✅ (실기 확인) | `Sources/PixelEditorApp/CanvasView.swift` |

### M0.5 — 문서·앱 생명주기 (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| `NSDocument` 기반 아키텍처 + 앱 번들(Info.plist) | ✅ | `PixelEditorDocument.swift`, `Resources/Info.plist` |
| 3계층(Document→WindowController→CanvasView) | ✅ | `CanvasWindowController.swift` |
| 네이티브 패키지 저장/열기(.pxledit: manifest+png) | ✅ | `fileWrapper`/`read(from:)` |
| `UndoManager` + dirty 연동(undoable 이미지 가져오기) | ✅ | `setState`/`importImage` |
| 이미지 가져오기 → 래스터 레이어 → CI 합성 표시 | ✅ | `compose(into:)` |

### M1 — 다층 합성 + 레이어 패널 (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| `ResourceStore`(픽셀 단일 소유, 값모델과 분리) | ✅ (M3에 actor 승격) | `ResourceStore.swift` |
| 다층 합성 — 여러 래스터 레이어 + 블렌드 5종 + opacity | ✅ | `Compositor` + 패널 |
| SwiftUI 레이어 패널(NSHostingView, 분할뷰) | ✅ | `LayerPanelView.swift`, `CanvasWindowController.swift` |
| 단방향 바인딩(@Observable VM, 선택=뷰상태) | ✅ | `DocumentViewModel.swift` |
| 표시/블렌드/순서/삭제 = undoable, opacity 라이브+코얼레스 | ✅ | `PixelEditorDocument` edit 메서드 |
| 저장 시 참조 핸들만 직렬화(고아 픽셀 제외) | ✅ | `referencedHandles` |

### M2a — 페인팅 (브러시/지우개 + 타일 Undo) (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| 페인트 엔진(soft dab, premult sRGB, 타일 추적) + 테스트 | ✅ 증명(5 테스트) | `Sources/Core/Paint.swift` |
| 도구 타입(ToolEvent/ToolKind/BrushSettings, 스트로크 샘플러) | ✅ | `Sources/Core/Tools.swift` |
| 브러시·지우개 — 선택 페인트 레이어에 칠하기 | ✅ | `PixelEditorDocument` stroke 메서드 |
| 스트로크 1회 = Undo 1회 (타일 before/after 델타) | ✅ | `applyPaintTiles` |
| 새 페인트 레이어(⌘⇧N), 도구 전환(V/B/E), 크기([ ]), 색상(NSColorPanel) | ✅ | `CanvasWindowController`, `AppDelegate` |

> M2a 한계(노트): Metal 스탬프 미적용(CPU, 측정 후 M2b 최적화) · 재열기 시 페인트 레이어는
> 평탄화되어 재편집 불가 · 가져온 이미지 위 직접 칠하기는 새 페인트 레이어로 대체.

### M2b — 스포이드·채우기·내보내기 (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| 버킷 채우기(flood, 톨러런스) + 테스트 | ✅ 증명 | `Paint.floodFill` |
| 스포이드 — 합성 결과에서 색 추출 | ✅ | `colorAt` |
| PNG/JPEG 내보내기(평탄화, sRGB) — "쉬운 배포" | ✅ | `flattenedCGImage`/`exportImage` (⌘E) |
| 도구 키 I(스포이드)·G(채우기) | ✅ | `CanvasView.keyDown` |

### M2b-2 — 보정 조정 레이어 (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| 조정 레이어 추가(밝기/대비/채도) — 위에 얹혀 아래 보정 | ✅ | `addAdjustment` + 조정 메뉴 |
| 패널 강도 슬라이더(−1…1) — 라이브 + undo 코얼레스 | ✅ | `adjustmentBinding`, `LayerPanelView` |

> **M2 완료.** 편집→배포 루프: 열기·여러 레이어·블렌드/opacity·브러시/지우개·스포이드·채우기·
> 보정·저장(.pxledit)·내보내기(PNG/JPEG). 모두 undoable, 색 정확, 타일 단위 undo.

### V1a — 가벼운 벡터: 도형 레이어 (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| 벡터 데이터 모델(VectorShape/Node, `.vector` 슬롯) + 테스트 | ✅ 증명(4 테스트) | `Sources/Core/Vector.swift` |
| Core Graphics 래스터화 → CIImage (재귀 평가기에 연결) | ✅ | `Sources/Rendering/VectorRasterizer.swift` |
| 도형 그리기(사각/원/선, R/O/L) 드래그 + 라이브 + 단일 undo | ✅ | `beginShape`/`updateShape`/`commitShape` |
| 채움/스트로크는 현재 색, 저장/내보내기에 포함(평탄화) | ✅ | Compositor `.vector` |

> 결정: 통합형 가벼운 벡터(주석/도형). 풀 일러스트는 별도 앱(Core 패키지 공유)으로 후일.
> V1a 한계: 도형 선택/이동/편집 불가(드래그 생성만), 텍스트 없음, 줌인 시 약간 흐림(C1).

### 가져오기 — PDF/EPS (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| PDF 가져오기(CGPDFDocument 네이티브 래스터화) | ✅ 검증(렌더 비공백 확인) | `PDFImport.swift` `rasterizePDF` |
| EPS 가져오기(Ghostscript 있으면 EPS→PDF 자동 변환) | ✅ (gs 설치 시) | `epsToTempPDF`/`findGhostscript` |
| gs 미설치 시 안내(brew install ghostscript) | ✅ | `alertGhostscriptMissing` |

> 실측 확인: macOS 26은 EPS를 네이티브로 못 엶(NSEPSImageRep 14.0+ 생성 불가, sips/QuickLook 실패).
> EPS는 Ghostscript 필수. PDF는 의존성 0 네이티브.

### V1b — 벡터/텍스트 편집 (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| V1b-1 이동 도구(M) + 클릭 레이어 선택(히트테스트) | ✅ | `beginMove`/`topLayer` |
| V1b-2 리사이즈 핸들(선택 오버레이, transform.scale) | ✅ | `SelectionOverlayView`, `beginResize` |
| V1b-3 텍스트 레이어(클릭 생성/편집, Core Text 래스터화) | ✅ 검증(글리프 렌더) | `Text.swift`, `TextRasterizer.swift` |
| V1b-4 인스펙터(텍스트 폰트/크기/색, 도형 채움/테두리) | ✅ | `InspectorView.swift` |
| V1b-5 인캔버스 실시간 텍스트 편집(NSTextField 인라인) | ✅ | `CanvasWindowController` 텍스트 편집 |

> 통합 가져오기(⌘I): 이미지·PDF·EPS(gs 자동변환). 모든 신규 레이어 타입은 이동·리사이즈·
> 블렌드/opacity·저장·내보내기에 일관 적용. **V1b 완료.**

### 2a — 가져오기 해상도(DPI) (구현, 실기 검증 중)
| 항목 | 상태 | 위치 |
|---|---|---|
| 가져오기 다이얼로그 DPI 선택(72/150/300/600, 기본 300) | ✅ | `importImageDialog` accessory |
| PDF/EPS를 선택 DPI로 래스터화(상한 8000px) | ✅ | `importVector(at:scale:)` |

> 제품 방향(2026-06-18 확정): **사무/문서 작업 중심**(문서에 로고 첨부·PDF 편집·주석).
> 로고 벡터 직접 편집은 비범위 — 래스터 가져오기로 충분. SVG 벡터 임포트(2b)는 **드롭**.

### M3 — 견고성·성능 (측정 기반, 실용 버전)
**측정 결론(릴리즈 빌드):** 스탬프 ~0.1ms/dab → **Metal 브러시 재작성 불필요**(측정-우선이 리스크 차단).
makeCGImage 풀캔버스 = 3ms(2048²)/9ms(4000²) — 사무 문서 크기엔 충분.

| 항목 | 결정 | 위치 |
|---|---|---|
| 성능 베이스라인 회귀 테스트(스탬프/makeCGImage) | ✅ | `Tests/CoreTests/PaintPerfTests.swift` |
| 메모리 압박 처리(DispatchSource→파생 캐시 evict) | ✅ | `AppDelegate` + `handleMemoryPressure` |
| Metal 브러시 가속 | **보류**(측정상 불필요) | — |
| Swift 6 strict concurrency(actor화) | **보류**(단일스레드 앱, 고churn/저ROI) | — |
| GPU device-loss · 디스크 페이징 | **보류**(단일Mac 사무용, 저우선) | — |

> 사무/문서 용도엔 현 성능·안정성으로 충분. 초대형(4000²+) 연속 스트로크가 느껴지면 그때
> recompose 코얼레스(드로우 레이트로 makeCGImage 제한)를 적용. [[product-direction-office-raster]]

### 생산성 확장 — 사무/문서 편집 마찰 제거 (구현, 실기 검증 중)
TODO.md 백로그(쉽고 가치 큰 것부터)를 순서대로 구현. 모두 헤드리스로 핵심 로직 증명 후 UI 부착.

| 항목 | 상태 | 위치 |
|---|---|---|
| 클립보드 붙여넣기(⌘V) — 파일URL 우선(아이콘 아닌 원본) → 새 래스터 | ✅ 증명(왕복) | `pasteImage`/`pasteboardCGImage` |
| 회전 핸들 — 중심 회전(anchor=center 재매개화), Shift=15° 스냅 | ✅ 증명(3 테스트) | `beginRotate`/`layerDocumentQuad`, `SelectionOverlayView` |
| 자르기 — 포토샵식 조절 프레임(핸들8·바깥어둡게·3분할), C→Enter | ✅ 증명(crop 수학) | `ToolKind.crop`, `CanvasView`, `applyCrop` |
| 내보내기 옵션 — 포맷·배율(Lanczos)·JPEG 품질 | ✅ 증명(픽셀·인코딩) | `ExportOptionsAccessory`, `flattenedCGImage(scale:)` |
| 색조/노출 조정 레이어 | ✅ 증명(중립·방향) | `Adjustment.hue/.exposure`, `Compositor` |
| 레벨 조정 레이어 — 입력블랙/화이트/감마/출력 5슬라이더 | ✅ 증명(중립·방향) | `Adjustment.levels`, `Compositor.applyLevels`, 인스펙터 |
| 커브 조정 레이어 — 단조3차 LUT→CIColorCurves, 그래프 점 편집 | ✅ 증명(4 테스트+CI) | `ToneCurve.sample`, `Compositor.applyCurve`, `CurveEditor` |
| 블러/샤픈 조정 레이어 — 0…1 반경 단일 슬라이더 | ✅ 증명(중립·번짐) | `Adjustment.blur/.sharpen`, `InspectorKind.radius` |
| 그라디언트 도구(⇧G) — 드래그 A→B 라이브 미리보기, 색→투명 선형 | ✅ 증명(투영·페이드·undo·합성) | `PaintCanvas.fillGradient`, `beginGradient`/`updateGradient` |
| 브러시 옵션 — 크기·경도·간격·플로우 슬라이더 패널 | ✅ 증명(간격→dab 밀도) | `BrushSettings.spacing`, `LayerPanelView.BrushOptionsView` |
| 레이어 마스크 — 비파괴 가리기(흰=보임/검정=숨김), 조정 마스킹 포함 | ✅ 증명(4 테스트: 보임/숨김/부분/조정) | `CommonLayerProps.maskHandle`, `Compositor.applyMask/mixByMask` |
| 배경 지우기 (AI) — Vision 온디바이스 전경 마스크 → 레이어 마스크 | ✅ 마스크 쓰기 방향 증명(실분리 품질은 실기) | `BackgroundRemover`(VNGenerateForegroundInstanceMaskRequest), `PaintCanvas.writeCoverage` |

> 조정 레이어 UI 분기: 양방향(−1…1)=패널 강도 슬라이더 · 레벨/커브=인스펙터 전용 뷰 ·
> 블러/샤픈=인스펙터 0…1 슬라이더(`isSimpleSlider`/`isRadiusAdjust`로 구분).
> 그라디언트는 현재 색→투명만(2색은 follow-up).
> **TODO 백로그 1~10 전부 완료.** 마스크: 캔버스 정렬(unlinked), 커버리지=마스크 R채널(콘텐츠 multiply, 조정 BlendWithMask).
> 배경 지우기: Apple Vision 온디바이스(외부 AI/네트워크·키 불필요, macOS 14+). 전경 마스크를 레이어 마스크에
> writeCoverage(layerDocumentRect 위치)로 기록 → 비파괴, 브러시로 다듬기 가능. 회전 레이어·다중 주제 선택은 follow-up.

---

### PDFEditor — 별도 앱 (PDFKit) — P1 구현
결정(2026-06-18): iLovePDF급 PDF 편집은 **PDFKit** 위에. 둘이 코드를 거의 공유 안 하므로
**별도 앱 2개로 분리** — 같은 SwiftPM 패키지의 두 실행 타깃(`PixelEditor`/`PDFEditor`), 중복 없음.
- `Sources/PixelEditorApp` → 이미지 편집기(.pxledit). PDF/EPS는 ⌘I로 래스터 가져오기만.
- `Sources/PDFEditorApp` → PDF 편집기(.pdf). PDFKit 전용, 우리 모듈 의존 없음.
- 빌드: `./scripts/make-app.sh` → `PixelEditor.app` + `PDFEditor.app`.
"기존 텍스트 직접 수정"은 PDF 특성상 불가 → 텍스트 박스 추가/화이트아웃 방식(P3).

| 항목 | 상태 | 위치 |
|---|---|---|
| `.pdf` 문서 타입 등록(Editor) → PDF 편집 모드 | ✅ | `Info.plist`, `PDFEditDocument` |
| 다중 페이지 열기·썸네일·네비게이션(PDFView) | ✅ | `PDFEditWindowController` |
| 페이지 삭제/순서/회전/이미지·PDF 삽입 + PDF 저장 | ✅ 검증(왕복) | `PDFEditDocument` 페이지 작업 |
| 페이지 작업 undo | ✅ | registerUndo 역연산 |
| **P2a 서명**(잉크 그리기 → PDFAnnotation.ink) + undo | ✅ 검증(저장 왕복) | `InkOverlayView`, `addAnnotation` |
| **P2b 도장/이미지**(ImageStampAnnotation) + undo | ✅ 검증(저장 보존·방향) | `ImageStampAnnotation`, `addImageStamp` |
| 도장 선택/이동/리사이즈(핸들, Shift=비율고정) + 줌/스크롤 동기 | ✅ | `InkOverlayView`(stamp 모드) |
| 줌 컨트롤(버튼 + ⌘=/⌘−/⌘0) | ✅ | `zoomInAction` 등 |
| (PixelEditor) 리사이즈 Shift=비율고정 | ✅ | `updateResize(aspectLocked:)` |
| 도장 삭제(Delete) + 깜빡임 없는 갱신(bounds 무효화) | ✅ | `removeAnnotation` |
| **P3a 텍스트 추가**(freeText, 이동/리사이즈로 폰트 스케일/중앙정렬/더블클릭 편집) | ✅ 검증 | `addTextAnnotation`/`setTextFrame` |
| **P3b 화이트아웃**(흰 사각형으로 가리고 위에 텍스트 = 텍스트 "수정") | ✅ 검증(글자 가림) | `addWhiteout` |
| **문서 스캔 (AI)** — 사진 속 문서 경계 감지 → 원근 보정 → PDF 페이지 삽입 | ✅ 원근보정 증명(실감지 실기) | `DocumentScanner`(VNDetectDocumentSegmentation + CIPerspectiveCorrection) |
| **OCR (AI)** — 현재 페이지 텍스트 인식(한/영) → 클립보드 복사 + .txt 저장 | ✅ 인식 파이프라인 증명(합성 텍스트) | `TextRecognizer`(VNRecognizeTextRequest), `recognizeText` |

> PDFEditor 계약서 워크플로 완성: 서명·도장/이미지·텍스트·화이트아웃(이동/리사이즈/삭제/undo,
> 저장 보존) + 페이지(삭제/순서/회전/삽입). 모든 주석은 한 오버레이로 선택·조작.

**다음(PDF P3):** 텍스트 주석(자유 텍스트)·화이트아웃·도형·하이라이트.
P4: 병합/분할. (래스터 편집기로 ⌘I PDF 가져오기 = 합성용 별개 경로, 그대로 유지)

## 13. 현재 상태 요약 (feature-complete for 사무/문서 용도)
열기(이미지·PDF·EPS, DPI 선택)·붙여넣기(⌘V) · 레이어 합성(블렌드/opacity) · 브러시/지우개/채우기/스포이드 ·
보정(밝기/대비/채도/색조/노출/레벨/커브/블러/샤픈) · 벡터 도형(사각/원/선) · 텍스트(인캔버스 편집) ·
이동/리사이즈/회전 · 자르기 · 인스펙터 · 저장(.pxledit) · 내보내기(PNG/JPEG, 배율·품질) · 메모리 압박 대응.
핵심 픽셀/좌표/색/변환/커브 로직은 테스트로 보장(31 테스트).

---

## 부록 A. 모듈 구조 (SwiftPM, 순환 차단)

```
Core/         # LayerNode, Document 값모델, Codable — 의존성 없음(leaf)
Color/        # 색공간·ICC — Core만 의존
Resources/    # ResourceStore(actor), TileStore, CIImage 캐시 — Core, Color 의존
Rendering/    # CI 합성 그래프, 재귀 평가기, Metal 브러시 핫패스 — Resources 의존
Commands/     # EditCommand(undo) — Core 의존(추상)
Tools/        # Tool 구현 — DocumentEditing 프로토콜(추상)에만 의존, 구체 Document 직접 의존 금지
IO/           # import/export, NSFileWrapper 패키지 — Core, Color 의존
App/          # NSDocument, NSWindowController, 메뉴·검증
UI/           # CanvasView(MTKView), SwiftUI 패널 — App 통해 모델 접근
```
의존 방향: `UI → App → Tools → Commands → Core`, `Rendering → Resources → Core`. UI로 들어오는
역방향 의존 금지. SwiftPM 모듈로 순환을 컴파일 단계에서 불가능하게.
