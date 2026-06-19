import CoreGraphics
import CoreImage
import Core

// MARK: - 벡터 → CIImage 래스터화 (설계 §3.5, V1a)
// 노드의 union bbox 크기 CGContext에 도형을 그려 CIImage로. document 좌표(좌하단)에서
// CGContext 기본 좌하단 좌표계와 일치하므로 별도 Y 플립 없이 그린다(설계 §5.2 좌표계).
//
// 검토자 C1(줌/회전 시 벡터 품질) 노트: V1a는 "한 번 래스터화"라 줌인 시 약간 흐려질 수 있다.
// 줌 정착 시 재래스터화·캐시 무효화는 V1b/M3에서. 주석/도형 용도엔 충분.

public enum VectorRasterizer {
    /// 노드를 래스터화해 document 좌표에 위치한 CIImage 반환(없으면 nil).
    public static func rasterize(_ node: VectorNode) -> CIImage? {
        guard let bounds = node.unionBounds else { return nil }
        let w = Int(bounds.size.x.rounded(.up)), h = Int(bounds.size.y.rounded(.up))
        guard w > 0, h > 0, w < 20000, h < 20000 else { return nil }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }

        // bbox 로컬 좌표로 이동(도형 document 좌표 - bbox 원점).
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for shape in node.shapes { draw(shape, in: ctx) }

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(
            by: CGAffineTransform(translationX: bounds.origin.x, y: bounds.origin.y))
    }

    private static func draw(_ shape: VectorShape, in ctx: CGContext) {
        let rect = CGRect(x: min(shape.p0.x, shape.p1.x), y: min(shape.p0.y, shape.p1.y),
                          width: abs(shape.p1.x - shape.p0.x), height: abs(shape.p1.y - shape.p0.y))
        let path = CGMutablePath()
        switch shape.kind {
        case .rectangle: path.addRect(rect)
        case .oval: path.addEllipse(in: rect)
        case .line:
            path.move(to: CGPoint(x: shape.p0.x, y: shape.p0.y))
            path.addLine(to: CGPoint(x: shape.p1.x, y: shape.p1.y))
        }

        if let fill = shape.fill, shape.kind != .line {
            ctx.addPath(path)
            ctx.setFillColor(cgColor(fill))
            ctx.fillPath()
        }
        if let stroke = shape.stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(cgColor(stroke.color))
            ctx.setLineWidth(stroke.width)
            ctx.strokePath()
        }
    }

    private static func cgColor(_ c: RGBA8) -> CGColor {
        CGColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }
}
