import AppKit
import SwiftUI
import Core

/// 윈도우당 1개 (설계 §7.1). 캔버스(AppKit) + 레이어 패널(SwiftUI)을 분할 뷰로 묶고,
/// 도구 상태(per-view)를 들고 페인트 동작을 document로 전달한다.
final class CanvasWindowController: NSWindowController, NSTextFieldDelegate, NSToolbarDelegate {
    let canvas: CanvasView
    let viewModel: DocumentViewModel
    private let doc: PixelEditorDocument
    private var canvasContainer: NSView!
    private let zoomField = NSTextField()

    // 도구/브러시 상태는 VM이 단일 소유(패널 SwiftUI가 관찰·편집). 컨트롤러는 통과 접근.
    var currentTool: ToolKind {
        get { viewModel.currentTool } set { viewModel.currentTool = newValue }
    }
    var brush: BrushSettings {
        get { viewModel.brush } set { viewModel.brush = newValue }
    }
    var shapeKind: VectorKind {
        get { viewModel.shapeKind } set { viewModel.shapeKind = newValue }
    }

    // 인라인 텍스트 편집(V1b-5)
    private var textEditor: NSTextField?
    private var editingLayerID: UUID?
    private var editingIsNew = false

    init?(doc: PixelEditorDocument) {
        self.doc = doc
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
        guard let canvas = CanvasView.create(frame: frame) else { return nil }
        self.canvas = canvas
        self.viewModel = DocumentViewModel(document: doc)

        // 캔버스 + 선택 오버레이를 한 컨테이너에 (오버레이는 클릭 통과)
        let container = NSView(frame: frame)
        canvas.frame = container.bounds; canvas.autoresizingMask = [.width, .height]
        let overlay = SelectionOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(canvas); container.addSubview(overlay)
        canvas.selectionOverlay = overlay
        self.canvasContainer = container

        // 분할 뷰: 도구 팔레트(좌, 고정) | 캔버스(가변) | 레이어 패널(우, 고정폭)
        let palette = NSHostingView(rootView: ToolPaletteView(vm: viewModel))
        let paletteVC = NSViewController(); paletteVC.view = palette
        let canvasVC = NSViewController(); canvasVC.view = container
        let panel = NSHostingView(rootView: LayerPanelView(vm: viewModel))
        let panelVC = NSViewController(); panelVC.view = panel

        let paletteItem = NSSplitViewItem(viewController: paletteVC)
        paletteItem.minimumThickness = 54; paletteItem.maximumThickness = 54
        paletteItem.canCollapse = false
        let canvasItem = NSSplitViewItem(viewController: canvasVC)
        let panelItem = NSSplitViewItem(viewController: panelVC)
        panelItem.minimumThickness = 220
        panelItem.maximumThickness = 360
        panelItem.canCollapse = true

        let splitVC = NSSplitViewController()
        splitVC.splitView.isVertical = true
        splitVC.addSplitViewItem(paletteItem)
        splitVC.addSplitViewItem(canvasItem)
        splitVC.addSplitViewItem(panelItem)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentViewController = splitVC
        window.setContentSize(frame.size)
        window.center()
        super.init(window: window)

        canvas.toolHost = self
        viewModel.onSelectionChanged = { [weak self] in self?.canvas.refreshOverlay() }
        viewModel.onToolChanged = { [weak self] in self?.canvas.toolChanged() }   // 팔레트→캔버스 동기화

        let toolbar = NSToolbar(identifier: "PixelEditorToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = true
        window.toolbar = toolbar

        canvas.onZoomChanged = { [weak self] z in self?.zoomField.stringValue = "\(Int((z * 100).rounded()))%" }
        setupZoomControl()
        window.makeFirstResponder(canvas)   // 줌·도구·키 입력 라우팅
    }

    func selectedLayerDocumentRect() -> CGRect? { doc.layerDocumentRect(viewModel.selectedID) }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: 페인트 전달 (CanvasView → document, 현재 선택 레이어 대상)
    func strokeBegan(at p: SIMD2<Double>, pressure: Float) {
        doc.beginStroke(layerID: viewModel.selectedID, brush: brush,
                        erase: currentTool == .eraser, at: p, mask: viewModel.editingMask)
    }
    func strokeMoved(at p: SIMD2<Double>) { doc.continueStroke(at: p) }
    func strokeEnded() { doc.endStroke() }

    func pickColor(at p: SIMD2<Double>) {
        guard let c = doc.colorAt(p) else { return }
        brush.color = c
        NSColorPanel.shared.color = NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                            blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }
    func fill(at p: SIMD2<Double>) {
        doc.fillAt(layerID: viewModel.selectedID, color: brush.color, at: p, tolerance: 32, mask: viewModel.editingMask)
    }
    func objectSelect(at p: SIMD2<Double>) { doc.extractObject(layerID: viewModel.selectedID, at: p) }
    func gradientBegan(at a: SIMD2<Double>) { doc.beginGradient(layerID: viewModel.selectedID, at: a, color: brush.color) }
    func gradientMoved(to b: SIMD2<Double>) { doc.updateGradient(to: b) }
    func gradientEnded() { doc.commitGradient() }

    func shapeBegan(at p: SIMD2<Double>) { doc.beginShape(shapeKind, color: brush.color, at: p) }
    func shapeMoved(at p: SIMD2<Double>) { doc.updateShape(to: p) }
    func shapeEnded() { doc.commitShape() }

    func moveBegan(at p: SIMD2<Double>) {
        if let hit = doc.topLayer(at: p) { viewModel.selectedID = hit }  // 클릭으로 레이어 선택
        doc.beginMove(layerID: viewModel.selectedID, at: p)
    }
    func moveMoved(at p: SIMD2<Double>) { doc.updateMove(to: p) }
    func moveEnded() { doc.commitMove() }

    func resizeBegan(fixed: SIMD2<Double>) { doc.beginResize(layerID: viewModel.selectedID, fixed: fixed) }
    func resizeMoved(to p: SIMD2<Double>, aspectLocked: Bool) { doc.updateResize(to: p, aspectLocked: aspectLocked) }
    func resizeEnded() { doc.commitResize() }

    func rotateBegan(at p: SIMD2<Double>) { doc.beginRotate(layerID: viewModel.selectedID, at: p) }
    func rotateMoved(to p: SIMD2<Double>, snap: Bool) { doc.updateRotate(to: p, snap: snap) }
    func rotateEnded() { doc.commitRotate() }
    func selectedLayerQuad() -> [SIMD2<Double>]? { doc.layerDocumentQuad(viewModel.selectedID) }
    func selectedLayerRotated() -> Bool { doc.isRotated(viewModel.selectedID) }

    func cropApply(origin: SIMD2<Double>, size: SIMD2<Double>) { doc.applyCrop(origin: origin, size: size) }

    // MARK: 인라인 텍스트 편집 (V1b-5)
    func textClick(at p: SIMD2<Double>) {
        endTextEdit(commit: true)   // 진행 중이면 먼저 커밋
        if let id = doc.topLayer(at: p), doc.isText(id) {
            doc.beginEditText(id)
            beginTextEdit(id: id, isNew: false)
        } else {
            let id = doc.beginNewTextEdit(at: p, color: brush.color)
            beginTextEdit(id: id, isNew: true)
        }
    }

    private func beginTextEdit(id: UUID, isNew: Bool) {
        guard let node = doc.textNode(id) else { return }
        let vp = canvas.viewport
        let o = vp.viewPoint(fromDocument: node.origin)
        let pt = max(6, node.fontSize * vp.zoom / vp.backingScale * node.common.transform.scale.y)
        let font = node.fontName.flatMap { NSFont(name: $0, size: pt) } ?? NSFont.systemFont(ofSize: pt)
        let lineH = font.ascender - font.descender + 6

        let tf = NSTextField(frame: NSRect(x: o.x, y: o.y, width: 260, height: lineH))
        tf.stringValue = node.text
        tf.font = font
        tf.textColor = NSColor(srgbRed: CGFloat(node.color.r) / 255, green: CGFloat(node.color.g) / 255,
                               blue: CGFloat(node.color.b) / 255, alpha: CGFloat(node.color.a) / 255)
        tf.isBordered = false; tf.drawsBackground = false; tf.focusRingType = .none
        tf.delegate = self
        canvasContainer.addSubview(tf)
        window?.makeFirstResponder(tf)

        textEditor = tf; editingLayerID = id; editingIsNew = isNew
        doc.setEditingHidden(id)
    }

    private func endTextEdit(commit: Bool) {
        guard let tf = textEditor, let id = editingLayerID else { return }
        let s = tf.stringValue
        textEditor = nil; editingLayerID = nil
        tf.removeFromSuperview()
        doc.setEditingHidden(nil)
        if commit { doc.commitText(id, s, isNew: editingIsNew) } else { doc.discardTextEdit(id) }
        // 포커스 복귀는 다음 런루프로 지연(동기 호출은 AppKit의 진행 중 포커스 변경에 덮임).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.canvas)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { endTextEdit(commit: true) }

    /// Enter=확정, Esc=확정 후 캔버스 복귀(도구 전환 가능하게).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEdit(commit: true)
            return true
        }
        return false
    }

