import Foundation
import CoreGraphics

// MARK: - 페인트 캔버스 (설계 §5.3 / §7)
// CPU RGBA8 premultiplied·sRGB 버퍼(top-left). 브러시가 여기에 dab을 스탬프한다.
// 타일 단위 dirty 추적 + before/after 델타로 스트로크 1회 = Undo 1회(설계 §7.2).
// M2a: 풀캔버스 버퍼 + Metal 미사용(정확성 우선). sparse 타일 저장·Metal 스탬프는 M2b 최적화.

public struct PaintDelta: Sendable {
    public var before: [TileIndex: [UInt8]]
    public var after: [TileIndex: [UInt8]]
    public var isEmpty: Bool { before.isEmpty }
}

public final class PaintCanvas {
    public let width: Int
    public let height: Int
    public let tileSize: Int
    public private(set) var pixels: [UInt8]   // RGBA8 premultiplied, sRGB, row-major top-left

    private var strokeBefore: [TileIndex: [UInt8]] = [:]
    private var strokeTouched: Set<TileIndex> = []

    public init(width: Int, height: Int, tileSize: Int = 256) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.tileSize = max(1, tileSize)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    // MARK: 스트로크
    public func beginStroke() {
        strokeBefore.removeAll(keepingCapacity: true)
        strokeTouched.removeAll(keepingCapacity: true)
    }

