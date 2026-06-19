import XCTest
import simd
@testable import Core

// 브러시 엔진 픽셀 로직 증명 (M2a). 렌더링은 눈으로 보지만 정확성은 테스트로 못 박는다.
final class PaintTests: XCTestCase {

    private func alpha(_ c: PaintCanvas, _ x: Int, _ y: Int) -> UInt8 {
        c.pixels[(y * c.width + x) * 4 + 3]
    }

    func testStampPaintsCenterNotCorner() {
        let c = PaintCanvas(width: 64, height: 64, tileSize: 32)
        c.beginStroke()
        c.stampDab(cx: 32, cy: 32, radius: 10, hardness: 1, color: RGBA8(255, 0, 0, 255), flow: 1, erase: false)
        _ = c.endStroke()

        let i = (32 * 64 + 32) * 4
        XCTAssertEqual(c.pixels[i], 255, "중심 R")
        XCTAssertEqual(c.pixels[i + 3], 255, "중심 알파 불투명")
        XCTAssertEqual(alpha(c, 0, 0), 0, "먼 구석은 미변경")
    }

    func testGradientFadesAcrossAxisAndUndoes() {
        let c = PaintCanvas(width: 64, height: 1, tileSize: 32)
        let before = c.pixels
        c.beginStroke()
        // 가로 A(0)→B(63): 빨강 불투명 → 빨강 투명.
        c.fillGradient(ax: 0, ay: 0, bx: 64, by: 0,
                       color0: RGBA8(255, 0, 0, 255), color1: RGBA8(255, 0, 0, 0))
        let delta = c.endStroke()

        let aL = alpha(c, 0, 0), aM = alpha(c, 32, 0), aR = alpha(c, 63, 0)
        XCTAssertGreaterThan(aL, 240, "시작=불투명")
        XCTAssertLessThan(aR, 16, "끝=투명")
        XCTAssertTrue(aM > 100 && aM < 156, "중간≈반투명(\(aM))")
        // premultiplied 빨강: 모든 픽셀에서 R == 알파.
        XCTAssertEqual(c.pixels[0], aL, "premult 시작 R==알파")
        XCTAssertEqual(c.pixels[(32 * 4)], aM, "premult 중간 R==알파")

        c.restore(delta.before)
        XCTAssertEqual(c.pixels, before, "undo로 정확히 복원")
    }

    func testWriteCoverageRoundTripsOrientation() {
        // 배경지우기 마스크 쓰기 방향 정합: writeCoverage→makeCGImage 가 원본 CGImage와 동일해야.
        // (틀리면 마스크가 상하 뒤집힘.) 비대칭 패턴(위 흰/아래 검정)으로 검증.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        func render(_ cg: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: 8 * 8 * 4)
            buf.withUnsafeMutableBytes {
                let ctx = CGContext(data: $0.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                                    bytesPerRow: 32, space: cs, bitmapInfo: info)!
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            return buf
        }
        // 소스 CGImage: CG 상단 절반(높은 y) 흰색 → 표시상 위쪽 흰색.
        let sctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                             space: cs, bitmapInfo: info)!
        sctx.setFillColor(CGColor(gray: 0, alpha: 1)); sctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        sctx.setFillColor(CGColor(gray: 1, alpha: 1)); sctx.fill(CGRect(x: 0, y: 4, width: 8, height: 4))
        let cg = sctx.makeImage()!

