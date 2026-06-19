import SwiftUI
import Observation
import Core

/// 레이어 패널이 관찰하는 뷰 모델 (설계 §7.1: 뷰당 상태).
/// 단방향: SwiftUI 액션 → 여기 → Document(undo+합성) → Document가 reload() 호출 → UI 갱신.
/// 선택(selectedID)은 view 상태라 undo 대상이 아니다.
@MainActor
@Observable
final class DocumentViewModel {
    weak var document: PixelEditorDocument?
    var rows: [LayerRow] = []                 // 화면 표시 순서(위=앞)
    var selectedID: UUID?

    // 도구/브러시 상태 (per-view, undo 대상 아님). 패널/팔레트가 직접 바인딩.
    var currentTool: ToolKind = .brush
    var shapeKind: VectorKind = .rectangle
    var brush = BrushSettings()
    var editingMask = false        // 켜면 브러시/채우기가 선택 레이어의 마스크를 칠한다.

    /// 도구 변경 시 캔버스 부수효과(크롭 세션·오버레이·브러시 커서) 동기화. 관찰 대상 아님.
    @ObservationIgnored var onToolChanged: (() -> Void)?

    /// 팔레트/단축키 공용 도구 선택.
    func selectTool(_ tool: ToolKind) { currentTool = tool; onToolChanged?() }
    func selectShape(_ kind: VectorKind) { shapeKind = kind; currentTool = .shape; onToolChanged?() }

    /// 선택 변경 시 호출(선택 핸들 오버레이 갱신용). 관찰 대상 아님.
    @ObservationIgnored var onSelectionChanged: (() -> Void)?

    // 인스펙터 상태 (선택 레이어, V1b-4)
    enum InspectorKind { case none, text, shape, levels, curve, radius }
    var inspectorKind: InspectorKind = .none
    var insLevels = Levels.identity
    var insCurve = ToneCurve.identity
    var insRadius: Double = 0           // 블러/샤픈 0…1
    var insRadiusTitle = ""
    // 페이지(문서) 크기
    var pageW = 0
    var pageH = 0
    // 레이어 크기 (모든 위치형 레이어)
    var selectedHasSize = false
    var insSizeW = 0
    var insSizeH = 0
    var insAspectLock = false
    @ObservationIgnored private var insAspect = 1.0
    var insText = ""
    var insFontName: String?
    var insFontSize: Double = 48
    var insColor: RGBA8 = .red
    var insFill: RGBA8?
    var insStrokeColor: RGBA8?
    var insStrokeWidth: Double = 3

    private var dragStartModel: Document?

    init(document: PixelEditorDocument?) {
        self.document = document
        reload()
    }

    /// Document 모델 → 표시용 행(top-first). Document 변경 후 호출된다.
    func reload() {
        if let p = document?.model.canvas.pixelSize { pageW = p.x; pageH = p.y }
        let layers = document?.model.layers ?? []
        rows = layers.reversed().map { node in
            let c = node.common
            var isAdj = false
            var adjValue: Float = 0
            var simpleSlider = false
            if case .adjustment(let n) = node {
                isAdj = true; adjValue = n.adjustment.value; simpleSlider = n.adjustment.isSimpleSlider
            }
            let thumb = document?.layerThumbnail(node)
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            return LayerRow(id: c.id, name: c.name, opacity: c.opacity, blend: c.blendMode,
                            visible: c.isVisible, isAdjustment: isAdj, adjustmentValue: adjValue,
                            isSimpleSlider: simpleSlider, hasMask: c.maskHandle != nil, thumbnail: thumb)
        }
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
        reloadInspector()
    }

