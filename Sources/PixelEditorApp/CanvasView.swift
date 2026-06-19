import AppKit
import MetalKit
import CoreImage
import simd
import Core
import ColorPipeline

/// M0 캔버스: Core Image 합성 결과(document space)를 받아 viewport 변환 후 드로어블에 렌더.
/// 줌/팬, 레티나 정확(설계 §5.2). 도구 시스템(ToolEvent)은 M2에서 추가.
final class CanvasView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    /// 표시할 합성 이미지(document space, 원점 0,0, 크기 = canvasPixels).
    private var displayImage: CIImage? { didSet { needsDisplay = true } }
    private var canvasPixels = SIMD2<Int>(0, 0)

    var viewport = Viewport()

    /// 도구 상태·페인트 동작을 코디네이트하는 윈도우 컨트롤러(설계 §7.1).
    weak var toolHost: CanvasWindowController?
    /// 선택 핸들 오버레이(클릭 통과).
    weak var selectionOverlay: SelectionOverlayView?
    /// 줌이 바뀔 때 호출(줌 표시 갱신용).
    var onZoomChanged: ((Double) -> Void)?
    private var resizingFixed: SIMD2<Double>?
    private var isRotating = false
    // 자르기(Crop): 캔버스를 덮는 조절 가능한 프레임. 핸들로 조절 → Enter 적용 / Esc 리셋(포토샵/사진 방식).
    private typealias CropRect = (origin: SIMD2<Double>, size: SIMD2<Double>)
    private var cropFrame: CropRect?
    private var cropDragHandle: Int?            // 0..7 핸들, 8 이동, nil 없음
    private var cropDragStartFrame: CropRect?
    private var cropDragStartPoint: SIMD2<Double>?
    private let cropMinSize = 16.0
    // 그라디언트: 드래그 A→B (document 좌표). 드래그 중 라이브 미리보기, 놓으면 커밋.
    private var gradientStart: SIMD2<Double>?
    private var gradientCurrent: SIMD2<Double>?
    private var gradientSessionActive = false
    private var lastMouseView: CGPoint?         // 브러시 커서 원 위치(뷰 좌표)

    /// Metal 디바이스가 없으면 nil. NSView의 init(frame:)은 non-failable이라 팩토리로 우회.
    static func create(frame: CGRect) -> CanvasView? {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        return CanvasView(frame: frame, device: dev, queue: queue)
    }

    private init(frame: CGRect, device dev: MTLDevice, queue: MTLCommandQueue) {
        self.commandQueue = queue
        self.ciContext = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: ColorSpaces.workingLinearP3,
            .cacheIntermediates: false,
        ])
        super.init(frame: frame, device: dev)

        framebufferOnly = false                 // CIContext가 드로어블 텍스처에 쓰려면 필요
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        (layer as? CAMetalLayer)?.colorspace = ColorSpaces.displayP3   // 설계 §4.2
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: 합성 결과 입력
    func setComposited(_ image: CIImage, canvasPixels: SIMD2<Int>) {
        // fit은 캔버스 크기가 바뀔 때(새 문서·첫 이미지 로드)만. 편집 중 재합성은 뷰포트 유지.
        let sizeChanged = canvasPixels != self.canvasPixels
        self.canvasPixels = canvasPixels
        let ext = image.extent
        displayImage = (ext.isInfinite || ext.isEmpty) ? nil : image
        if sizeChanged { fitToWindow() } else { needsDisplay = true }
    }

    func fitToWindow() {
        viewport.backingScale = Double(window?.backingScaleFactor ?? 2)
        guard canvasPixels.x > 0, bounds.width > 0 else { return }
        viewport.fit(canvasPixels: canvasPixels,
                     inViewSize: SIMD2(Double(bounds.width), Double(bounds.height)))
        needsDisplay = true
        onZoomChanged?(viewport.zoom)
    }

    /// 줌을 퍼센트로 설정(뷰 중심 고정). 줌 입력 필드용.
    func setZoomPercent(_ pct: Double) {
        let center = SIMD2(Double(drawableSize.width) / 2, Double(drawableSize.height) / 2)
        let anchor = viewport.documentPoint(fromDevice: center)
        viewport.setZoom(pct / 100, pinningDocument: anchor)
        needsDisplay = true; refreshBrushCursor(); onZoomChanged?(viewport.zoom)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewport.backingScale = Double(window?.backingScaleFactor ?? 2)
        if canvasPixels.x > 0 { fitToWindow() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        viewport.backingScale = Double(window?.backingScaleFactor ?? 2)
        needsDisplay = true
    }

    // MARK: 렌더
    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable,
              let cb = commandQueue.makeCommandBuffer() else { return }
        let dsize = drawableSize
        let canvas = CGRect(x: 0, y: 0, width: dsize.width, height: dsize.height)
        // 바깥(도큐먼트) = 다크 그레이, 페이지 = 체커보드(투명 표시) — 같은 그레이 계열로 톤 통일.
        let pasteboard = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.19, alpha: 1)).cropped(to: canvas)
        var base = pasteboard
        if canvasPixels.x > 0, canvasPixels.y > 0 {
            let z = CGFloat(viewport.zoom)
            let pageRect = CGRect(x: CGFloat(viewport.panDevice.x), y: CGFloat(viewport.panDevice.y),
                                  width: CGFloat(canvasPixels.x) * z, height: CGFloat(canvasPixels.y) * z)
            if let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
                "inputColor0": CIColor(red: 0.42, green: 0.42, blue: 0.43),
                "inputColor1": CIColor(red: 0.35, green: 0.35, blue: 0.36),
                "inputWidth": 8.0, "inputSharpness": 1.0,
                "inputCenter": CIVector(x: pageRect.minX, y: pageRect.minY)])?.outputImage {
                base = checker.cropped(to: pageRect).composited(over: pasteboard)
            }
        }

        let frame: CIImage
        if let img = displayImage {
            var t = CGAffineTransform(scaleX: CGFloat(viewport.zoom), y: CGFloat(viewport.zoom))
            t = t.concatenating(CGAffineTransform(translationX: CGFloat(viewport.panDevice.x),
                                                  y: CGFloat(viewport.panDevice.y)))
            frame = img.transformed(by: t).composited(over: base).cropped(to: canvas)
        } else {
            frame = base.cropped(to: canvas)
        }

        ciContext.render(frame, to: drawable.texture, commandBuffer: cb,
                         bounds: canvas, colorSpace: ColorSpaces.displayP3)
        cb.present(drawable)
        cb.commit()
        refreshOverlay()
    }

    // MARK: 선택 핸들 오버레이
    /// 선택 레이어의 뷰 좌표 4코너(회전 포함, BL/BR/TR/TL). move 도구일 때만.
    private func selectionViewCorners() -> [CGPoint]? {
        guard toolHost?.currentTool == .move, let quad = toolHost?.selectedLayerQuad() else { return nil }
        return quad.map { let v = viewport.viewPoint(fromDocument: $0); return CGPoint(x: v.x, y: v.y) }
    }

    /// 회전 핸들 위치(뷰 좌표): 윗변 중점에서 박스 바깥으로 24pt. 박스와 함께 회전한다.
    private func rotationHandlePoint(_ c: [CGPoint]) -> CGPoint {
        let topMid = CGPoint(x: (c[2].x + c[3].x) / 2, y: (c[2].y + c[3].y) / 2)
        let center = CGPoint(x: (c[0].x + c[1].x + c[2].x + c[3].x) / 4,
                             y: (c[0].y + c[1].y + c[2].y + c[3].y) / 4)
        let dx = topMid.x - center.x, dy = topMid.y - center.y
        let len = max(1e-6, hypot(dx, dy))
        return CGPoint(x: topMid.x + dx / len * 24, y: topMid.y + dy / len * 24)
    }

    /// 문서 페이지 경계를 뷰 좌표 사각형으로(무한 평면 속 출력 영역).
    private func pageRectInView() -> CGRect? {
        guard canvasPixels.x > 0, canvasPixels.y > 0 else { return nil }
        let a = viewport.viewPoint(fromDocument: SIMD2(0, 0))
        let b = viewport.viewPoint(fromDocument: SIMD2(Double(canvasPixels.x), Double(canvasPixels.y)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func refreshOverlay() {
        guard let overlay = selectionOverlay else { return }
        overlay.pageRect = pageRectInView()   // 모든 도구에서 항상 표시
        overlay.gradientLine = nil
        if toolHost?.currentTool == .gradient {
            overlay.corners = nil; overlay.rotationHandle = nil; overlay.cropFrame = nil
            if let a = gradientStart, let b = gradientCurrent {
                let va = viewport.viewPoint(fromDocument: a), vb = viewport.viewPoint(fromDocument: b)
                overlay.gradientLine = (CGPoint(x: va.x, y: va.y), CGPoint(x: vb.x, y: vb.y))
            }
            return
        }
        if toolHost?.currentTool == .crop {
            overlay.corners = nil; overlay.rotationHandle = nil
            overlay.cropFrame = cropFrameViewRect()
            return
        }
        overlay.cropFrame = nil
        if let corners = selectionViewCorners() {
            overlay.corners = corners
            overlay.rotationHandle = rotationHandlePoint(corners)
        } else {
            overlay.corners = nil
            overlay.rotationHandle = nil
        }
    }

    // MARK: 자르기 (조절 가능한 프레임)
    /// 크롭 도구 진입 시 프레임을 캔버스 전체로 초기화.
    func beginCropSession() {
        guard canvasPixels.x > 0, canvasPixels.y > 0 else { cropFrame = nil; return }
        cropFrame = (SIMD2(0, 0), SIMD2(Double(canvasPixels.x), Double(canvasPixels.y)))
        cropDragHandle = nil
        refreshOverlay()
    }
    func endCropSession() {
        cropFrame = nil; cropDragHandle = nil; cropDragStartFrame = nil; cropDragStartPoint = nil
        refreshOverlay()
    }

    /// 현재 크롭 프레임을 뷰 좌표 사각형으로(회전 없음 → 축정렬). 핸들/그리기 공용.
    private func cropFrameViewRect() -> CGRect? {
        guard let f = cropFrame else { return nil }
        let a = viewport.viewPoint(fromDocument: f.origin)
        let b = viewport.viewPoint(fromDocument: f.origin + f.size)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 핸들 8개의 뷰 좌표(0..3 코너 BL/BR/TR/TL, 4..7 변 중점 bottom/right/top/left).
    private func cropHandleViewPoints() -> [CGPoint]? {
        guard let r = cropFrameViewRect() else { return nil }
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    /// 뷰 좌표 vp가 어느 크롭 요소 위인가: 0..7 핸들, 8 프레임 내부(이동), nil 바깥.
    private func cropHit(_ vp: CGPoint) -> Int? {
        guard let pts = cropHandleViewPoints(), let r = cropFrameViewRect() else { return nil }
        for (i, p) in pts.enumerated() where hypot(p.x - vp.x, p.y - vp.y) <= 11 { return i }
        return r.insetBy(dx: -2, dy: -2).contains(vp) ? 8 : nil
    }

    /// 핸들/이동에 따라 프레임 갱신. 캔버스 경계·최소크기로 클램프.
    private func updateCropDrag(to p: SIMD2<Double>) {
        guard let handle = cropDragHandle, let start = cropDragStartFrame,
              let sp = cropDragStartPoint else { return }
        let cw = Double(canvasPixels.x), ch = Double(canvasPixels.y)
        var minX = start.origin.x, minY = start.origin.y
        var maxX = start.origin.x + start.size.x, maxY = start.origin.y + start.size.y

        if handle == 8 {   // 이동: 전체 평행이동 후 캔버스 안으로 클램프.
            var dx = p.x - sp.x, dy = p.y - sp.y
            dx = max(-minX, min(cw - maxX, dx)); dy = max(-minY, min(ch - maxY, dy))
            minX += dx; maxX += dx; minY += dy; maxY += dy
        } else {
            // 각 핸들이 제어하는 변: left/right/bottom/top.
            let ctrlLeft   = handle == 0 || handle == 3 || handle == 7
            let ctrlRight  = handle == 1 || handle == 2 || handle == 5
            let ctrlBottom = handle == 0 || handle == 1 || handle == 4
            let ctrlTop    = handle == 2 || handle == 3 || handle == 6
            if ctrlLeft   { minX = max(0, min(p.x, maxX - cropMinSize)) }
            if ctrlRight  { maxX = min(cw, max(p.x, minX + cropMinSize)) }
            if ctrlBottom { minY = max(0, min(p.y, maxY - cropMinSize)) }
            if ctrlTop    { maxY = min(ch, max(p.y, minY + cropMinSize)) }
        }
        cropFrame = (SIMD2(minX, minY), SIMD2(maxX - minX, maxY - minY))
        refreshOverlay()
    }

    private func commitCrop() {
        guard let f = cropFrame, f.size.x >= 1, f.size.y >= 1 else { return }
        toolHost?.cropApply(origin: f.origin, size: f.size)
        endCropSession()
    }

    /// 뷰 좌표 vp가 회전 핸들 위인가.
    private func rotationHandleHit(_ vp: CGPoint) -> Bool {
        guard let c = selectionViewCorners() else { return false }
        let rh = rotationHandlePoint(c)
        return hypot(rh.x - vp.x, rh.y - vp.y) <= 11
    }

    /// 뷰 좌표 vp가 코너 핸들 위면, 반대편(고정) 코너를 document 좌표로 반환.
    /// 회전된 레이어는 축정렬 리사이즈가 왜곡되므로 비활성화(코너 드래그→이동).
    private func handleFixedCorner(atViewPoint vp: CGPoint) -> SIMD2<Double>? {
        guard toolHost?.currentTool == .move, toolHost?.selectedLayerRotated() == false,
              let quad = toolHost?.selectedLayerQuad() else { return nil }
        let opposite = [2, 3, 0, 1]   // BL↔TR, BR↔TL
        let radius: CGFloat = 9
        for (i, d) in quad.enumerated() {
            let v = viewport.viewPoint(fromDocument: d)
            if abs(v.x - vp.x) <= radius, abs(v.y - vp.y) <= radius { return quad[opposite[i]] }
        }
        return nil
    }

    // MARK: 줌/팬
    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let anchor = viewport.documentPoint(fromView: SIMD2(Double(p.x), Double(p.y)))
        viewport.setZoom(viewport.zoom * (1 + event.magnification), pinningDocument: anchor)
        needsDisplay = true
        refreshBrushCursor(); onZoomChanged?(viewport.zoom)
    }

    override func scrollWheel(with event: NSEvent) {
        // 마우스 휠(정밀 델타 없음) 또는 ⌘+스크롤 → 커서 기준 줌. 트랙패드 정밀 스크롤 → 팬.
        if !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            let anchor = viewport.documentPoint(fromView: SIMD2(Double(p.x), Double(p.y)))
            let factor = exp(Double(event.scrollingDeltaY) * 0.02)
            viewport.setZoom(viewport.zoom * factor, pinningDocument: anchor)
        } else {
            let s = viewport.backingScale
            viewport.panDevice += SIMD2(Double(event.scrollingDeltaX) * s,
                                        -Double(event.scrollingDeltaY) * s)
        }
        needsDisplay = true
        refreshBrushCursor(); onZoomChanged?(viewport.zoom)
    }

    // MARK: 도구 디스패치 (V=이동/팬, B=브러시, E=지우개). 휠=줌은 항상.
    private var isPanning: Bool { toolHost?.currentTool == .pan || toolHost == nil }

    private func docPoint(_ event: NSEvent) -> SIMD2<Double> {
        let p = convert(event.locationInWindow, from: nil)
        return viewport.documentPoint(fromView: SIMD2(Double(p.x), Double(p.y)))
    }

    // MARK: 브러시 커서 (포토샵식 크기 원 — 마우스 따라다님)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { refreshBrushCursor(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { refreshBrushCursor(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { lastMouseView = nil; selectionOverlay?.brushCursor = nil }

    /// 브러시/지우개 도구일 때 커서 위치에 브러시 크기 원 표시.
    func refreshBrushCursor(_ viewPt: CGPoint? = nil) {
        if let p = viewPt { lastMouseView = p }
        guard let overlay = selectionOverlay else { return }
        let tool = toolHost?.currentTool
        if (tool == .brush || tool == .eraser), let p = lastMouseView, let r = toolHost?.brush.radius {
            let vr = CGFloat(r) * CGFloat(viewport.zoom / max(0.0001, viewport.backingScale))
            overlay.brushCursor = (p, vr)
        } else {
            overlay.brushCursor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = docPoint(event)
        switch toolHost?.currentTool {
        case .pan, .none: return
        case .brush, .eraser: toolHost?.strokeBegan(at: p, pressure: Float(event.pressure))
        case .eyedropper: toolHost?.pickColor(at: p)
        case .fill: toolHost?.fill(at: p)
        case .shape: toolHost?.shapeBegan(at: p)
        case .text: toolHost?.textClick(at: p)
        case .objectSelect: toolHost?.objectSelect(at: p)   // 클릭한 개체 추출
        case .gradient:
            gradientStart = p; gradientCurrent = p; gradientSessionActive = false; refreshOverlay()
        case .crop:
            if cropFrame == nil { beginCropSession() }
            let vp = convert(event.locationInWindow, from: nil)
            cropDragHandle = cropHit(vp)
            cropDragStartFrame = cropFrame
            cropDragStartPoint = p
        case .move:
            let vp = convert(event.locationInWindow, from: nil)
            if rotationHandleHit(vp) {
                isRotating = true
                toolHost?.rotateBegan(at: p)
            } else if let fixed = handleFixedCorner(atViewPoint: vp) {
                resizingFixed = fixed
                toolHost?.resizeBegan(fixed: fixed)
            } else {
                resizingFixed = nil
                toolHost?.moveBegan(at: p)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = docPoint(event)
        refreshBrushCursor(convert(event.locationInWindow, from: nil))
        switch toolHost?.currentTool {
        case .pan, .none:
            let s = viewport.backingScale
            viewport.panDevice += SIMD2(Double(event.deltaX) * s, -Double(event.deltaY) * s)
            needsDisplay = true
        case .brush, .eraser: toolHost?.strokeMoved(at: p)
        case .eyedropper: toolHost?.pickColor(at: p)
        case .shape: toolHost?.shapeMoved(at: p)
        case .move:
            if isRotating {
                toolHost?.rotateMoved(to: p, snap: event.modifierFlags.contains(.shift))
            } else if resizingFixed != nil {
                toolHost?.resizeMoved(to: p, aspectLocked: event.modifierFlags.contains(.shift))
            } else { toolHost?.moveMoved(at: p) }
        case .gradient:
            gradientCurrent = p
            if !gradientSessionActive, let a = gradientStart {
                toolHost?.gradientBegan(at: a); gradientSessionActive = true
            }
            toolHost?.gradientMoved(to: p); refreshOverlay()
        case .crop: if cropDragHandle != nil { updateCropDrag(to: p) }
        case .fill, .text, .objectSelect: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch toolHost?.currentTool {
        case .brush, .eraser: toolHost?.strokeEnded()
        case .shape: toolHost?.shapeEnded()
        case .move:
            if isRotating { toolHost?.rotateEnded(); isRotating = false }
            else if resizingFixed != nil { toolHost?.resizeEnded(); resizingFixed = nil }
            else { toolHost?.moveEnded() }
        case .gradient:
            if gradientSessionActive { toolHost?.gradientEnded() }
            gradientSessionActive = false; gradientStart = nil; gradientCurrent = nil; refreshOverlay()
        case .crop:
            cropDragHandle = nil; cropDragStartFrame = nil; cropDragStartPoint = nil
        default: break
        }
    }

    override func keyDown(with event: NSEvent) {
        if toolHost?.currentTool == .crop {
            if event.keyCode == 36 || event.keyCode == 76 { commitCrop(); return }   // Return / 키패드 Enter → 적용
            if event.keyCode == 53 { beginCropSession(); return }                    // Esc → 프레임 리셋(전체)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": toolHost?.currentTool = .pan
        case "c": toolHost?.currentTool = .crop
        case "m": toolHost?.currentTool = .move
        case "b": toolHost?.currentTool = .brush
        case "e": toolHost?.currentTool = .eraser
        case "i": toolHost?.currentTool = .eyedropper
        case "g": toolHost?.currentTool = event.modifierFlags.contains(.shift) ? .gradient : .fill
        case "a": toolHost?.currentTool = .objectSelect
        case "t": toolHost?.currentTool = .text
        case "r": toolHost?.currentTool = .shape; toolHost?.shapeKind = .rectangle
        case "o": toolHost?.currentTool = .shape; toolHost?.shapeKind = .oval
        case "l": toolHost?.currentTool = .shape; toolHost?.shapeKind = .line
        case "[": toolHost?.adjustBrushRadius(-2)
        case "]": toolHost?.adjustBrushRadius(+2)
        default: super.keyDown(with: event); return
        }
        toolChanged()
    }

    /// 도구 전환 부수효과(키보드·팔레트 공용): 크롭 세션·그라디언트 정리·오버레이·브러시 커서 동기화.
    func toolChanged() {
        if toolHost?.currentTool == .crop { if cropFrame == nil { beginCropSession() } }
        else { endCropSession() }
        if toolHost?.currentTool != .gradient { gradientStart = nil; gradientCurrent = nil; gradientSessionActive = false }
        refreshOverlay()
        refreshBrushCursor()
    }

    /// 색상 패널(NSColorPanel) → 브러시 색.
    @objc func changeColor(_ sender: NSColorPanel) {
        toolHost?.setBrushColor(sender.color)
    }

    private func zoom(by factor: Double) {
        let center = SIMD2(Double(drawableSize.width) / 2, Double(drawableSize.height) / 2)
        let anchor = viewport.documentPoint(fromDevice: center)
        viewport.setZoom(viewport.zoom * factor, pinningDocument: anchor)
        needsDisplay = true
        refreshBrushCursor(); onZoomChanged?(viewport.zoom)
    }

    // MARK: 메뉴 액션 (first responder로 라우팅 — 멀티윈도우 대비)
    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }
    @objc func zoomToFit(_ sender: Any?) { fitToWindow() }
}
