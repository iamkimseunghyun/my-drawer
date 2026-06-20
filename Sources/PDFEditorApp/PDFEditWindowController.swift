import AppKit
import PDFKit
import ImageIO

/// 빈 영역 클릭(=PDF로 통과한 클릭) 시 콜백 → 도장 선택 해제용.
final class EditablePDFView: PDFView {
    var onBackgroundMouseDown: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onBackgroundMouseDown?()
        super.mouseDown(with: event)
    }
}

/// PDF 편집 창: 상단 페이지 작업 버튼 + (썸네일 | PDFView).
final class PDFEditWindowController: NSWindowController {
    private let doc: PDFEditDocument
    private let pdfView = EditablePDFView()
    private let thumbnails = PDFThumbnailView()
    private let inkOverlay = InkOverlayView()
    private let signButton = NSButton()
    private let whiteoutButton = NSButton()

    init(doc: PDFEditDocument) {
        self.doc = doc
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.center()
        super.init(window: window)

        pdfView.document = doc.pdf
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 100, height: 130)
        thumbnails.backgroundColor = NSColor.windowBackgroundColor

        inkOverlay.pdfView = pdfView
        inkOverlay.doc = doc
        pdfView.onBackgroundMouseDown = { [weak self] in self?.inkOverlay.deselect() }  // 빈 곳 클릭 → 선택 해제
        inkOverlay.onEditText = { [weak self] ann in self?.editTextAnnotation(ann) }     // 더블클릭 재편집