    /// 선택 레이어 → 인스펙터 상태. 선택만 바뀌어도 호출.
    func reloadInspector() {
        inspectorKind = .none
        if let s = document?.layerSize(selectedID) {
            selectedHasSize = true; insSizeW = s.w; insSizeH = s.h
            insAspect = s.h > 0 ? Double(s.w) / Double(s.h) : 1
        } else { selectedHasSize = false }
        guard let id = selectedID,
              let node = document?.model.layers.first(where: { $0.id == id }) else { editingMask = false; return }
        if node.common.maskHandle == nil { editingMask = false }   // 마스크 없는 레이어 선택 시 편집 해제
        switch node {
        case .text(let n):
            inspectorKind = .text
            insText = n.text; insFontName = n.fontName; insFontSize = n.fontSize; insColor = n.color
        case .vector(let n):
            inspectorKind = .shape
            let s = n.shapes.first
            insFill = s?.fill; insStrokeColor = s?.stroke?.color; insStrokeWidth = s?.stroke?.width ?? 3
        case .adjustment(let n):
            switch n.adjustment {
            case .levels(let L): inspectorKind = .levels; insLevels = L
            case .curve(let C): inspectorKind = .curve; insCurve = C
            case .blur, .sharpen:
                inspectorKind = .radius
                insRadius = Double(n.adjustment.value); insRadiusTitle = n.adjustment.displayName
            default: break    // 단일값(−1…1) 조정은 패널 슬라이더 사용
            }
        default:
            break
        }
    }

    // 이산 액션
    func toggleVisible(_ id: UUID) {
        let cur = rows.first { $0.id == id }?.visible ?? true
        document?.setVisible(id, !cur)
    }
    func setBlend(_ id: UUID, _ mode: Core.BlendMode) { document?.setBlendMode(id, mode) }
    func delete(_ id: UUID) { document?.deleteLayer(id) }
    func moveUp(_ id: UUID) { document?.moveLayer(id, by: +1) }    // 위(앞) = 배열 뒤로
    func moveDown(_ id: UUID) { document?.moveLayer(id, by: -1) }