    /// 소프트 원형 dab. (cx,cy)는 이미지 픽셀 좌표(top-left).
    public func stampDab(cx: Double, cy: Double, radius: Double,
                         hardness: Double, color: RGBA8, flow: Double, erase: Bool) {
        let r = max(0.5, radius)
        let minX = max(0, Int((cx - r).rounded(.down)))
        let maxX = min(width - 1, Int((cx + r).rounded(.up)))
        let minY = max(0, Int((cy - r).rounded(.down)))
        let maxY = min(height - 1, Int((cy + r).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }

        captureTiles(minX: minX, minY: minY, maxX: maxX, maxY: maxY)

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - cx
                let dy = Double(y) + 0.5 - cy
                let dist = (dx * dx + dy * dy).squareRoot()
                let cov = coverage(dist / r, hardness: hardness)
                if cov <= 0 { continue }
                blend(x: x, y: y, color: color, alpha: cov * flow, erase: erase)
            }
        }
    }

    /// 거리비 t(0..1)에서의 커버리지. hardness=1 → 가장자리까지 1, hardness=0 → 중심부터 선형 감쇠.
    private func coverage(_ t: Double, hardness: Double) -> Double {
        if t >= 1 { return 0 }
        if hardness >= 0.999 { return 1 }
        if t <= hardness { return 1 }
        return (1 - t) / (1 - hardness)
    }

    private func blend(x: Int, y: Int, color: RGBA8, alpha: Double, erase: Bool) {
        let i = (y * width + x) * 4
        let dr = Double(pixels[i]) / 255, dg = Double(pixels[i + 1]) / 255
        let db = Double(pixels[i + 2]) / 255, da = Double(pixels[i + 3]) / 255
        if erase {
            let f = 1 - max(0, min(1, alpha))
            store(i, dr * f, dg * f, db * f, da * f)
        } else {
            let srcA = max(0, min(1, alpha)) * Double(color.a) / 255
            let sr = Double(color.r) / 255 * srcA
            let sg = Double(color.g) / 255 * srcA
            let sb = Double(color.b) / 255 * srcA
            let inv = 1 - srcA
            store(i, sr + dr * inv, sg + dg * inv, sb + db * inv, srcA + da * inv)
        }
    }

    private func store(_ i: Int, _ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        pixels[i]     = UInt8(max(0, min(255, (r * 255).rounded())))
        pixels[i + 1] = UInt8(max(0, min(255, (g * 255).rounded())))
        pixels[i + 2] = UInt8(max(0, min(255, (b * 255).rounded())))
        pixels[i + 3] = UInt8(max(0, min(255, (a * 255).rounded())))
    }

    /// 버킷 채우기 (4방향 flood). (startX,startY)는 이미지 픽셀 좌표. beginStroke/endStroke 사이에 호출.
    public func floodFill(startX: Int, startY: Int, color: RGBA8, tolerance: Int) {
        guard startX >= 0, startY >= 0, startX < width, startY < height else { return }
        let target = pixelRGBA(startX, startY)
        let repl = RGBA8(color.r, color.g, color.b, 255)        // 불투명 = premult 그대로
        if matches(target, repl, 0) { return }                  // 같은 색이면 무한루프 방지
        var stack: [(Int, Int)] = [(startX, startY)]
        // 스택에 넣기 전 경계·색 일치를 미리 검사 → 대형 채우기에서 중복 push/pop 절감(CodeRabbit/Gemini 리뷰).
        // pop 시점 재검사는 같은 픽셀이 여러 이웃에서 push될 수 있어 여전히 필요(이미 채움이면 skip).
        func enqueueIfFillable(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let c = pixelRGBA(x, y)
            if matches(c, target, tolerance), !matches(c, repl, 0) { stack.append((x, y)) }
        }
        while let (x, y) = stack.popLast() {
            let cur = pixelRGBA(x, y)
            if !matches(cur, target, tolerance) || matches(cur, repl, 0) { continue }   // 이미 채움/불일치
            captureTile(forX: x, y: y)
            let i = (y * width + x) * 4
            pixels[i] = repl.r; pixels[i + 1] = repl.g; pixels[i + 2] = repl.b; pixels[i + 3] = 255
            enqueueIfFillable(x + 1, y); enqueueIfFillable(x - 1, y)
            enqueueIfFillable(x, y + 1); enqueueIfFillable(x, y - 1)
        }
    }

    /// 선형 그라디언트로 전체 캔버스를 채운다. 끝점 A,B는 이미지 픽셀 좌표(top-left).
    /// 각 픽셀을 A→B 축에 투영(t∈0…1)해 color0→color1 보간 후 기존 위에 src-over.
    /// (color1 alpha=0 이면 페이드.) beginStroke/endStroke 사이에 호출.
    public func fillGradient(ax: Double, ay: Double, bx: Double, by: Double,
                             color0: RGBA8, color1: RGBA8) {
        guard width > 0, height > 0 else { return }
        captureTiles(minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let r0 = Double(color0.r), g0 = Double(color0.g), b0 = Double(color0.b), a0 = Double(color0.a)
        let r1 = Double(color1.r), g1 = Double(color1.g), b1 = Double(color1.b), a1 = Double(color1.a)
        for y in 0..<height {
            for x in 0..<width {
                var t = 0.0
                if len2 >= 1e-9 {
                    let px = Double(x) + 0.5 - ax, py = Double(y) + 0.5 - ay
                    t = max(0, min(1, (px * dx + py * dy) / len2))
                }
                let r = r0 + (r1 - r0) * t, g = g0 + (g1 - g0) * t
                let b = b0 + (b1 - b0) * t, a = a0 + (a1 - a0) * t
                blend(x: x, y: y,
                      color: RGBA8(UInt8(r.rounded()), UInt8(g.rounded()), UInt8(b.rounded()), 255),
                      alpha: a / 255, erase: false)
            }
        }
    }

    private func pixelRGBA(_ x: Int, _ y: Int) -> RGBA8 {
        let i = (y * width + x) * 4
        return RGBA8(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }
    private func matches(_ a: RGBA8, _ b: RGBA8, _ tol: Int) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= tol && abs(Int(a.g) - Int(b.g)) <= tol &&
        abs(Int(a.b) - Int(b.b)) <= tol && abs(Int(a.a) - Int(b.a)) <= tol
    }
    private func captureTile(forX x: Int, y: Int) {
        let idx = TileIndex(x: x / tileSize, y: y / tileSize)
        if strokeBefore[idx] == nil { strokeBefore[idx] = tileBytes(idx) }
        strokeTouched.insert(idx)
    }

    public func endStroke() -> PaintDelta {
        var after: [TileIndex: [UInt8]] = [:]
        for idx in strokeTouched { after[idx] = tileBytes(idx) }
        let delta = PaintDelta(before: strokeBefore, after: after)
        strokeBefore.removeAll(keepingCapacity: true)
        strokeTouched.removeAll(keepingCapacity: true)
        return delta
    }

    // MARK: 타일 입출력 (Undo 델타용)
    public func tilesBytes(_ indices: [TileIndex]) -> [TileIndex: [UInt8]] {
        var out: [TileIndex: [UInt8]] = [:]
        for idx in indices { out[idx] = tileBytes(idx) }
        return out
    }
    public func restore(_ tiles: [TileIndex: [UInt8]]) {
        for (idx, bytes) in tiles { writeTile(idx, bytes) }
    }
    /// CGImage를 버퍼에 로드(캔버스 크기로 그림). 정적 이미지 레이어 → 편집 가능 페인트 캔버스 변환용.
    /// makeCGImage와 같은 컨텍스트 규약이라 makeCGImage()로 원본을 그대로 복원(방향 보존, 테스트로 증명).
    public func loadCGImage(_ cg: CGImage) {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: cs, bitmapInfo: info) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 커버리지 CGImage(흰=보임)를 불투명 그레이스케일로 버퍼에 그린다(캔버스 크기로 스케일).
    /// 배경 지우기: Vision 전경 마스크 → 마스크 캔버스. makeCGImage와 같은 컨텍스트 규약이라 방향 정합.
    /// beginStroke/endStroke 사이에 호출하면 undo 델타로 잡힌다.
    public func writeCoverage(_ cg: CGImage) {
        writeCoverage(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    /// rect(document/캔버스 좌표, 좌하단 원점 — makeCGImage 컨텍스트와 동일)에 커버리지를 배치.
    /// 레이어가 캔버스를 안 채우면 layerDocumentRect 를 넘겨 위치 정합.
    public func writeCoverage(_ cg: CGImage, in rect: CGRect) {
        captureTiles(minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: cs, bitmapInfo: info) else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))                              // 전체 배경=검정(숨김)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(cg, in: rect)                                                    // 전경=흰색(보임)
        }
    }

    /// 전체 캔버스를 단색으로 채운다(마스크 초기화 등). 스트로크 추적 없음.
    public func fillSolid(_ color: RGBA8) {
        var i = 0
        while i < pixels.count {
            pixels[i] = color.r; pixels[i + 1] = color.g; pixels[i + 2] = color.b; pixels[i + 3] = color.a
            i += 4
        }
    }

    /// 전체 타일 인덱스(그라디언트 라이브 미리보기: 프레임마다 원본 복원용).
    public func allTileIndices() -> [TileIndex] {
        let nx = (width + tileSize - 1) / tileSize, ny = (height + tileSize - 1) / tileSize
        var out: [TileIndex] = []; out.reserveCapacity(nx * ny)
        for ty in 0..<ny { for tx in 0..<nx { out.append(TileIndex(x: tx, y: ty)) } }
        return out
    }

    private func captureTiles(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        for ty in (minY / tileSize)...(maxY / tileSize) {
            for tx in (minX / tileSize)...(maxX / tileSize) {
                let idx = TileIndex(x: tx, y: ty)
                if strokeBefore[idx] == nil { strokeBefore[idx] = tileBytes(idx) }
                strokeTouched.insert(idx)
            }
        }
    }

    private func tileRect(_ idx: TileIndex) -> (x: Int, y: Int, w: Int, h: Int) {
        let x = idx.x * tileSize, y = idx.y * tileSize
        return (x, y, max(0, min(tileSize, width - x)), max(0, min(tileSize, height - y)))
    }
    private func tileBytes(_ idx: TileIndex) -> [UInt8] {
        let r = tileRect(idx)
        var out = [UInt8](repeating: 0, count: r.w * r.h * 4)
        for row in 0..<r.h {
            let src = ((r.y + row) * width + r.x) * 4
            let dst = row * r.w * 4
            out.replaceSubrange(dst..<(dst + r.w * 4), with: pixels[src..<(src + r.w * 4)])
        }
        return out
    }
    private func writeTile(_ idx: TileIndex, _ bytes: [UInt8]) {
        let r = tileRect(idx)
        guard bytes.count == r.w * r.h * 4 else { return }
        for row in 0..<r.h {
            let dst = ((r.y + row) * width + r.x) * 4
            let src = row * r.w * 4
            pixels.replaceSubrange(dst..<(dst + r.w * 4), with: bytes[src..<(src + r.w * 4)])
        }
    }

    // MARK: 이미지화 (합성기 입력)
    public func makeCGImage() -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var data = pixels
        return data.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }
}