    func adjustBrushRadius(_ delta: Double) {
        brush.radius = max(1, min(400, brush.radius + delta))
        canvas.refreshBrushCursor()
    }
    func setBrushColor(_ color: NSColor) {
        let s = color.usingColorSpace(.sRGB) ?? color
        brush.color = RGBA8(UInt8(s.redComponent * 255), UInt8(s.greenComponent * 255),
                            UInt8(s.blueComponent * 255), UInt8(s.alphaComponent * 255))
    }

    // MARK: 줌 컨트롤 (캔버스 좌하단 플로팅 — 표시 + 입력)
    private func setupZoomControl() {
        zoomField.stringValue = "100%"; zoomField.alignment = .center
        zoomField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomField.target = self; zoomField.action = #selector(zoomFieldChanged)
        zoomField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let stack = NSStackView(views: [
            zoomButton("−", #selector(zoomOutClicked)), zoomField,
            zoomButton("＋", #selector(zoomInClicked)), zoomButton("맞춤", #selector(zoomFitClicked)),
        ])
        stack.orientation = .horizontal; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        stack.layer?.cornerRadius = 7
        stack.setFrameSize(stack.fittingSize)
        stack.setFrameOrigin(NSPoint(x: 8, y: 8))
        stack.autoresizingMask = [.maxXMargin, .maxYMargin]   // 좌하단 고정
        canvasContainer.addSubview(stack)
    }
    private func zoomButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded; b.controlSize = .small
        return b
    }
    @objc private func zoomInClicked() { canvas.zoomIn(nil) }
    @objc private func zoomOutClicked() { canvas.zoomOut(nil) }
    @objc private func zoomFitClicked() { canvas.zoomToFit(nil) }
    @objc private func zoomFieldChanged() {
        let s = zoomField.stringValue.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let v = Double(s), v > 0 { canvas.setZoomPercent(v) }
    }
}

// MARK: - 상단 툴바 (자주 쓰는 동작). target=nil → 책임 연쇄(문서·캔버스)로 라우팅.
extension CanvasWindowController {
    private struct TB {
        static let importImage = NSToolbarItem.Identifier("import")
        static let export = NSToolbarItem.Identifier("export")
        static let newPaint = NSToolbarItem.Identifier("newPaint")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let zoomFit = NSToolbarItem.Identifier("zoomFit")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.importImage, TB.export, TB.newPaint, .flexibleSpace, TB.undo, TB.redo, .flexibleSpace, TB.zoomFit]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.importImage, TB.export, TB.newPaint, TB.undo, TB.redo, TB.zoomFit, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.isBordered = true; item.target = nil          // 책임 연쇄
        switch id {
        case TB.importImage: set(item, "가져오기", "square.and.arrow.down", #selector(PixelEditorDocument.importImageDialog(_:)))
        case TB.export:      set(item, "내보내기", "square.and.arrow.up", #selector(PixelEditorDocument.exportImage(_:)))
        case TB.newPaint:    set(item, "새 페인트 레이어", "plus.square.on.square", #selector(PixelEditorDocument.newPaintLayer(_:)))
        case TB.undo:        set(item, "실행 취소", "arrow.uturn.backward", Selector(("undo:")))
        case TB.redo:        set(item, "다시 실행", "arrow.uturn.forward", Selector(("redo:")))
        case TB.zoomFit:     set(item, "화면 맞춤", "arrow.up.left.and.down.right.magnifyingglass", #selector(CanvasView.zoomToFit(_:)))
        default: return nil
        }
        return item
    }

    private func set(_ item: NSToolbarItem, _ label: String, _ symbol: String, _ action: Selector) {
        item.label = label; item.toolTip = label; item.action = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }
}