    // 불투명도 라이브 드래그 (undo 한 번으로 코얼레스)
    func opacityBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { Double(self.rows.first { $0.id == id }?.opacity ?? 1) },
            set: { newValue in
                if let idx = self.rows.firstIndex(where: { $0.id == id }) {
                    self.rows[idx].opacity = Float(newValue)      // 슬라이더 즉시 반영
                }
                self.document?.setOpacityLive(id, Float(newValue))
            }
        )
    }
    func opacityEditing(_ id: UUID, _ editing: Bool) {
        if editing {
            dragStartModel = document?.model
        } else if let start = dragStartModel {
            document?.commitLive(from: start, actionName: "불투명도")
            dragStartModel = nil
        }
    }

    // 조정 강도 (라이브 + undo 코얼레스)
    func adjustmentBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { Double(self.rows.first { $0.id == id }?.adjustmentValue ?? 0) },
            set: { newValue in
                if let idx = self.rows.firstIndex(where: { $0.id == id }) {
                    self.rows[idx].adjustmentValue = Float(newValue)
                }
                self.document?.setAdjustmentLive(id, Float(newValue))
            }
        )
    }
    func adjustmentEditing(_ id: UUID, _ editing: Bool) {
        if editing {
            dragStartModel = document?.model
        } else if let start = dragStartModel {
            document?.commitLive(from: start, actionName: "보정")
            dragStartModel = nil
        }
    }

    // MARK: 인스펙터 액션 (V1b-4)
    func commitTextString() { if let id = selectedID { document?.setTextString(id, insText) } }
    func setFont(_ name: String?) { insFontName = name; if let id = selectedID { document?.setTextFont(id, name) } }
    func setTextColor(_ c: RGBA8) { insColor = c; if let id = selectedID { document?.setTextColor(id, c) } }
    func setFill(_ c: RGBA8?) { insFill = c; if let id = selectedID { document?.setShapeFill(id, c) } }
    func setStrokeColor(_ c: RGBA8) { insStrokeColor = c; if let id = selectedID { document?.setShapeStrokeColor(id, c) } }

    func fontSizeBinding() -> Binding<Double> {
        Binding(get: { self.insFontSize },
                set: { v in self.insFontSize = v; if let id = self.selectedID { self.document?.setFontSizeLive(id, v) } })
    }
    func strokeWidthBinding() -> Binding<Double> {
        Binding(get: { self.insStrokeWidth },
                set: { v in self.insStrokeWidth = v; if let id = self.selectedID { self.document?.setStrokeWidthLive(id, v) } })
    }
    func sliderEditing(_ editing: Bool, _ name: String) {
        if editing { dragStartModel = document?.model }
        else if let start = dragStartModel { document?.commitLive(from: start, actionName: name); dragStartModel = nil }
    }

    // MARK: 레벨 (인스펙터 5슬라이더, 라이브 + undo 코얼레스)
    func levelsBinding(_ kp: WritableKeyPath<Levels, Float>) -> Binding<Double> {
        Binding(
            get: { Double(self.insLevels[keyPath: kp]) },
            set: { v in
                self.insLevels[keyPath: kp] = Float(v)
                if let id = self.selectedID { self.document?.setLevelsLive(id, self.insLevels) }
            }
        )
    }

    // MARK: 커브 (그래프 편집기)
    /// 점 드래그: 시작에 모델 캡처 → 라이브 → 끝에 단일 undo로 커밋.
    func curveBeginEdit() { dragStartModel = document?.model }
    func curveLive(_ c: ToneCurve) {
        insCurve = c
        if let id = selectedID { document?.setCurveLive(id, c) }
    }
    func curveCommit() {
        if let start = dragStartModel { document?.commitLive(from: start, actionName: "커브"); dragStartModel = nil }
    }
    /// 점 추가/삭제 등 이산 편집: 한 번에 커밋.
    func curveSetCommitted(_ c: ToneCurve) {
        insCurve = c
        if let id = selectedID { document?.setCurve(id, c) }
    }
    func resetLevels() { insLevels = .identity; if let id = selectedID { document?.setLevels(id, .identity) } }
    func resetCurve() { curveSetCommitted(.identity) }

    // MARK: 페이지(문서/캔버스) 크기
    func pageWBinding() -> Binding<Int> { Binding(get: { self.pageW }, set: { self.pageW = max(1, $0) }) }
    func pageHBinding() -> Binding<Int> { Binding(get: { self.pageH }, set: { self.pageH = max(1, $0) }) }
    func applyPageSize() { document?.resizeCanvas(width: pageW, height: pageH, anchor: .center) }
    func openCanvasSizeDialog() { document?.resizeCanvasDialog(nil) }   // 앵커 선택 가능한 전체 다이얼로그

    // MARK: 레이어 크기 (숫자 입력, 비율 잠금)
    func sizeWBinding() -> Binding<Int> {
        Binding(get: { self.insSizeW }, set: { v in
            self.insSizeW = max(1, v)
            if self.insAspectLock { self.insSizeH = max(1, Int((Double(self.insSizeW) / self.insAspect).rounded())) }
        })
    }
    func sizeHBinding() -> Binding<Int> {
        Binding(get: { self.insSizeH }, set: { v in
            self.insSizeH = max(1, v)
            if self.insAspectLock { self.insSizeW = max(1, Int((Double(self.insSizeH) * self.insAspect).rounded())) }
        })
    }
    func applyLayerSize() { if let id = selectedID { document?.setLayerSize(id, width: insSizeW, height: insSizeH) } }

    // MARK: 레이어 마스크
    func addMask() { if let id = selectedID { document?.addMask(layerID: id) } }
    func removeMask() { if let id = selectedID { document?.removeMask(layerID: id) }; editingMask = false }
    func removeBackground() { document?.removeBackground(nil) }

    // MARK: 블러/샤픈 (인스펙터 0…1 단일 슬라이더, 라이브 + undo 코얼레스)
    func radiusBinding() -> Binding<Double> {
        Binding(
            get: { self.insRadius },
            set: { v in self.insRadius = v; if let id = self.selectedID { self.document?.setAdjustmentLive(id, Float(v)) } }
        )
    }
}

struct LayerRow: Identifiable {
    let id: UUID
    var name: String
    var opacity: Float
    var blend: Core.BlendMode
    var visible: Bool
    var isAdjustment: Bool = false
    var adjustmentValue: Float = 0
    var isSimpleSlider: Bool = false
    var hasMask: Bool = false
    var thumbnail: NSImage?
}