        buildLayout(in: window, frame: frame)
        setupOverlaySync()
    }

    private var observers: [NSObjectProtocol] = []

    /// 줌/스크롤 시 도장 선택 핸들이 따라오도록 오버레이를 다시 그린다.
    private func setupOverlaySync() {
        let nc = NotificationCenter.default
        let redraw: (Notification) -> Void = { [weak self] _ in self?.inkOverlay.needsDisplay = true }
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main, using: redraw))
        if let scroll = firstScrollView(in: pdfView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: scroll.contentView, queue: .main, using: redraw))
        }
    }
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildLayout(in window: NSWindow, frame: NSRect) {
        let container = NSView(frame: frame)

        // 상단 툴바
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            return b
        }
        bar.addArrangedSubview(button("◀ 페이지 위로", #selector(movePageUp)))
        bar.addArrangedSubview(button("페이지 아래로 ▶", #selector(movePageDown)))
        bar.addArrangedSubview(button("↻ 회전", #selector(rotatePage)))
        bar.addArrangedSubview(button("🗑 페이지 삭제", #selector(deletePage)))
        bar.addArrangedSubview(button("＋ 이미지 페이지", #selector(insertImage)))
        bar.addArrangedSubview(button("📄 문서 스캔", #selector(scanDocument)))
        bar.addArrangedSubview(button("🔤 OCR", #selector(recognizeText)))
        bar.addArrangedSubview(button("＋ PDF 삽입", #selector(insertPDF)))
        signButton.title = "✍️ 서명"; signButton.target = self; signButton.action = #selector(toggleSign(_:))
        signButton.setButtonType(.pushOnPushOff); signButton.bezelStyle = .rounded
        bar.addArrangedSubview(signButton)
        bar.addArrangedSubview(button("🔖 도장/이미지", #selector(insertStamp)))
        bar.addArrangedSubview(button("🅣 텍스트", #selector(insertTextAnnotation)))
        whiteoutButton.title = "⬜ 화이트아웃"; whiteoutButton.target = self; whiteoutButton.action = #selector(toggleWhiteout(_:))
        whiteoutButton.setButtonType(.pushOnPushOff); whiteoutButton.bezelStyle = .rounded
        bar.addArrangedSubview(whiteoutButton)
        bar.addArrangedSubview(button("－", #selector(zoomOutAction)))
        bar.addArrangedSubview(button("＋", #selector(zoomInAction)))
        bar.addArrangedSubview(button("맞춤", #selector(zoomFitAction)))

        // PDFView + 잉크 오버레이를 한 컨테이너에
        let pdfContainer = NSView()
        pdfContainer.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        inkOverlay.translatesAutoresizingMaskIntoConstraints = false
        pdfContainer.addSubview(pdfView)
        pdfContainer.addSubview(inkOverlay)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: pdfContainer.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: pdfContainer.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: pdfContainer.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: pdfContainer.trailingAnchor),
            inkOverlay.topAnchor.constraint(equalTo: pdfContainer.topAnchor),
            inkOverlay.bottomAnchor.constraint(equalTo: pdfContainer.bottomAnchor),
            inkOverlay.leadingAnchor.constraint(equalTo: pdfContainer.leadingAnchor),
            inkOverlay.trailingAnchor.constraint(equalTo: pdfContainer.trailingAnchor),
        ])

        // 썸네일 | (PDF + 잉크)
        let split = NSSplitView(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(thumbnails)
        split.addArrangedSubview(pdfContainer)
        thumbnails.widthAnchor.constraint(equalToConstant: 150).isActive = true

        container.addSubview(bar)
        container.addSubview(split)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
    }

    /// 현재 PDFView가 보고 있는 페이지 인덱스.
    private var currentIndex: Int {
        guard let p = pdfView.currentPage else { return max(0, doc.pageCount - 1) }
        let i = doc.pdf.index(for: p)
        return i == NSNotFound ? 0 : i
    }

    func refresh() {
        let target = currentIndex
        let scale = pdfView.scaleFactor, autoS = pdfView.autoScales
        // 같은 PDFDocument 객체 재할당은 PDFKit이 무시 → 페이지 순서 변경(exchangePage)이 본문에 반영
        // 안 됨(페이지 수 안 바뀌어 재레이아웃 트리거 없음). nil로 비웠다가 재할당해 강제 리로드.
        pdfView.document = nil
        pdfView.document = doc.pdf
        thumbnails.pdfView = pdfView
        pdfView.autoScales = autoS
        if !autoS { pdfView.scaleFactor = scale }
        goTo(min(target, doc.pageCount - 1))
    }
    private func goTo(_ i: Int) {
        guard i >= 0, i < doc.pageCount, let page = doc.pdf.page(at: i) else { return }
        // 문서 재할당(refresh) 직후 PDFView 레이아웃은 비동기 → 같은 런루프의 go(to:)는 무시돼 1페이지로 튐.
        // 다음 런루프로 미뤄, 모든 호출처(refresh·삭제·삽입·순서이동)가 일관되게 올바른 페이지로 이동.
        DispatchQueue.main.async { [weak self] in self?.pdfView.go(to: page) }
    }

    /// 이동/리사이즈 등 bounds 변경 — 가벼운 갱신(즉시 반영됨).
    func refreshAnnotations() { pdfView.setNeedsDisplay(pdfView.bounds) }

    /// 추가/삭제 — 내부 페이지 캐시를 깨려면 강제 리로드. 같은 객체 재할당은 무시되므로
    /// nil로 비웠다가 다시 넣는다. 스크롤·줌 위치는 보존.
    func reloadAnnotations() {
        let scale = pdfView.scaleFactor
        let autoS = pdfView.autoScales
        let dest = pdfView.currentDestination
        pdfView.document = nil
        pdfView.document = doc.pdf
        thumbnails.pdfView = pdfView
        pdfView.autoScales = autoS
        if !autoS { pdfView.scaleFactor = scale }
        if let dest { pdfView.go(to: dest) }
        inkOverlay.needsDisplay = true
    }

    @objc private func toggleSign(_ sender: NSButton) {
        inkOverlay.signing = (sender.state == .on)
        if sender.state == .on { whiteoutButton.state = .off; inkOverlay.whiteoutMode = false }
    }
    @objc private func toggleWhiteout(_ sender: NSButton) {
        inkOverlay.whiteoutMode = (sender.state == .on)
        if sender.state == .on { signButton.state = .off; inkOverlay.signing = false }
    }

    // 줌 (마우스 사용자용 버튼 + 보기 메뉴 ⌘=/⌘−/⌘0)
    @objc func zoomInAction() { pdfView.autoScales = false; pdfView.zoomIn(nil) }
    @objc func zoomOutAction() { pdfView.autoScales = false; pdfView.zoomOut(nil) }
    @objc func zoomFitAction() { pdfView.autoScales = true }

    // MARK: 액션
    @objc func deletePage() { let i = currentIndex; doc.deletePage(at: i); goTo(min(i, doc.pageCount - 1)) }
    @objc func rotatePage() { doc.rotatePage(at: currentIndex, by: 90) }
    @objc func movePageUp() { let i = currentIndex; doc.movePage(from: i, to: i - 1) }
    @objc func movePageDown() { let i = currentIndex; doc.movePage(from: i, to: i + 1) }

    @objc func insertImage() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if #available(macOS 11, *) { panel.allowedContentTypes = [.image] }
        let i = currentIndex
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
            self?.doc.insertImagePage(img, after: i); self?.goTo(i + 1)
        }
    }
    @objc func scanDocument() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if #available(macOS 11, *) { panel.allowedContentTypes = [.image] }
        let i = currentIndex
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self,
                  let cg = Self.loadCGImage(url) else { return }
            // Vision 문서 감지 + 원근 보정은 백그라운드에서(UI 안 멈춤).
            DispatchQueue.global(qos: .userInitiated).async {
                let corrected = DocumentScanner.scan(cg) ?? cg     // 못 찾으면 원본 그대로
                let img = NSImage(cgImage: corrected,
                                  size: NSSize(width: corrected.width, height: corrected.height))
                DispatchQueue.main.async {
                    self.doc.insertImagePage(img, after: i); self.goTo(i + 1)
                }
            }
        }
    }
    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // OCR — 현재 페이지 텍스트 인식 → 클립보드 복사 + .txt 저장.
    @objc func recognizeText() {
        guard let page = doc.pdf.page(at: currentIndex), let cg = Self.renderPageImage(page) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lines = TextRecognizer.recognize(cg)
            DispatchQueue.main.async { self?.presentOCR(lines) }
        }
    }

    private static func renderPageImage(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    private func presentOCR(_ lines: [String]) {
        let alert = NSAlert(); alert.messageText = "텍스트 인식 (OCR)"
        guard !lines.isEmpty else {
            alert.informativeText = "텍스트를 찾지 못했습니다. 글자가 또렷한 페이지에서 잘 동작합니다."
            alert.beginSheetModal(for: window!); return
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        alert.informativeText = "\(lines.count)줄 인식 — 클립보드에 복사됨."
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
        tv.string = text; tv.isEditable = false; tv.isRichText = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
        scroll.documentView = tv; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "닫기")
        alert.addButton(withTitle: "텍스트 저장…")
        if alert.runModal() == .alertSecondButtonReturn { saveText(text) }
    }

    private func saveText(_ text: String) {
        let panel = NSSavePanel()
        if #available(macOS 11, *) { panel.allowedContentTypes = [.plainText] }
        panel.nameFieldStringValue = "OCR.txt"
        panel.beginSheetModal(for: window!) { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc func insertPDF() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if #available(macOS 11, *) { panel.allowedContentTypes = [.pdf] }
        let i = currentIndex
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.doc.insertPDF(at: url, after: i); self?.goTo(i + 1)
        }
    }

    @objc func deleteSelectedStamp() { inkOverlay.deleteSelected() }

    @objc func insertTextAnnotation() {
        let i = currentIndex
        promptText("") { [weak self] t in
            if !t.isEmpty { self?.doc.addTextAnnotation(t, toPageAt: i) }
        }
    }
    func editTextAnnotation(_ ann: PDFAnnotation) {
        promptText(ann.contents ?? "") { [weak self] t in self?.doc.setTextContents(ann, t) }
    }
    private func promptText(_ initial: String, _ completion: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "텍스트 입력"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { completion(field.stringValue) }
    }

    @objc func insertStamp() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if #available(macOS 11, *) { panel.allowedContentTypes = [.image] }
        let i = currentIndex
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
            self?.doc.addImageStamp(img, toPageAt: i)
        }
    }
}
