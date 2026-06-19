import PDFKit
import CoreGraphics

/// 이미지(도장/서명 PNG/로고)를 페이지에 얹는 스탬프 주석.
/// macOS 26에서 저장 시 외형이 PDF에 보존됨(헤드리스 검증). 방향=정상(좌하단 좌표).
final class ImageStampAnnotation: PDFAnnotation {
    var image: CGImage?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image else { return }
        context.draw(image, in: bounds)
    }
}
