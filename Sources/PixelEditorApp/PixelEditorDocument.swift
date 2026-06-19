import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
import Core
import ColorPipeline
import Rendering

/// 네이티브 문서 (설계 §7). NSDocument에 올려 dirty/저장/Undo/Versions를 무료로 얻는다.
/// 값 모델(`Document`)과 픽셀(`ResourceStore`)을 분리(설계 §3.2).
final class PixelEditorDocument: NSDocument {

    static let nativeType = "kr.laaf.pixeleditor.project"

    private(set) var model: Document
    let resources = ResourceStore()

    override init() {
        model = Document(canvas: CanvasSettings(pixelSize: SIMD2(1024, 768)))
        super.init()
    }

    override class var autosavesInPlace: Bool { false }
    override class var writableTypes: [String] { [nativeType] }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [Self.nativeType] }
    override class func isNativeType(_ type: String) -> Bool { type == nativeType }

    // MARK: 윈도우 (3계층, 설계 §7.1)
    override func makeWindowControllers() {
        guard let wc = CanvasWindowController(doc: self) else { return }
        addWindowController(wc)
        refresh(wc)
    }

    private var canvasControllers: [CanvasWindowController] {
        windowControllers.compactMap { $0 as? CanvasWindowController }
    }

    /// 합성만 갱신 (opacity 라이브 드래그 — 패널 행은 건드리지 않아 슬라이더가 매끄럽다).
    func recompose() { canvasControllers.forEach(composeCanvas) }

    /// 메모리 압박 대응(설계 §8): 파생 CIImage 캐시를 비우고 보이는 것만 재구성.
    func handleMemoryPressure() { resources.evictDerivedCaches(); recompose() }
    /// 패널 + 합성 모두 갱신 (구조 변경 후).
    func reloadAll() { canvasControllers.forEach { $0.viewModel.reload(); composeCanvas($0) } }
    private func refresh(_ wc: CanvasWindowController) { wc.viewModel.reload(); composeCanvas(wc) }

    private func composeCanvas(_ wc: CanvasWindowController) {
        let layers = editingHiddenLayer == nil ? model.layers
            : model.layers.filter { $0.id != editingHiddenLayer }
        let result = Compositor(sources: resources.ciSources()).render(layers, below: CIImage.empty())
        wc.canvas.setComposited(result, canvasPixels: model.canvas.pixelSize)
    }

    // MARK: 편집 진입점 (undoable)
    private func setModel(_ newModel: Document, actionName: String) {
        let old = model
        undoManager?.registerUndo(withTarget: self) { $0.setModel(old, actionName: actionName) }
        undoManager?.setActionName(actionName)
        model = newModel
        reloadAll()
    }

    /// undo 등록 없이 모델만 갱신(라이브 드래그). dirty는 수동 표시.
    private func updateLive(_ change: (inout Document) -> Void) {
        var m = model; change(&m); model = m
        updateChangeCount(.changeDone)
        recompose()
    }
    /// 라이브 드래그 종료 시 단 한 번 undo 커밋.
    func commitLive(from old: Document, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { $0.setModel(old, actionName: actionName) }
        undoManager?.setActionName(actionName)
        reloadAll()
    }

    private func mutateCommon(_ doc: inout Document, _ id: UUID, _ f: (inout CommonLayerProps) -> Void) {
        for i in doc.layers.indices where doc.layers[i].id == id {
            var c = doc.layers[i].common; f(&c); doc.layers[i] = doc.layers[i].withCommon(c)
        }
    }

    // MARK: 레이어 액션 (패널에서 호출)
    func importImage(_ cg: CGImage, name: String) {
        let handle = TileStoreHandle()
        resources.set(cg, for: handle)
        var m = model
        if m.layers.isEmpty { m.canvas.pixelSize = SIMD2(cg.width, cg.height) }
        m.layers.append(.raster(RasterNode(common: CommonLayerProps(name: name), pixels: handle)))
        setModel(m, actionName: "이미지 가져오기")
    }

    /// 클립보드 → 새 래스터 레이어. 스크린샷/복사 이미지를 1동작으로 붙여넣어 편집(편집→배포 마찰 제거).
    @objc func pasteImage(_ sender: Any?) {
        guard let cg = Self.pasteboardCGImage() else { NSSound.beep(); return }
        let handle = TileStoreHandle()
        resources.set(cg, for: handle)
        var m = model
        if m.layers.isEmpty { m.canvas.pixelSize = SIMD2(cg.width, cg.height) }
        let common = CommonLayerProps(name: "붙여넣기 \(m.layers.count + 1)")
        m.layers.append(.raster(RasterNode(common: common, pixels: handle)))
        setModel(m, actionName: "붙여넣기")
        canvasControllers.forEach { $0.viewModel.selectedID = common.id }
    }

    /// 클립보드에서 이미지를 추출.
    /// 1) 이미지 "파일"을 복사하면(Finder) 클립보드엔 파일 URL + Finder 아이콘만 들어온다 →
    ///    URL을 먼저 잡아 파일 원본을 읽어야 한다(아니면 아이콘의 tiff를 붙여넣게 됨).
    /// 2) 스크린샷·다른 앱 복사는 PNG/TIFF 비트맵 → 원본 해상도 보존.
    /// 3) 그 외 표현형은 NSImage로 폴백.
    private static func pasteboardCGImage() -> CGImage? {
        let pb = NSPasteboard.general

        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: urlOptions) as? [URL],
           let url = urls.first,
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return cg
        }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type),
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return cg
            }
        }

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first {
            var rect = CGRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        var m = model; mutateCommon(&m, id) { $0.isVisible = visible }
        setModel(m, actionName: visible ? "레이어 표시" : "레이어 숨김")
    }
    func setBlendMode(_ id: UUID, _ mode: BlendMode) {
        var m = model; mutateCommon(&m, id) { $0.blendMode = mode }
        setModel(m, actionName: "블렌드 모드")
    }
    func deleteLayer(_ id: UUID) {
        var m = model; m.layers.removeAll { $0.id == id }
        setModel(m, actionName: "레이어 삭제")
    }
    func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = model.layers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < model.layers.count else { return }
        var m = model; m.layers.swapAt(i, j)
        setModel(m, actionName: "레이어 순서")
    }
    /// 라이브 불투명도(드래그 중). undo는 commitLive에서.
    func setOpacityLive(_ id: UUID, _ value: Float) {
        updateLive { mutateCommon(&$0, id) { $0.opacity = value } }
    }

    // MARK: 페인트 (M2a) — 브러시/지우개. 모델 외부(픽셀)라 별도 Undo 경로지만 동일 UndoManager 사용.
    private struct StrokeState {
        let handle: TileStoreHandle
        var last: SIMD2<Double>
        let brush: BrushSettings
        let erase: Bool
        let name: String
    }
    private var activeStroke: StrokeState?

    /// 선택 레이어가 페인트 레이어면 그 핸들, 아니면 새 페인트 레이어를 만든다.
    private func paintHandle(forLayer id: UUID?) -> TileStoreHandle? {
        if let id, let node = model.layers.first(where: { $0.id == id }),
           case .raster(let r) = node, resources.isPaint(r.pixels) {
            return r.pixels
        }
        return createPaintLayer()
    }

    @discardableResult
    func createPaintLayer() -> TileStoreHandle {
        let handle = TileStoreHandle()
        let size = model.canvas.pixelSize
        resources.createPaintCanvas(handle, width: size.x, height: size.y)
        let common = CommonLayerProps(name: "페인트 \(model.layers.count + 1)")
        var m = model
        m.layers.append(.raster(RasterNode(common: common, pixels: handle)))
        setModel(m, actionName: "새 페인트 레이어")
        canvasControllers.forEach { $0.viewModel.selectedID = common.id }
        return handle
    }
    @objc func newPaintLayer(_ sender: Any?) { createPaintLayer() }

    // MARK: 조정 레이어 (M2b-2) — 위에 얹혀 아래 전체를 보정
    func addAdjustment(_ adjustment: Adjustment) {
        let common = CommonLayerProps(name: adjustment.displayName)
        var m = model
        m.layers.append(.adjustment(AdjustmentNode(common: common, adjustment: adjustment)))
        setModel(m, actionName: "\(adjustment.displayName) 추가")
        canvasControllers.forEach { $0.viewModel.selectedID = common.id }
    }
    @objc func addBrightness(_ sender: Any?) { addAdjustment(.brightness(0)) }
    @objc func addContrast(_ sender: Any?) { addAdjustment(.contrast(0)) }
    @objc func addSaturation(_ sender: Any?) { addAdjustment(.saturation(0)) }
    @objc func addHue(_ sender: Any?) { addAdjustment(.hue(0)) }
    @objc func addExposure(_ sender: Any?) { addAdjustment(.exposure(0)) }
    @objc func addLevels(_ sender: Any?) { addAdjustment(.levels(.identity)) }
    @objc func addCurve(_ sender: Any?) { addAdjustment(.curve(.identity)) }
    @objc func addBlur(_ sender: Any?) { addAdjustment(.blur(0.3)) }
    @objc func addSharpen(_ sender: Any?) { addAdjustment(.sharpen(0.5)) }

    /// 레벨/커브 등 비단일값 조정의 교체. live면 코얼레스(undo는 commitLive), 아니면 단일 undo.
    private func setAdjustment(_ id: UUID, _ adj: Adjustment, live: Bool, name: String) {
        var m = model
        for i in m.layers.indices where m.layers[i].id == id {
            if case .adjustment(var n) = m.layers[i] { n.adjustment = adj; m.layers[i] = .adjustment(n) }
        }
        if live { model = m; updateChangeCount(.changeDone); recompose() }
        else { setModel(m, actionName: name) }
    }
    func setLevelsLive(_ id: UUID, _ L: Levels) { setAdjustment(id, .levels(L), live: true, name: "레벨") }
    func setLevels(_ id: UUID, _ L: Levels) { setAdjustment(id, .levels(L), live: false, name: "레벨") }
    func setCurveLive(_ id: UUID, _ C: ToneCurve) { setAdjustment(id, .curve(C), live: true, name: "커브") }
    func setCurve(_ id: UUID, _ C: ToneCurve) { setAdjustment(id, .curve(C), live: false, name: "커브") }

    /// 조정 강도 라이브 변경(슬라이더 드래그). undo는 commitLive에서.
    func setAdjustmentLive(_ id: UUID, _ value: Float) {
        updateLive { doc in
            for i in doc.layers.indices where doc.layers[i].id == id {
                if case .adjustment(var n) = doc.layers[i] {
                    n.adjustment = n.adjustment.withValue(value)
                    doc.layers[i] = .adjustment(n)
                }
            }
        }
    }

    /// document 좌표(좌하단) → 이미지 픽셀 좌표(좌상단).
    private func imageCoord(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(p.x, Double(model.canvas.pixelSize.y) - p.y)
    }

    /// 칠하기 대상 핸들: 마스크 편집이면 선택 레이어의 마스크 캔버스(없으면 nil), 아니면 페인트 레이어.
    private func targetHandle(layerID id: UUID?, mask: Bool) -> TileStoreHandle? {
        if mask {
            guard let id, let node = model.layers.first(where: { $0.id == id }) else { return nil }
            return node.common.maskHandle
        }
        return paintHandle(forLayer: id)
    }

    func beginStroke(layerID: UUID?, brush: BrushSettings, erase: Bool, at p: SIMD2<Double>, mask: Bool = false) {
        guard let handle = targetHandle(layerID: layerID, mask: mask),
              let c = resources.paintCanvas(handle) else { return }
        // 마스크 편집: 브러시=검정(숨김)·지우개=흰색(보임), 항상 불투명(마스크 opaque 유지).
        var b = brush, eff = erase
        if mask { b.color = erase ? RGBA8(255, 255, 255, 255) : RGBA8(0, 0, 0, 255); eff = false }
        c.beginStroke()
        let q = imageCoord(p)
        c.stampDab(cx: q.x, cy: q.y, radius: b.radius, hardness: b.hardness,
                   color: b.color, flow: b.flow, erase: eff)
        activeStroke = StrokeState(handle: handle, last: p, brush: b, erase: eff,
                                   name: mask ? "마스크 편집" : (erase ? "지우개" : "브러시"))
        resources.invalidate(handle); recompose()
    }

    func continueStroke(at p: SIMD2<Double>) {
        guard var s = activeStroke, let c = resources.paintCanvas(s.handle) else { return }
        for ctr in StrokeSampler.dabCenters(from: s.last, to: p, spacing: max(1, s.brush.radius * s.brush.spacing)) {
            let q = imageCoord(ctr)
            c.stampDab(cx: q.x, cy: q.y, radius: s.brush.radius, hardness: s.brush.hardness,
                       color: s.brush.color, flow: s.brush.flow, erase: s.erase)
        }
        s.last = p; activeStroke = s
        resources.invalidate(s.handle); recompose()
    }

    func endStroke() {
        guard let s = activeStroke, let c = resources.paintCanvas(s.handle) else { activeStroke = nil; return }
        let delta = c.endStroke()
        activeStroke = nil
        commitPaint(delta, handle: s.handle, name: s.name)
    }

    private func commitPaint(_ delta: PaintDelta, handle: TileStoreHandle, name: String) {
        guard !delta.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.applyPaintTiles(handle: handle, tiles: delta.before, name: name)
        }
        undoManager?.setActionName(name)
        canvasControllers.forEach { $0.viewModel.reload() }   // 썸네일 갱신(페인트 후)
    }

    // MARK: 채우기 (버킷, M2b)
    func fillAt(layerID: UUID?, color: RGBA8, at p: SIMD2<Double>, tolerance: Int, mask: Bool = false) {
        guard let handle = targetHandle(layerID: layerID, mask: mask),
              let c = resources.paintCanvas(handle) else { return }
        c.beginStroke()
        let q = imageCoord(p)
        c.floodFill(startX: Int(q.x.rounded(.down)), startY: Int(q.y.rounded(.down)),
                    color: color, tolerance: tolerance)
        let delta = c.endStroke()
        resources.invalidate(handle); recompose()
        commitPaint(delta, handle: handle, name: mask ? "마스크 편집" : "채우기")
    }

    // MARK: 레이어 마스크 — 비파괴(흰=보임/검정=숨김). 모든 레이어 타입(조정 포함)에 적용.
    func addMask(layerID: UUID?) {
        guard let id = layerID, let i = model.layers.firstIndex(where: { $0.id == id }),
              model.layers[i].common.maskHandle == nil else { return }
        let handle = TileStoreHandle()
        let size = model.canvas.pixelSize
        resources.createMaskCanvas(handle, width: size.x, height: size.y)
        var m = model
        var c = m.layers[i].common; c.maskHandle = handle
        m.layers[i] = m.layers[i].withCommon(c)
        setModel(m, actionName: "마스크 추가")
    }
    func removeMask(layerID: UUID?) {
        guard let id = layerID, let i = model.layers.firstIndex(where: { $0.id == id }),
              model.layers[i].common.maskHandle != nil else { return }
        var m = model
        var c = m.layers[i].common; c.maskHandle = nil
        m.layers[i] = m.layers[i].withCommon(c)
        setModel(m, actionName: "마스크 제거")
    }
    func hasMask(_ id: UUID?) -> Bool {
        guard let id, let node = model.layers.first(where: { $0.id == id }) else { return false }
        return node.common.maskHandle != nil
    }
    @objc func addLayerMask(_ sender: Any?) { addMask(layerID: canvasControllers.first?.viewModel.selectedID) }

    // MARK: 배경 지우기 (Vision 전경 마스크 → 레이어 마스크). 온디바이스, 비파괴.
    @objc func removeBackground(_ sender: Any?) {
        guard let id = canvasControllers.first?.viewModel.selectedID,
              let node = model.layers.first(where: { $0.id == id }), case .raster(let r) = node else {
            alertBG("래스터 레이어(이미지·페인트)를 선택하세요."); return
        }
        let contentCG = resources.isPaint(r.pixels) ? resources.paintCanvas(r.pixels)?.makeCGImage()
                                                    : resources.image(for: r.pixels)
        guard let cg = contentCG else { alertBG("레이어 이미지를 읽을 수 없습니다."); return }
        let size = model.canvas.pixelSize
        let rect = layerDocumentRect(id) ?? CGRect(x: 0, y: 0, width: size.x, height: size.y)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mask = BackgroundRemover.foregroundMask(of: cg)   // 온디바이스 ~1–2s
            DispatchQueue.main.async {
                guard let self else { return }
                guard let maskCG = mask else { self.alertBG("전경(주제)을 찾지 못했습니다. 인물·사물이 뚜렷한 이미지에서 잘 동작합니다."); return }
                self.applyBackgroundMask(layerID: id, maskCG: maskCG, rect: rect)
            }
        }
    }

    private func applyBackgroundMask(layerID id: UUID, maskCG: CGImage, rect: CGRect) {
        guard model.layers.contains(where: { $0.id == id }) else { return }
        if !hasMask(id) { addMask(layerID: id) }
        guard let mh = model.layers.first(where: { $0.id == id })?.common.maskHandle,
              let mc = resources.paintCanvas(mh) else { return }
        mc.beginStroke()
        mc.writeCoverage(maskCG, in: rect)
        let delta = mc.endStroke()
        resources.invalidate(mh); recompose()
        commitPaint(delta, handle: mh, name: "배경 지우기")
    }

    // MARK: 개체 자동선택 → 새 레이어 추출 (Vision 인스턴스 마스크). 클릭한 개체를 잘라 별 레이어로.
    func extractObject(layerID: UUID?, at clickDoc: SIMD2<Double>) {
        guard let id = layerID, let node = model.layers.first(where: { $0.id == id }),
              case .raster(let r) = node else { alertBG("래스터 레이어(이미지·페인트)를 선택하세요."); return }
        let cg = resources.isPaint(r.pixels) ? resources.paintCanvas(r.pixels)?.makeCGImage()
                                             : resources.image(for: r.pixels)
        guard let content = cg else { return }
        let size = model.canvas.pixelSize
        let rect = layerDocumentRect(id) ?? CGRect(x: 0, y: 0, width: size.x, height: size.y)
        // 클릭 document 좌표 → 콘텐츠 top-left 픽셀 (이동+스케일 보정).
        let px = (clickDoc.x - rect.minX) / max(1, rect.width) * Double(content.width)
        let py = (rect.maxY - clickDoc.y) / max(1, rect.height) * Double(content.height)
        let transform = node.common.transform

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mask = BackgroundRemover.objectMask(of: content, atContentPixel: CGPoint(x: px, y: py))
            DispatchQueue.main.async {
                guard let self else { return }
                guard let maskCG = mask else { self.alertBG("그 위치에서 개체를 찾지 못했습니다. 개체 위를 클릭하세요."); return }
                self.applyExtractedObject(content: content, maskCG: maskCG, transform: transform)
            }
        }
    }

    private func applyExtractedObject(content: CGImage, maskCG: CGImage, transform: DecomposedTransform) {
        let img = CIImage(cgImage: content)
        let cov = CIImage(cgImage: maskCG).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
        let cut = img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: cov])
        guard let cutCG = ciContext.createCGImage(cut, from: img.extent, format: .RGBA8, colorSpace: ColorSpaces.sRGB)
        else { return }
        let handle = TileStoreHandle()
        resources.set(cutCG, for: handle)
        var common = CommonLayerProps(name: "개체"); common.transform = transform
        var m = model
        m.layers.append(.raster(RasterNode(common: common, pixels: handle)))
        setModel(m, actionName: "개체 추출")
        canvasControllers.forEach { $0.viewModel.selectedID = common.id }
    }

    // MARK: 캔버스(페이지) 크기 — 자르기와 달리 내용을 안 자르고 페이지만 키우거나 줄임.
    enum CanvasAnchor { case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight }

    /// 새 문서 초기 크기(윈도우 만들기 전 호출 — undo 불필요).
    func setNewCanvasSize(_ w: Int, _ h: Int) {
        model.canvas.pixelSize = SIMD2(max(1, min(16000, w)), max(1, min(16000, h)))
    }

    /// 캔버스 크기 변경 + 앵커에 따라 레이어 평행이동(내용 위치 유지). undoable.
    func resizeCanvas(width: Int, height: Int, anchor: CanvasAnchor) {
        let w = max(1, min(16000, width)), h = max(1, min(16000, height))
        let old = model.canvas.pixelSize
        let dw = Double(w - old.x), dh = Double(h - old.y)
        // document space = 좌하단 원점(위=+y). x: 좌0·중dw/2·우dw, y: 하0·중dh/2·상dh.
        let sx: Double = (anchor == .topLeft || anchor == .left || anchor == .bottomLeft) ? 0
            : (anchor == .topRight || anchor == .right || anchor == .bottomRight) ? dw : dw / 2
        let sy: Double = (anchor == .bottomLeft || anchor == .bottom || anchor == .bottomRight) ? 0
            : (anchor == .topLeft || anchor == .top || anchor == .topRight) ? dh : dh / 2
        let shift = SIMD2(sx, sy)
        var m = model
        m.canvas.pixelSize = SIMD2(w, h)
        if shift != .zero {
            for i in m.layers.indices {
                var c = m.layers[i].common; c.transform.translation += shift
                m.layers[i] = m.layers[i].withCommon(c)
            }
        }
        setModel(m, actionName: "캔버스 크기")
    }

    @objc func resizeCanvasDialog(_ sender: Any?) {
        let cur = model.canvas.pixelSize
        let alert = NSAlert(); alert.messageText = "캔버스 크기"
        alert.informativeText = "페이지 크기를 바꿉니다(레이어 유지, 내용 안 잘림)."
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 92))
        func label(_ s: String, _ x: CGFloat, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.frame = NSRect(x: x, y: y, width: 36, height: 18); v.addSubview(l); return l
        }
        _ = label("너비", 0, 60); let wF = NSTextField(frame: NSRect(x: 40, y: 58, width: 80, height: 24)); wF.integerValue = cur.x
        _ = label("높이", 0, 28); let hF = NSTextField(frame: NSRect(x: 40, y: 26, width: 80, height: 24)); hF.integerValue = cur.y
        _ = label("기준", 150, 78)
        let grid = AnchorGridView(frame: NSRect(x: 150, y: 4, width: 72, height: 72))
        v.addSubview(wF); v.addSubview(hF); v.addSubview(grid)
        alert.accessoryView = v
        alert.addButton(withTitle: "변경"); alert.addButton(withTitle: "취소")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            self.resizeCanvas(width: wF.integerValue, height: hF.integerValue, anchor: grid.anchor)
        }
        if let win = windowForSheet { alert.beginSheetModal(for: win, completionHandler: done) } else { done(alert.runModal()) }
    }

    private func alertBG(_ message: String) {
        let a = NSAlert(); a.messageText = "배경 지우기"; a.informativeText = message
        if let w = windowForSheet { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    // MARK: 그라디언트 (선형) — 드래그 중 라이브 미리보기, 놓으면 단일 undo로 커밋.
    private struct GradientDraft {
        let handle: TileStoreHandle
        let before: [TileIndex: [UInt8]]    // 시작 스냅샷(전체) — 프레임마다 복원
        let a: SIMD2<Double>                // image 좌표(top-left)
        let color: RGBA8
    }
    private var gradientDraft: GradientDraft?

    func beginGradient(layerID: UUID?, at p: SIMD2<Double>, color: RGBA8) {
        guard let handle = paintHandle(forLayer: layerID), let c = resources.paintCanvas(handle) else { return }
        c.beginStroke()
        gradientDraft = GradientDraft(handle: handle, before: c.tilesBytes(c.allTileIndices()),
                                      a: imageCoord(p), color: color)
    }
    func updateGradient(to p: SIMD2<Double>) {
        guard let d = gradientDraft, let c = resources.paintCanvas(d.handle) else { return }
        c.restore(d.before)                                   // 직전 미리보기 지우고 다시 그림
        let pb = imageCoord(p)
        let end = RGBA8(d.color.r, d.color.g, d.color.b, 0)   // 끝=투명(페이드)
        c.fillGradient(ax: d.a.x, ay: d.a.y, bx: pb.x, by: pb.y, color0: d.color, color1: end)
        resources.invalidate(d.handle); recompose()
    }
    func commitGradient() {
        guard let d = gradientDraft, let c = resources.paintCanvas(d.handle) else { gradientDraft = nil; return }
        gradientDraft = nil
        commitPaint(c.endStroke(), handle: d.handle, name: "그라디언트")
    }

    // MARK: 스포이드 (M2b) — 합성 결과에서 색 추출
    private lazy var ciContext = CIContext(options: [.workingColorSpace: ColorSpaces.workingLinearP3])

    private func composite() -> CIImage {
        Compositor(sources: resources.ciSources()).render(model.layers, below: CIImage.empty())
    }

    /// 레이어 패널 썸네일: 해당 노드만 단독 렌더 → 회색 배경 위에 합성 → 축소. 조정 레이어는 nil(아이콘).
    func layerThumbnail(_ node: LayerNode, maxDim: CGFloat = 40) -> CGImage? {
        if case .adjustment = node { return nil }
        let size = model.canvas.pixelSize
        guard size.x > 0, size.y > 0 else { return nil }
        let scale = maxDim / CGFloat(max(size.x, size.y))
        let w = max(1, Int((CGFloat(size.x) * scale).rounded()))
        let h = max(1, Int((CGFloat(size.y) * scale).rounded()))
        let outRect = CGRect(x: 0, y: 0, width: w, height: h)
        let rendered = Compositor(sources: resources.ciSources())
            .render([node], below: CIImage.empty())
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bg = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)).cropped(to: outRect)
        let composed = rendered.composited(over: bg)
        return ciContext.createCGImage(composed, from: outRect, format: .RGBA8, colorSpace: ColorSpaces.sRGB)
    }

    func colorAt(_ p: SIMD2<Double>) -> RGBA8? {
        let img = composite()
        var px = [UInt8](repeating: 0, count: 4)
        let rect = CGRect(x: Double(Int(p.x)), y: Double(Int(p.y)), width: 1, height: 1)
        ciContext.render(img, toBitmap: &px, rowBytes: 4, bounds: rect,
                         format: .RGBA8, colorSpace: ColorSpaces.sRGB)
        return RGBA8(px[0], px[1], px[2], px[3])
    }

    // MARK: 내보내기 (PNG/JPEG, M2b) — "쉽고 빠른 배포"의 핵심
    /// 평탄화 + 선택 배율로 리샘플(축소는 Lanczos로 품질 확보). scale=1이면 원본 크기.
    func flattenedCGImage(scale: Double = 1) -> CGImage? {
        let size = model.canvas.pixelSize
        var img = composite()
        if scale != 1 {
            img = img.applyingFilter("CILanczosScaleTransform",
                                     parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        let w = max(1, Int((Double(size.x) * scale).rounded()))
        let h = max(1, Int((Double(size.y) * scale).rounded()))
        return ciContext.createCGImage(img, from: CGRect(x: 0, y: 0, width: w, height: h),
                                       format: .RGBA8, colorSpace: ColorSpaces.sRGB)
    }

    @objc func exportImage(_ sender: Any?) {
        guard model.canvas.pixelSize.x > 0 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".png"
        let accessory = ExportOptionsAccessory(basePixels: model.canvas.pixelSize, panel: panel)
        panel.accessoryView = accessory
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self,
                  let cg = self.flattenedCGImage(scale: accessory.scale) else { return }
            let isJPEG = accessory.isJPEG
            let rep = NSBitmapImageRep(cgImage: cg)
            let data = rep.representation(using: isJPEG ? .jpeg : .png,
                                         properties: isJPEG ? [.compressionFactor: accessory.quality] : [:])
            try? data?.write(to: url)
        }
        if let win = windowForSheet { panel.beginSheetModal(for: win, completionHandler: done) }
        else { done(panel.runModal()) }
    }

    /// 타일 바이트를 써넣고 그 역(현재값)을 다시 undo 등록 → 대칭 undo/redo.
    func applyPaintTiles(handle: TileStoreHandle, tiles: [TileIndex: [UInt8]], name: String) {
        guard let c = resources.paintCanvas(handle) else { return }
        let reverse = c.tilesBytes(Array(tiles.keys))
        c.restore(tiles)
        resources.invalidate(handle)
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.applyPaintTiles(handle: handle, tiles: reverse, name: name)
        }
        undoManager?.setActionName(name)
        recompose()
    }

    // MARK: 벡터 도형 (V1a) — 드래그로 생성. 라이브 미리보기 + 단일 undo.
    private struct ShapeDraft { let startModel: Document; let layerID: UUID }
    private var shapeDraft: ShapeDraft?

    func beginShape(_ kind: VectorKind, color: RGBA8, at p: SIMD2<Double>) {
        let startModel = model
        let fill: RGBA8? = (kind == .line) ? nil : color
        let stroke: VectorStroke? = (kind == .line) ? VectorStroke(color: color, width: 3) : nil
        let shape = VectorShape(kind: kind, p0: p, p1: p, fill: fill, stroke: stroke)
        let common = CommonLayerProps(name: kind.displayName)
        var m = model
        m.layers.append(.vector(VectorNode(common: common, shapes: [shape])))
        model = m
        updateChangeCount(.changeDone); reloadAll()
        canvasControllers.forEach { $0.viewModel.selectedID = common.id }
        shapeDraft = ShapeDraft(startModel: startModel, layerID: common.id)
    }

    func updateShape(to p: SIMD2<Double>) {
        guard let d = shapeDraft,
              let i = model.layers.firstIndex(where: { $0.id == d.layerID }),
              case .vector(var n) = model.layers[i], !n.shapes.isEmpty else { return }
        n.shapes[0].p1 = p
        var m = model; m.layers[i] = .vector(n); model = m
        updateChangeCount(.changeDone); recompose()
    }

    func commitShape() {
        guard let d = shapeDraft else { return }
        shapeDraft = nil
        // 너무 작으면(클릭만) 폐기.
        if let i = model.layers.firstIndex(where: { $0.id == d.layerID }),
           case .vector(let n) = model.layers[i], let s = n.shapes.first,
           abs(s.p1.x - s.p0.x) < 2, abs(s.p1.y - s.p0.y) < 2 {
            model = d.startModel; reloadAll()
        } else {
            commitLive(from: d.startModel, actionName: "도형 추가")
        }
    }

    /// 통합 가져오기: 이미지·PDF·EPS. 확장자로 분기(이미지=네이티브, PDF/EPS=래스터화).
    // MARK: 레이어 이동 (V1b-1) — 선택 레이어의 transform.translation 드래그. 라이브 + 단일 undo.
    private struct MoveDraft {
        let startModel: Document
        let id: UUID
        let startTranslation: SIMD2<Double>
        let startPoint: SIMD2<Double>
    }
    private var moveDraft: MoveDraft?

    /// 레이어 콘텐츠의 변환 전 bbox. 벡터=union bbox, 래스터/이미지=콘텐츠 크기.
    func layerBaseBox(_ id: UUID) -> (origin: SIMD2<Double>, size: SIMD2<Double>)? {
        guard let node = model.layers.first(where: { $0.id == id }) else { return nil }
        switch node {
        case .vector(let n): return n.unionBounds
        case .raster(let r):
            return resources.contentSize(r.pixels).map { (SIMD2(0, 0), SIMD2(Double($0.x), Double($0.y))) }
        case .text(let n):
            let s = TextRasterizer.measure(n)
            return (n.origin, SIMD2(Double(s.width), Double(s.height)))
        case .adjustment, .group: return nil
        }
    }

    /// 변환(scale+translation, anchor=0) 적용된 document 좌표 사각형.
    func layerDocumentRect(_ id: UUID?) -> CGRect? {
        guard let id, let node = model.layers.first(where: { $0.id == id }),
              let base = layerBaseBox(id) else { return nil }
        let s = node.common.transform.scale, t = node.common.transform.translation
        return CGRect(x: base.origin.x * s.x + t.x, y: base.origin.y * s.y + t.y,
                      width: base.size.x * s.x, height: base.size.y * s.y)
    }

    /// 선택 레이어의 현재 표시 크기(px). 측정 불가(조정/그룹)면 nil.
    func layerSize(_ id: UUID?) -> (w: Int, h: Int)? {
        guard let r = layerDocumentRect(id), r.width >= 1, r.height >= 1 else { return nil }
        return (Int(r.width.rounded()), Int(r.height.rounded()))
    }

    /// 레이어를 정확한 W×H px로 리사이즈(현재 좌하단 코너 고정, 회전 미지원). undoable.
    func setLayerSize(_ id: UUID?, width: Int, height: Int) {
        guard let id, let i = model.layers.firstIndex(where: { $0.id == id }),
              let base = layerBaseBox(id), base.size.x > 0, base.size.y > 0,
              let rect = layerDocumentRect(id), width >= 1, height >= 1 else { return }
        let sx = Double(width) / base.size.x, sy = Double(height) / base.size.y
        var c = model.layers[i].common
        c.transform.scale = SIMD2(sx, sy)
        c.transform.anchor = SIMD2(0, 0)
        c.transform.translation = SIMD2(rect.minX - base.origin.x * sx, rect.minY - base.origin.y * sy)
        var m = model; m.layers[i] = m.layers[i].withCommon(c)
        setModel(m, actionName: "레이어 크기")
    }

    /// 변환(회전 포함) 적용된 document 좌표 4코너 (BL, BR, TR, TL). 회전 핸들/오버레이용.
    func layerDocumentQuad(_ id: UUID?) -> [SIMD2<Double>]? {
        guard let id, let node = model.layers.first(where: { $0.id == id }),
              let base = layerBaseBox(id) else { return nil }
        let m = node.common.transform.matrix
        let corners = [SIMD2(base.origin.x, base.origin.y),
                       SIMD2(base.origin.x + base.size.x, base.origin.y),
                       SIMD2(base.origin.x + base.size.x, base.origin.y + base.size.y),
                       SIMD2(base.origin.x, base.origin.y + base.size.y)]
        return corners.map { p in let v = m * SIMD3(p.x, p.y, 1); return SIMD2(v.x, v.y) }
    }

    /// 레이어가 회전돼 있는가(회전 시 축정렬 리사이즈는 왜곡되므로 비활성화 판단용).
    func isRotated(_ id: UUID?) -> Bool {
        guard let id, let node = model.layers.first(where: { $0.id == id }) else { return false }
        return abs(node.common.transform.rotation) > 1e-6
    }

    /// 해당 지점을 덮는 최상단 레이어(클릭 선택용). 회전 포함 4코너 다각형 기준.
    func topLayer(at p: SIMD2<Double>) -> UUID? {
        for node in model.layers.reversed() {
            guard node.common.isVisible, let quad = layerDocumentQuad(node.id) else { continue }
            if Self.pointInPolygon(p, quad) { return node.id }
        }
        return nil
    }

    private static func pointInPolygon(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    func beginMove(layerID: UUID?, at p: SIMD2<Double>) {
        guard let id = layerID, let i = model.layers.firstIndex(where: { $0.id == id }) else { return }
        moveDraft = MoveDraft(startModel: model, id: id,
                              startTranslation: model.layers[i].common.transform.translation,
                              startPoint: p)
    }
    func updateMove(to p: SIMD2<Double>) {
        guard let d = moveDraft, let i = model.layers.firstIndex(where: { $0.id == d.id }) else { return }
        var c = model.layers[i].common
        c.transform.translation = d.startTranslation + (p - d.startPoint)
        var m = model; m.layers[i] = m.layers[i].withCommon(c); model = m
        updateChangeCount(.changeDone); recompose()
    }
    func commitMove() {
        guard let d = moveDraft else { return }
        moveDraft = nil
        // 실제 이동이 있을 때만 undo 등록.
        if let i = model.layers.firstIndex(where: { $0.id == d.id }),
           model.layers[i].common.transform.translation == d.startTranslation {
            return
        }
        commitLive(from: d.startModel, actionName: "이동")
    }

    // MARK: 리사이즈 (V1b-2) — transform.scale 조절. 고정 코너 기준.
    private struct ResizeDraft {
        let startModel: Document
        let id: UUID
        let baseOrigin: SIMD2<Double>
        let baseSize: SIMD2<Double>
        let fixed: SIMD2<Double>
    }
    private var resizeDraft: ResizeDraft?

    func beginResize(layerID: UUID?, fixed: SIMD2<Double>) {
        guard let id = layerID, let base = layerBaseBox(id), base.size.x > 0, base.size.y > 0 else { return }
        resizeDraft = ResizeDraft(startModel: model, id: id,
                                  baseOrigin: base.origin, baseSize: base.size, fixed: fixed)
    }
    func updateResize(to m: SIMD2<Double>, aspectLocked: Bool = false) {
        guard let d = resizeDraft, let i = model.layers.firstIndex(where: { $0.id == d.id }) else { return }
        let minSize = 4.0
        var w = max(minSize, abs(m.x - d.fixed.x))
        var h = max(minSize, abs(m.y - d.fixed.y))
        if aspectLocked, d.baseSize.x > 0, d.baseSize.y > 0 {
            let s = max(w / d.baseSize.x, h / d.baseSize.y)   // 콘텐츠 비율 유지
            w = d.baseSize.x * s; h = d.baseSize.y * s
        }
        let dragX = d.fixed.x + (m.x >= d.fixed.x ? w : -w)
        let dragY = d.fixed.y + (m.y >= d.fixed.y ? h : -h)
        let ro = SIMD2(min(d.fixed.x, dragX), min(d.fixed.y, dragY))
        let rs = SIMD2(w, h)
        let sx = rs.x / d.baseSize.x, sy = rs.y / d.baseSize.y
        var c = model.layers[i].common
        c.transform.scale = SIMD2(sx, sy)
        c.transform.translation = SIMD2(ro.x - d.baseOrigin.x * sx, ro.y - d.baseOrigin.y * sy)
        c.transform.anchor = SIMD2(0, 0)
        var mm = model; mm.layers[i] = mm.layers[i].withCommon(c); model = mm
        updateChangeCount(.changeDone); recompose()
    }
    func commitResize() {
        guard let d = resizeDraft else { return }
        resizeDraft = nil
        commitLive(from: d.startModel, actionName: "크기 조절")
    }

    // MARK: 회전 (회전 핸들) — transform.rotation 조절, 레이어 중심 기준.
    // anchor=center 로 재매개화(매핑 불변, TransformTests로 증명) 후 rotation 만 바꾼다 → center 고정.
    private struct RotateDraft {
        let startModel: Document
        let id: UUID
        let center: SIMD2<Double>      // document space 회전 중심(드래그 내내 고정)
        let startRotation: Double
        let startAngle: Double         // 마우스→center 시작 각도(radian)
    }
    private var rotateDraft: RotateDraft?

    func beginRotate(layerID: UUID?, at p: SIMD2<Double>) {
        guard let id = layerID, let i = model.layers.firstIndex(where: { $0.id == id }),
              let base = layerBaseBox(id) else { return }
        let startModel = model
        let centerModel = base.origin + base.size / 2
        let m = model.layers[i].common.transform.matrix
        let cv = m * SIMD3(centerModel.x, centerModel.y, 1)
        let docCenter = SIMD2(cv.x, cv.y)
        var c = model.layers[i].common
        let startRotation = c.transform.rotation
        c.transform.anchor = centerModel
        c.transform.translation = docCenter - centerModel
        var mm = model; mm.layers[i] = mm.layers[i].withCommon(c); model = mm
        rotateDraft = RotateDraft(startModel: startModel, id: id, center: docCenter,
                                  startRotation: startRotation,
                                  startAngle: atan2(p.y - docCenter.y, p.x - docCenter.x))
    }

    func updateRotate(to p: SIMD2<Double>, snap: Bool = false) {
        guard let d = rotateDraft, let i = model.layers.firstIndex(where: { $0.id == d.id }) else { return }
        let angle = atan2(p.y - d.center.y, p.x - d.center.x)
        var rot = d.startRotation + (angle - d.startAngle)
        if snap { let step = Double.pi / 12; rot = (rot / step).rounded() * step }   // Shift=15° 스냅
        var c = model.layers[i].common
        c.transform.rotation = rot
        var m = model; m.layers[i] = m.layers[i].withCommon(c); model = m
        updateChangeCount(.changeDone); recompose()
    }

    func commitRotate() {
        guard let d = rotateDraft else { return }
        rotateDraft = nil
        // 실제 회전이 없으면 재매개화만 했으니 원본 복원(dirty/undo 남기지 않음).
        if let i = model.layers.firstIndex(where: { $0.id == d.id }),
           abs(model.layers[i].common.transform.rotation - d.startRotation) < 1e-9 {
            model = d.startModel; recompose(); return
        }
        commitLive(from: d.startModel, actionName: "회전")
    }

    // MARK: 자르기 (Crop) — 캔버스를 크롭 영역으로 줄이고 모든 레이어를 -origin 오프셋(콘텐츠 위치 유지).
    // origin/size 는 document 좌표(좌하단 원점). 크롭 영역 좌하단이 새 캔버스 원점(0,0)이 된다.
    func applyCrop(origin: SIMD2<Double>, size: SIMD2<Double>) {
        let w = Int(size.x.rounded()), h = Int(size.y.rounded())
        guard w >= 1, h >= 1 else { return }
        var m = model
        m.canvas.pixelSize = SIMD2(w, h)
        for i in m.layers.indices {
            var c = m.layers[i].common
            c.transform.translation -= origin       // translation -= origin → 전체 -origin 평행이동(TransformTests 증명)
            m.layers[i] = m.layers[i].withCommon(c)
        }
        setModel(m, actionName: "자르기")
    }

    // MARK: 인스펙터 setter (V1b-4)
    private func applyText(_ id: UUID, live: Bool, name: String, _ f: (inout TextNode) -> Void) {
        var m = model
        for i in m.layers.indices where m.layers[i].id == id {
            if case .text(var n) = m.layers[i] { f(&n); m.layers[i] = .text(n) }
        }
        if live { model = m; updateChangeCount(.changeDone); recompose() }
        else { setModel(m, actionName: name) }
    }
    func setTextString(_ id: UUID, _ s: String) {
        applyText(id, live: false, name: "텍스트 편집") { $0.text = s; $0.common.name = String(s.prefix(12)) }
    }
    func setTextFont(_ id: UUID, _ fontName: String?) { applyText(id, live: false, name: "글꼴") { $0.fontName = fontName } }
    func setTextColor(_ id: UUID, _ c: RGBA8) { applyText(id, live: false, name: "글자색") { $0.color = c } }
    func setFontSizeLive(_ id: UUID, _ v: Double) { applyText(id, live: true, name: "") { $0.fontSize = max(4, v) } }

    private func applyShapes(_ id: UUID, live: Bool, name: String, _ f: (inout VectorShape) -> Void) {
        var m = model
        for i in m.layers.indices where m.layers[i].id == id {
            if case .vector(var n) = m.layers[i] {
                for j in n.shapes.indices { f(&n.shapes[j]) }
                m.layers[i] = .vector(n)
            }
        }
        if live { model = m; updateChangeCount(.changeDone); recompose() }
        else { setModel(m, actionName: name) }
    }
    func setShapeFill(_ id: UUID, _ c: RGBA8?) { applyShapes(id, live: false, name: "채움") { $0.fill = c } }
    func setShapeStrokeColor(_ id: UUID, _ c: RGBA8) {
        applyShapes(id, live: false, name: "테두리 색") { s in
            if s.stroke == nil { s.stroke = VectorStroke(color: c, width: 3) } else { s.stroke?.color = c }
        }
    }
    func setStrokeWidthLive(_ id: UUID, _ w: Double) {
        applyShapes(id, live: true, name: "") { s in
            if s.stroke == nil { s.stroke = VectorStroke(color: .red, width: max(0, w)) }
            else { s.stroke?.width = max(0, w) }
        }
    }

    // MARK: 텍스트 (V1b-3/V1b-5) — 캔버스 인라인 편집
    func isText(_ id: UUID) -> Bool {
        if case .text = model.layers.first(where: { $0.id == id }) { return true }
        return false
    }
    func textNode(_ id: UUID) -> TextNode? {
        for n in model.layers { if case .text(let t) = n, t.common.id == id { return t } }
        return nil
    }

    /// 편집 중 래스터 텍스트를 합성에서 제외(인라인 에디터와 이중 표시 방지).
    private(set) var editingHiddenLayer: UUID?
    func setEditingHidden(_ id: UUID?) { editingHiddenLayer = id; recompose() }

    private var textEditStart: Document?

    /// 빈 텍스트 레이어를 만들고(라이브, undo 미등록) 편집 시작. id 반환.
    func beginNewTextEdit(at p: SIMD2<Double>, color: RGBA8) -> UUID {
        textEditStart = model
        let node = TextNode(common: CommonLayerProps(name: "텍스트"), text: "", color: color, origin: p)
        var m = model; m.layers.append(.text(node)); model = m
        updateChangeCount(.changeDone); reloadAll()
        canvasControllers.forEach { $0.viewModel.selectedID = node.common.id }
        return node.common.id
    }
    func beginEditText(_ id: UUID) { textEditStart = model }

    /// 편집 종료 — 단일 undo. 빈 문자열이면 레이어 제거.
    func commitText(_ id: UUID, _ s: String, isNew: Bool) {
        guard let start = textEditStart else { return }
        textEditStart = nil
        let trimmed = s
        if trimmed.isEmpty {
            if isNew {
                model = start; reloadAll()              // 새 빈 텍스트 폐기(undo 불필요)
            } else {
                var m = model; m.layers.removeAll { $0.id == id }; model = m
                commitLive(from: start, actionName: "텍스트 삭제")
            }
            return
        }
        applyText(id, live: true, name: "") { $0.text = trimmed; $0.common.name = String(trimmed.prefix(12)) }
        commitLive(from: start, actionName: isNew ? "텍스트 추가" : "텍스트 편집")
    }
    func discardTextEdit(_ id: UUID) {
        guard let start = textEditStart else { return }
        textEditStart = nil; model = start; reloadAll()
    }

    @objc func importImageDialog(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.image, .pdf]
        if let eps = UTType("com.adobe.encapsulated-postscript") { types.append(eps) }
        panel.allowedContentTypes = types

        // PDF/EPS 해상도(DPI) 선택 — 기본 300(인쇄 품질). 이미지엔 영향 없음.
        let dpis: [Double] = [72, 150, 300, 600]
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 34))
        let label = NSTextField(labelWithString: "PDF/EPS 해상도:")
        label.frame = NSRect(x: 8, y: 7, width: 120, height: 20)
        let popup = NSPopUpButton(frame: NSRect(x: 132, y: 3, width: 170, height: 26))
        popup.addItems(withTitles: ["72 DPI (화면)", "150 DPI", "300 DPI (인쇄)", "600 DPI"])
        popup.selectItem(at: 2)
        accessory.addSubview(label); accessory.addSubview(popup)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        let done: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" || ext == "eps" {
                let dpi = dpis[max(0, popup.indexOfSelectedItem)]
                self.importVector(at: url, scale: CGFloat(dpi / 72))
            } else if let cg = Self.loadCGImage(url) {
                self.importImage(cg, name: url.deletingPathExtension().lastPathComponent)
            }
        }
        if let win = windowForSheet { panel.beginSheetModal(for: win, completionHandler: done) }
        else { done(panel.runModal()) }
    }

    // MARK: 저장/열기 (.pxledit 패키지: manifest.json + resources/<uuid>.png)
    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let manifest = try JSONEncoder().encode(model)
        let referenced = model.layers.reduce(into: Set<TileStoreHandle>()) { $0.formUnion($1.referencedHandles) }
        let pngs = resources.pngData(referencedBy: referenced)
        let resourceWrappers = pngs.mapValues { FileWrapper(regularFileWithContents: $0) }
        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: manifest),
            "resources": FileWrapper(directoryWithFileWrappers: resourceWrappers),
        ])
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let manifestData = fileWrapper.fileWrappers?["manifest.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        model = try JSONDecoder().decode(Document.self, from: manifestData)
        var named: [String: Data] = [:]
        if let resDir = fileWrapper.fileWrappers?["resources"]?.fileWrappers {
            for (name, wrapper) in resDir {
                if let data = wrapper.regularFileContents { named[name] = data }
            }
        }
        resources.load(named)
        reloadAll()
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
