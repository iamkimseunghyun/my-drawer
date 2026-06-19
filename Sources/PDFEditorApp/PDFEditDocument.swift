import AppKit
import PDFKit

/// PDF 편집 문서 (PDFKit 기반). 다중 페이지 + 페이지 작업 + PDF 저장(원본 벡터/텍스트 보존).
/// 기존 래스터 편집기(PixelEditorDocument)와 별도 모드. 서명/도장/텍스트 주석은 P2~P3.
final class PDFEditDocument: NSDocument {
    private(set) var pdf = PDFDocument()

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        // 새(빈) 문서면 빈 페이지 1장으로 시작.
        if pdf.pageCount == 0, let blank = Self.blankPage() { pdf.insert(blank, at: 0) }
        addWindowController(PDFEditWindowController(doc: self))
    }

    private static func blankPage(size: CGSize = CGSize(width: 612, height: 792)) -> PDFPage? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(box)
        ctx.endPDFPage(); ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    // MARK: 읽기/쓰기 (flat PDF)
    override func read(from data: Data, ofType typeName: String) throws {
        guard let d = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        pdf = d
        refreshWindows()
    }
    override func data(ofType typeName: String) throws -> Data {
        guard let d = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return d
    }

    var pageCount: Int { pdf.pageCount }

    private func refreshWindows() {
        for case let wc as PDFEditWindowController in windowControllers { wc.refresh() }
    }
    private func didChangePages() { refreshWindows() }   // dirty는 registerUndo가 표시

    // MARK: 페이지 작업 (undoable)
    func deletePage(at i: Int) {
        guard i >= 0, i < pdf.pageCount, let page = pdf.page(at: i) else { return }
        pdf.removePage(at: i)
        undoManager?.registerUndo(withTarget: self) { $0.insertPage(page, at: i) }
        undoManager?.setActionName("페이지 삭제")
        didChangePages()
    }
    func insertPage(_ page: PDFPage, at i: Int) {
        let idx = min(max(0, i), pdf.pageCount)
        pdf.insert(page, at: idx)
        undoManager?.registerUndo(withTarget: self) { $0.deletePage(at: idx) }
        undoManager?.setActionName("페이지 삽입")
        didChangePages()
    }
    func rotatePage(at i: Int, by degrees: Int) {
        guard let page = pdf.page(at: i) else { return }
        page.rotation += degrees
        undoManager?.registerUndo(withTarget: self) { $0.rotatePage(at: i, by: -degrees) }
        undoManager?.setActionName("페이지 회전")
        didChangePages()
    }
    func movePage(from i: Int, to j: Int) {
        guard i != j, i >= 0, i < pdf.pageCount, j >= 0, j < pdf.pageCount else { return }
        pdf.exchangePage(at: i, withPageAt: j)
        undoManager?.registerUndo(withTarget: self) { $0.movePage(from: j, to: i) }
        undoManager?.setActionName("페이지 이동")
        didChangePages()
    }

    // MARK: 주석 (서명/도장/텍스트 등, undoable). 깜빡임 없이 — bounds 변경 영역만 갱신.
    func addAnnotation(_ ann: PDFAnnotation, to page: PDFPage, name: String = "서명") {
        page.addAnnotation(ann)
        undoManager?.registerUndo(withTarget: self) { $0.removeAnnotation(ann, from: page, name: name) }
        undoManager?.setActionName(name)
        refreshInWindows()
    }
    func removeAnnotation(_ ann: PDFAnnotation, from page: PDFPage, name: String = "서명") {
        let saved = ann.bounds
        ann.bounds = .zero        // 이전 영역을 PDFView가 무효화하도록(리로드 없이 본문 갱신)
        page.removeAnnotation(ann)
        undoManager?.registerUndo(withTarget: self) {
            ann.bounds = saved; $0.addAnnotation(ann, to: page, name: name)
        }
        undoManager?.setActionName(name)
        refreshInWindows()
    }
    private func refreshInWindows() {
        for case let wc as PDFEditWindowController in windowControllers { wc.refreshAnnotations() }
    }

    /// 주석 bounds 변경(이동/리사이즈) — 자기대칭 undo. 가벼운 갱신.
    func setAnnotationBounds(_ ann: PDFAnnotation, _ bounds: CGRect, name: String) {
        let reverse = ann.bounds
        ann.bounds = bounds
        undoManager?.registerUndo(withTarget: self) { $0.setAnnotationBounds(ann, reverse, name: name) }
        undoManager?.setActionName(name)
        refreshInWindows()
    }

    /// 텍스트 박스(freeText)를 현재 페이지 중앙에 추가. 이동/리사이즈/더블클릭 편집.
    func addTextAnnotation(_ text: String, toPageAt i: Int) {
        guard let page = pdf.page(at: i) else { return }
        let font = NSFont.systemFont(ofSize: 24)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let w = max(80, size.width + 14), h = max(30, size.height + 10)
        let pb = page.bounds(for: .mediaBox)
        let bounds = CGRect(x: pb.midX - w / 2, y: pb.midY - h / 2, width: w, height: h)
        let ann = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        ann.contents = text
        ann.font = font
        ann.fontColor = .black
        ann.color = .clear
        ann.alignment = .center
        addAnnotation(ann, to: page, name: "텍스트")
    }

    /// 텍스트 박스 크기 + 폰트 동시 변경(리사이즈로 글자 크기 변경). 자기대칭 undo.
    func setTextFrame(_ ann: PDFAnnotation, _ bounds: CGRect, _ fontSize: CGFloat, name: String) {
        let revBounds = ann.bounds, revFont = ann.font?.pointSize ?? fontSize
        ann.font = ann.font?.withSize(fontSize)
        ann.bounds = bounds   // bounds 마지막 → PDFView 재렌더
        undoManager?.registerUndo(withTarget: self) { $0.setTextFrame(ann, revBounds, revFont, name: name) }
        undoManager?.setActionName(name)
        refreshInWindows()
    }

    /// 텍스트 내용 변경 — 새 텍스트에 맞춰 박스를 다시 재고 중심 유지. 자기대칭 undo.
    func setTextContents(_ ann: PDFAnnotation, _ text: String) {
        let font = ann.font ?? NSFont.systemFont(ofSize: 24)
        let sz = (text as NSString).size(withAttributes: [.font: font])
        let w = max(40, sz.width + 14), h = max(24, sz.height + 10)
        let c = CGPoint(x: ann.bounds.midX, y: ann.bounds.midY)
        setTextState(ann, contents: text, bounds: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
    }
    private func setTextState(_ ann: PDFAnnotation, contents: String, bounds: CGRect) {
        let revC = ann.contents ?? "", revB = ann.bounds
        ann.contents = contents
        ann.bounds = bounds
        undoManager?.registerUndo(withTarget: self) { $0.setTextState(ann, contents: revC, bounds: revB) }
        undoManager?.setActionName("텍스트 편집")
        refreshInWindows()
    }

    /// 화이트아웃: 영역을 흰 사각형으로 가린다(그 위에 텍스트 얹어 "수정").
    func addWhiteout(_ rect: CGRect, to page: PDFPage) {
        let ann = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        ann.interiorColor = .white
        ann.color = .white
        let b = PDFBorder(); b.lineWidth = 0; ann.border = b
        addAnnotation(ann, to: page, name: "화이트아웃")
    }

    /// 이미지를 현재 페이지에 도장/스탬프로 얹는다(중앙 배치, 드래그로 이동).
    func addImageStamp(_ image: NSImage, toPageAt i: Int) {
        guard let page = pdf.page(at: i), let cg = Self.cgImage(image) else { return }
        let pb = page.bounds(for: .mediaBox)
        let aspect = CGFloat(cg.height) / CGFloat(max(1, cg.width))
        let w = min(pb.width * 0.4, 220)
        let h = w * aspect
        let bounds = CGRect(x: pb.midX - w / 2, y: pb.midY - h / 2, width: w, height: h)
        let ann = ImageStampAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)
        ann.image = cg
        addAnnotation(ann, to: page, name: "도장/이미지")
    }
    private static func cgImage(_ image: NSImage) -> CGImage? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    func insertImagePage(_ image: NSImage, after i: Int) {
        guard let page = Self.pdfPage(from: image) else { return }
        insertPage(page, at: i + 1)
    }
    func insertPDF(at url: URL, after i: Int) {
        guard let other = PDFDocument(url: url) else { return }
        var idx = i + 1
        for p in 0..<other.pageCount {
            if let pg = other.page(at: p) { insertPage(pg, at: idx); idx += 1 }
        }
    }

    /// 이미지를 1페이지 PDF로 렌더 → PDFPage.
    private static func pdfPage(from image: NSImage) -> PDFPage? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.draw(cg, in: box)
        ctx.endPDFPage(); ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