        let mask = PaintCanvas(width: 8, height: 8)
        mask.beginStroke(); mask.writeCoverage(cg); _ = mask.endStroke()
        guard let out = mask.makeCGImage() else { return XCTFail("makeCGImage nil") }
        XCTAssertEqual(render(cg), render(out), "writeCoverage→makeCGImage 는 원본과 동일(방향 보존)")
    }

    func testBrushSpacingControlsDabDensity() {
        let a = SIMD2<Double>(0, 0), b = SIMD2<Double>(100, 0)
        let tight = StrokeSampler.dabCenters(from: a, to: b, spacing: 20 * 0.1)   // radius20, 간격0.1 → 2px
        let loose = StrokeSampler.dabCenters(from: a, to: b, spacing: 20 * 1.0)   // 간격1.0 → 20px
        XCTAssertGreaterThan(tight.count, loose.count, "촘촘한 간격 = 더 많은 dab")
        XCTAssertEqual(loose.count, 5, "100px / 20px = 5 dab")
    }

    func testGradientLivePreviewRestoreDoesNotStack() {
        // 라이브 미리보기: 매 프레임 원본 복원 후 다시 그림 → 최종은 마지막 드래그만 반영.
        let c = PaintCanvas(width: 64, height: 1, tileSize: 32)
        c.beginStroke()
        let before = c.tilesBytes(c.allTileIndices())
        // 프레임1: 짧은 그라디언트(0→16)
        c.fillGradient(ax: 0, ay: 0, bx: 16, by: 0, color0: RGBA8(255, 0, 0, 255), color1: RGBA8(255, 0, 0, 0))
        // 프레임2: 복원 후 긴 그라디언트(0→64)로 교체
        c.restore(before)
        c.fillGradient(ax: 0, ay: 0, bx: 64, by: 0, color0: RGBA8(255, 0, 0, 255), color1: RGBA8(255, 0, 0, 0))
        _ = c.endStroke()
        // x=32: 0→16 그라디언트면 이미 투명(>16), 0→64면 반투명. 교체됐으면 반투명이어야.
        XCTAssertTrue(alpha(c, 32, 0) > 100 && alpha(c, 32, 0) < 156, "마지막 드래그만 반영(\(alpha(c, 32, 0)))")
    }

    func testStrokeUndoRestoresExactly() {
        let c = PaintCanvas(width: 64, height: 64, tileSize: 32)
        c.beginStroke()
        c.stampDab(cx: 20, cy: 20, radius: 8, hardness: 0.5, color: RGBA8(0, 200, 0), flow: 1, erase: false)
        let delta = c.endStroke()

        XCTAssertGreaterThan(alpha(c, 20, 20), 0, "스트로크 후 칠해짐")
        XCTAssertFalse(delta.isEmpty)

        c.restore(delta.before)
        XCTAssertEqual(alpha(c, 20, 20), 0, "undo(before) → 원상복구")
        c.restore(delta.after)
        XCTAssertGreaterThan(alpha(c, 20, 20), 0, "redo(after) → 재적용")
    }

    func testEraseReducesAlpha() {
        let c = PaintCanvas(width: 32, height: 32, tileSize: 32)
        c.beginStroke()
        c.stampDab(cx: 16, cy: 16, radius: 12, hardness: 1, color: RGBA8(255, 255, 255, 255), flow: 1, erase: false)
        _ = c.endStroke()
        let painted = alpha(c, 16, 16)
        XCTAssertEqual(painted, 255)

        c.beginStroke()
        c.stampDab(cx: 16, cy: 16, radius: 12, hardness: 1, color: RGBA8(0, 0, 0), flow: 1, erase: true)
        _ = c.endStroke()
        XCTAssertLessThan(alpha(c, 16, 16), painted, "지우개가 알파를 줄임")
    }

    func testCGImageRoundsTrip() {
        let c = PaintCanvas(width: 16, height: 16)
        c.beginStroke()
        c.stampDab(cx: 8, cy: 8, radius: 6, hardness: 1, color: RGBA8(10, 20, 30, 255), flow: 1, erase: false)
        _ = c.endStroke()
        let img = c.makeCGImage()
        XCTAssertNotNil(img)
        XCTAssertEqual(img?.width, 16)
        XCTAssertEqual(img?.height, 16)
    }

    func testFloodFillAndUndo() {
        let c = PaintCanvas(width: 16, height: 16, tileSize: 16)
        c.beginStroke()
        c.floodFill(startX: 8, startY: 8, color: RGBA8(0, 0, 255), tolerance: 10)
        let delta = c.endStroke()

        // 빈(투명) 캔버스 전체가 연결돼 있으니 모두 파랑 불투명으로 채워진다.
        XCTAssertEqual(c.pixels[(8 * 16 + 8) * 4 + 2], 255, "중심 B=255")
        XCTAssertEqual(c.pixels[(8 * 16 + 8) * 4 + 3], 255, "중심 알파 불투명")
        XCTAssertEqual(c.pixels[3], 255, "구석도 채워짐(연결됨)")

        c.restore(delta.before)
        XCTAssertEqual(c.pixels[(8 * 16 + 8) * 4 + 3], 0, "undo로 원상복구")
    }

    func testDabSampling() {
        let pts = StrokeSampler.dabCenters(from: SIMD2(0, 0), to: SIMD2(10, 0), spacing: 5)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].x, 5, accuracy: 1e-9)
        XCTAssertEqual(pts[1].x, 10, accuracy: 1e-9)

        XCTAssertEqual(StrokeSampler.dabCenters(from: SIMD2(0, 0), to: SIMD2(0, 0), spacing: 5).count, 0)
        // 짧은 이동도 끝점 1개는 찍는다
        XCTAssertEqual(StrokeSampler.dabCenters(from: SIMD2(0, 0), to: SIMD2(1, 0), spacing: 5).count, 1)
    }
}
