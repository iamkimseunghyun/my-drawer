import AppKit
import CoreText
import CoreGraphics
import CoreImage
import Core

// MARK: - 텍스트 → CIImage 래스터화 (V1b-3)
// 단일 라인. Core Text(CTLine)로 bottom-left CGContext에 그려 다른 래스터화와 좌표 일관.

public enum TextRasterizer {
    private static func makeLine(_ node: TextNode) -> (CTLine, CGRect) {
        let font = node.fontName.flatMap { NSFont(name: $0, size: CGFloat(node.fontSize)) }
            ?? NSFont.systemFont(ofSize: CGFloat(node.fontSize))
        let color = NSColor(srgbRed: CGFloat(node.color.r) / 255, green: CGFloat(node.color.g) / 255,
                            blue: CGFloat(node.color.b) / 255, alpha: CGFloat(node.color.a) / 255)
        let attr = NSAttributedString(string: node.text.isEmpty ? " " : node.text,
                                      attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, [])   // typographic: origin.y = -descent
        return (line, bounds)
    }

    /// 텍스트 픽셀 크기(레이어 base box 크기).
    public static func measure(_ node: TextNode) -> CGSize {
        let (_, b) = makeLine(node)
        return CGSize(width: ceil(b.width) + 2, height: ceil(b.height) + 2)
    }

    /// document 좌표 origin에 위치한 텍스트 CIImage.
    public static func rasterize(_ node: TextNode) -> CIImage? {
        let (line, b) = makeLine(node)
        let w = Int(ceil(b.width) + 2), h = Int(ceil(b.height) + 2)
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: 1 - b.origin.x, y: 1 - b.origin.y)   // descent만큼 위로
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(translationX: node.origin.x, y: node.origin.y))
    }
}
