import AppKit
import PDFKit

/// PDFView 위 오버레이.
/// - 서명 모드: 마우스로 잉크 그리기 → PDFAnnotation.ink.
/// - 비서명 모드: 도장/텍스트 주석 선택/이동/리사이즈(핸들, Shift=비율고정)/삭제(Delete),
///   freeText는 더블클릭 재편집. 주석/핸들 위에서만 캡처, 그 외는 통과(스크롤).
final class InkOverlayView: NSView {
    var signing = false
    var whiteoutMode = false
    weak var pdfView: PDFView?
    weak var doc: PDFEditDocument?
    var inkColor: NSColor = .black
    var inkWidth: CGFloat = 2
    var onEditText: ((PDFAnnotation) -> Void)?

    private enum Mode { case none, ink, move, resize, whiteout }
    private var mode: Mode = .none
    private var windowPoints: [CGPoint] = []

    private weak var selected: PDFAnnotation?
    private weak var selectedPage: PDFPage?
    private var startWindow: CGPoint = .zero
    private var startBounds: CGRect = .zero
    private var resizeFixedPage: CGPoint = .zero
    private var lockAspect: CGFloat = 1     // Shift 시 유지할 h/w
    private var resizeStartFont: CGFloat = 24   // freeText 리사이즈 시작 폰트

