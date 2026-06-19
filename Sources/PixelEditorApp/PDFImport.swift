import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import Core

// MARK: - PDF / EPS 가져오기 (래스터화)
// PDF: CGPDFDocument로 네이티브 렌더(의존성 0).
// EPS: macOS 26은 네이티브로 못 엶 → Ghostscript(`gs`)가 있으면 EPS→PDF 변환 후 동일 경로.

extension PixelEditorDocument {

    /// PDF/EPS를 래스터화해 레이어로. scale = DPI/72 (가져오기 다이얼로그가 분기해 호출).
    func importVector(at url: URL, scale: CGFloat) {
        let isEPS = url.pathExtension.lowercased() == "eps"
        let pdfURL: URL?
        if isEPS {
            guard let converted = Self.epsToTempPDF(url) else {
                Self.alertGhostscriptMissing()
                return
            }
            pdfURL = converted
        } else {
            pdfURL = url
        }
        guard let pdfURL, let cg = Self.rasterizePDF(pdfURL, scale: scale) else {
            Self.alert("불러올 수 없습니다: \(url.lastPathComponent)")
            return
        }
        importImage(cg, name: url.deletingPathExtension().lastPathComponent)
        if isEPS { try? FileManager.default.removeItem(at: pdfURL) }
    }

    // MARK: PDF → CGImage
    static func rasterizePDF(_ url: URL, page pageNumber: Int = 1, scale: CGFloat) -> CGImage? {
        guard let doc = CGPDFDocument(url as CFURL),
              let page = doc.page(at: max(1, pageNumber)) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        // 과대 해상도 방지: 최대 변 8000px로 클램프.
        let s = min(scale, 8000 / max(box.width, box.height))
        let w = Int((box.width * s).rounded(.up)), h = Int((box.height * s).rounded(.up))
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: EPS → 임시 PDF (Ghostscript)
    static func findGhostscript() -> URL? {
        for path in ["/opt/homebrew/bin/gs", "/usr/local/bin/gs", "/usr/bin/gs"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func epsToTempPDF(_ epsURL: URL) -> URL? {
        guard let gs = findGhostscript() else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        let proc = Process()
        proc.executableURL = gs
        proc.arguments = ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dEPSCrop",
                          "-sDEVICE=pdfwrite", "-sOutputFile=\(out.path)", epsURL.path]
        proc.standardOutput = nil; proc.standardError = nil
        do {
            try proc.run(); proc.waitUntilExit()
        } catch { return nil }
        return (proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)) ? out : nil
    }

    // MARK: 알림
    private static func alert(_ message: String) {
        let a = NSAlert(); a.messageText = message; a.alertStyle = .warning; a.runModal()
    }
    private static func alertGhostscriptMissing() {
        let a = NSAlert()
        a.messageText = "EPS를 열려면 Ghostscript가 필요합니다"
        a.informativeText = "macOS는 EPS를 네이티브로 렌더하지 못합니다.\n터미널에서 다음을 실행하세요:\n\n    brew install ghostscript\n\n설치 후 다시 시도하면 EPS가 바로 열립니다."
        a.alertStyle = .informational
        a.runModal()
    }
}