    private let handleR: CGFloat = 9

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if signing || whiteoutMode { return self }
        guard let pdfView else { return nil }
        // hitTest 의 point 는 superview 좌표계. 핸들/page(for:)/editable 은 pdfView 좌표를 기대하므로
        // 변환 필수. 현재 레이아웃은 오버레이·pdfView 가 같은 컨테이너에 동일 프레임이라 좌표가 우연히
        // 일치하지만, 레이아웃이 어긋나면 조용히 깨짐 → 명시 변환으로 좌표계 안전성 확보(리뷰 반영).
        let vp = superview.map { pdfView.convert(point, from: $0) } ?? point
        if let s = selected, let pg = selectedPage, handleFixedCorner(of: s, page: pg, atViewPoint: vp) != nil {
            return self
        }
        if let page = pdfView.page(for: vp, nearest: true), editable(at: vp, on: page) != nil { return self }
        return nil
    }

    // MARK: 마우스
    override func mouseDown(with event: NSEvent) {
        if signing { mode = .ink; windowPoints = [event.locationInWindow]; needsDisplay = true; return }
        if whiteoutMode { mode = .whiteout; windowPoints = [event.locationInWindow, event.locationInWindow]; needsDisplay = true; return }
        guard let pdfView else { return }
        let vp = pdfView.convert(event.locationInWindow, from: nil)

        if let s = selected, let pg = selectedPage,
           let fixed = handleFixedCorner(of: s, page: pg, atViewPoint: vp) {
            mode = .resize; startBounds = s.bounds; resizeFixedPage = fixed
            lockAspect = (s as? ImageStampAnnotation)?.image.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) }
                ?? (s.bounds.height / max(1, s.bounds.width))
            resizeStartFont = s.font?.pointSize ?? 24
            return
        }
        if let page = pdfView.page(for: vp, nearest: true), let s = editable(at: vp, on: page) {
            selected = s; selectedPage = page
            window?.makeFirstResponder(self)
            if event.clickCount >= 2, s.type == "FreeText" { onEditText?(s); mode = .none; needsDisplay = true; return }
            mode = .move; startWindow = event.locationInWindow; startBounds = s.bounds
            needsDisplay = true
            return
        }
        mode = .none
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pdfView else { return }
        switch mode {
        case .ink:
            windowPoints.append(event.locationInWindow); needsDisplay = true
        case .whiteout:
            if windowPoints.count == 2 { windowPoints[1] = event.locationInWindow; needsDisplay = true }
        case .move:
            guard let s = selected, let pg = selectedPage else { return }
            let pg0 = pdfView.convert(pdfView.convert(startWindow, from: nil), to: pg)
            let pg1 = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: pg)
            s.bounds = startBounds.offsetBy(dx: pg1.x - pg0.x, dy: pg1.y - pg0.y)
            redraw()
        case .resize:
            guard let s = selected, let pg = selectedPage else { return }
            let m = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: pg)
            var w = abs(m.x - resizeFixedPage.x), h = abs(m.y - resizeFixedPage.y)
            if event.modifierFlags.contains(.shift) {
                let targetH = w * lockAspect
                if targetH >= h { h = targetH } else { w = h / max(0.0001, lockAspect) }
            }
            w = max(8, w); h = max(8, h)
            let dx = m.x >= resizeFixedPage.x ? w : -w
            let dy = m.y >= resizeFixedPage.y ? h : -h
            let drag = CGPoint(x: resizeFixedPage.x + dx, y: resizeFixedPage.y + dy)
            s.bounds = CGRect(x: min(resizeFixedPage.x, drag.x), y: min(resizeFixedPage.y, drag.y), width: w, height: h)
            if s.type == "FreeText" {   // 박스 크기에 맞춰 글자 크기도 변경
                s.font = s.font?.withSize(resizeStartFont * (h / max(1, startBounds.height)))
            }
            redraw()
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .ink: commitInk(); windowPoints = []; needsDisplay = true
        case .whiteout: commitWhiteout(); windowPoints = []; needsDisplay = true
        case .move, .resize:
            if let s = selected, let doc {
                if mode == .resize, s.type == "FreeText" {
                    let fb = s.bounds, ff = s.font?.pointSize ?? resizeStartFont
                    s.bounds = startBounds; s.font = s.font?.withSize(resizeStartFont)
                    doc.setTextFrame(s, fb, ff, name: "크기 조절")
                } else {
                    let final = s.bounds; s.bounds = startBounds
                    doc.setAnnotationBounds(s, final, name: mode == .resize ? "크기 조절" : "이동")
                }
            }
            needsDisplay = true
        case .none: break
        }
        mode = .none
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), selected != nil { deleteSelected() }
        else { super.keyDown(with: event) }
    }

    func deleteSelected() {
        guard let s = selected, let pg = selectedPage, let doc else { return }
        doc.removeAnnotation(s, from: pg, name: "삭제")
        deselect()
    }
    func deselect() { selected = nil; selectedPage = nil; needsDisplay = true }

    // MARK: 그리기
    override func draw(_ dirtyRect: NSRect) {
        if signing { drawInkPreview(); return }
        if whiteoutMode { drawWhiteoutPreview(); return }
        guard let s = selected, let pg = selectedPage else { return }
        let c = viewCorners(of: s, page: pg)
        guard c.count == 4 else { return }
        let box = NSBezierPath()
        box.move(to: c[0]); box.line(to: c[1]); box.line(to: c[2]); box.line(to: c[3]); box.close()
        NSColor.systemBlue.setStroke(); box.lineWidth = 1; box.stroke()
        for p in c {
            let r = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); NSBezierPath(rect: r).fill()
            NSColor.systemBlue.setStroke(); NSBezierPath(rect: r).stroke()
        }
    }

    private func drawInkPreview() {
        guard windowPoints.count > 1 else { return }
        let path = NSBezierPath(); path.lineWidth = inkWidth
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: convert(windowPoints[0], from: nil))
        for p in windowPoints.dropFirst() { path.line(to: convert(p, from: nil)) }
        inkColor.setStroke(); path.stroke()
    }

    private func drawWhiteoutPreview() {
        guard windowPoints.count == 2 else { return }
        let p0 = convert(windowPoints[0], from: nil), p1 = convert(windowPoints[1], from: nil)
        let r = NSRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        NSColor.white.withAlphaComponent(0.85).setFill(); NSBezierPath(rect: r).fill()
        let path = NSBezierPath(rect: r); path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.gray.setStroke(); path.stroke()
    }

    private func commitWhiteout() {
        guard windowPoints.count == 2, let pdfView, let doc else { return }
        let v0 = pdfView.convert(windowPoints[0], from: nil), v1 = pdfView.convert(windowPoints[1], from: nil)
        guard let page = pdfView.page(for: v0, nearest: true) else { return }
        let p0 = pdfView.convert(v0, to: page), p1 = pdfView.convert(v1, to: page)
        let rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        if rect.width < 4 || rect.height < 4 { return }
        doc.addWhiteout(rect, to: page)
    }

    private func redraw() { pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero); needsDisplay = true }

    // MARK: 잉크 커밋
    private func commitInk() {
        guard windowPoints.count > 1, let pdfView, let doc else { return }
        let viewPoints = windowPoints.map { pdfView.convert($0, from: nil) }
        guard let page = pdfView.page(for: viewPoints[0], nearest: true) else { return }
        let pagePoints = viewPoints.map { pdfView.convert($0, to: page) }
        let lineW = inkWidth / pdfView.scaleFactor
        let path = NSBezierPath(); path.lineWidth = lineW
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: pagePoints[0]); for p in pagePoints.dropFirst() { path.line(to: p) }
        let ann = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .ink, withProperties: nil)
        ann.color = inkColor
        let border = PDFBorder(); border.lineWidth = lineW; ann.border = border
        ann.add(path)
        doc.addAnnotation(ann, to: page)
    }

    // MARK: 헬퍼
    /// 이동/리사이즈 가능한 주석(도장·텍스트).
    private func editable(at viewPoint: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        guard let pdfView else { return nil }
        let pagePt = pdfView.convert(viewPoint, to: page)
        for ann in page.annotations.reversed() {
            let movable = (ann is ImageStampAnnotation) || ann.type == "FreeText" || ann.type == "Square"
            if movable, ann.bounds.contains(pagePt) { return ann }
        }
        return nil
    }

    private func viewCorners(of ann: PDFAnnotation, page: PDFPage) -> [CGPoint] {
        guard let pdfView else { return [] }
        let b = ann.bounds
        let pc = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                  CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
        return pc.map { pdfView.convert($0, from: page) }
    }

    private func handleFixedCorner(of ann: PDFAnnotation, page: PDFPage, atViewPoint vp: CGPoint) -> CGPoint? {
        let vc = viewCorners(of: ann, page: page)
        guard vc.count == 4 else { return nil }
        let opposite = [2, 3, 0, 1]
        let b = ann.bounds
        let pc = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                  CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
        for (i, c) in vc.enumerated() {
            if abs(c.x - vp.x) <= handleR, abs(c.y - vp.y) <= handleR { return pc[opposite[i]] }
        }
        return nil
    }
}
