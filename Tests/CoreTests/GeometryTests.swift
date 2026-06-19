import XCTest
import simd
@testable import Core

// 설계 §5.2 / §9 M0: 좌표계 확정. 틀리면 전 도구 재작성이므로 테스트로 못 박는다.
final class GeometryTests: XCTestCase {

    func testViewDocumentRoundTrip() {
        let vp = Viewport(zoom: 1.7, panDevice: SIMD2(120, -45), backingScale: 2)
        let docPoints = [SIMD2<Double>(0, 0), SIMD2(100, 200), SIMD2(-30, 15.5), SIMD2(4096, 4096)]
        for d in docPoints {
            let v = vp.viewPoint(fromDocument: d)
            let back = vp.documentPoint(fromView: v)
            XCTAssertEqual(back.x, d.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, d.y, accuracy: 1e-9)
        }
    }

    func testRetinaZoomIsDevicePixelBased() {
        // 100% 줌 + 레티나(backingScale 2): document 1px = device 1px = view 0.5pt.
        let vp = Viewport(zoom: 1, panDevice: .zero, backingScale: 2)
        let v = vp.viewPoint(fromDocument: SIMD2(1, 0))
        XCTAssertEqual(v.x, 0.5, accuracy: 1e-12)
    }

    func testZoomPinsCursorDocumentPoint() {
        // 커서가 가리키던 document 지점이 줌 후에도 같은 화면 위치를 유지해야 한다.
        var vp = Viewport(zoom: 1, panDevice: SIMD2(10, 20), backingScale: 2)
        let cursorDevice = SIMD2<Double>(300, 250)
        let anchorDoc = vp.documentPoint(fromDevice: cursorDevice)

        vp.setZoom(3.5, pinningDocument: anchorDoc)

        let afterDevice = vp.devicePixel(fromDocument: anchorDoc)
        XCTAssertEqual(afterDevice.x, cursorDevice.x, accuracy: 1e-9)
        XCTAssertEqual(afterDevice.y, cursorDevice.y, accuracy: 1e-9)
    }

    func testZoomClampsToRange() {
        var vp = Viewport(zoom: 1, backingScale: 1)
        vp.setZoom(9999, pinningDocument: .zero)
        XCTAssertLessThanOrEqual(vp.zoom, 256)
        vp.setZoom(0.0001, pinningDocument: .zero)
        XCTAssertGreaterThanOrEqual(vp.zoom, 0.01)
    }

    func testFitCentersCanvas() {
        var vp = Viewport(backingScale: 2)
        vp.fit(canvasPixels: SIMD2(1000, 1000), inViewSize: SIMD2(500, 500))
        // viewDevice = 1000x1000, zoom = (1000/1000)*0.95 = 0.95, 캔버스 device = 950x950, pan = 25.
        XCTAssertEqual(vp.zoom, 0.95, accuracy: 1e-12)
        XCTAssertEqual(vp.panDevice.x, 25, accuracy: 1e-9)
        XCTAssertEqual(vp.panDevice.y, 25, accuracy: 1e-9)
    }
}

// 회전 핸들(TODO)의 핵심 수학: anchor 기준 회전 재매개화. 틀리면 회전 시 레이어가 튄다.
final class TransformTests: XCTestCase {

    private func map(_ t: DecomposedTransform, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = t.matrix * SIMD3(p.x, p.y, 1)
        return SIMD2(v.x, v.y)
    }
    private func assertClose(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ acc: Double = 1e-9) {
        XCTAssertEqual(a.x, b.x, accuracy: acc); XCTAssertEqual(a.y, b.y, accuracy: acc)
    }

    /// anchor 점은 회전/스케일과 무관하게 anchor+translation 으로 매핑된다.
    func testAnchorMapsToAnchorPlusTranslation() {
        let a = SIMD2<Double>(100, 50), tr = SIMD2<Double>(7, -3)
        for rot in [0.0, 0.3, 1.2, -2.0] {
            let t = DecomposedTransform(translation: tr, rotation: rot, scale: SIMD2(2, 3), anchor: a)
            assertClose(map(t, a), a + tr)
        }
    }

    /// 재매개화: anchor=0 변환을 anchor=center 로 바꿔도(회전·스케일 유지) 매핑이 동일.
    /// → 회전 시작 순간 레이어가 1px도 움직이지 않음을 보장.
    func testReparametrizeToCenterPreservesMapping() {
        let base = (origin: SIMD2<Double>(0, 0), size: SIMD2<Double>(200, 120))
        let center = base.origin + base.size / 2
        let t0 = DecomposedTransform(translation: SIMD2(30, -10), rotation: 0.4,
                                     scale: SIMD2(1.5, 0.8), anchor: .zero)
        let docCenter = map(t0, center)
        let t1 = DecomposedTransform(translation: docCenter - center, rotation: t0.rotation,
                                     scale: t0.scale, anchor: center)
        for p in [base.origin, SIMD2(base.size.x, 0), base.size, SIMD2(0, base.size.y), center] {
            assertClose(map(t1, p), map(t0, p))
        }
    }

    /// 재매개화 후 rotation 만 바꾸면 center 는 고정되고 코너는 center 기준 Δθ 회전한다.
    func testRotatingAboutCenterFixesCenterAndRotatesCorners() {
        let base = (origin: SIMD2<Double>(0, 0), size: SIMD2<Double>(200, 120))
        let center = base.origin + base.size / 2
        let t1 = DecomposedTransform(translation: .zero, rotation: 0, scale: .one, anchor: center)
        let docCenter = map(t1, center)
        let corner = base.origin                     // BL
        let before = map(t1, corner)

        let dθ = 0.5
        var t2 = t1; t2.rotation += dθ
        assertClose(map(t2, center), docCenter)      // center 고정

        // before 를 docCenter 기준 dθ 회전한 위치와 일치해야 함.
        let rel = before - docCenter
        let c = cos(dθ), s = sin(dθ)
        let expected = docCenter + SIMD2(c * rel.x - s * rel.y, s * rel.x + c * rel.y)
        assertClose(map(t2, corner), expected)
    }

    /// 자르기(Crop): 모든 레이어 translation -= cropOrigin 이면 콘텐츠가 정확히 -cropOrigin
    /// 평행이동(회전/anchor 무관). 크롭 영역 좌하단이 새 캔버스 원점(0,0)이 됨을 보장.
    func testCropTranslationShiftsAllPointsByMinusOrigin() {
        let crop = SIMD2<Double>(120, 80)
        let t0 = DecomposedTransform(translation: SIMD2(50, 30), rotation: 0.7,
                                     scale: SIMD2(1.3, 0.9), anchor: SIMD2(40, 25))
        var t1 = t0; t1.translation -= crop
        for p in [SIMD2<Double>(0, 0), SIMD2(200, 0), SIMD2(60, 140), SIMD2(40, 25)] {
            assertClose(map(t1, p), map(t0, p) - crop)
        }
    }
}

// 톤 커브 샘플링(단조 3차) — LUT 생성의 정확성. 틀리면 커브 보정이 어긋난다.
final class ToneCurveTests: XCTestCase {
    func testIdentityCurveSamplesToInput() {
        let ys = ToneCurve.identity.sample(count: 11)
        for (i, y) in ys.enumerated() {
            XCTAssertEqual(y, Float(i) / 10, accuracy: 1e-5)   // (0,0)-(1,1) → y=x
        }
    }

    func testMonotoneNoOvershoot() {
        // 가파른 S 커브여도 단조 증가 + 0…1 범위 유지(오버슈트 없음).
        let c = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.3, 0.05), SIMD2(0.7, 0.95), SIMD2(1, 1)])
        let ys = c.sample(count: 256)
        for i in 1..<ys.count {
            XCTAssertGreaterThanOrEqual(ys[i], ys[i - 1] - 1e-6)   // 단조
            XCTAssertGreaterThanOrEqual(ys[i], 0); XCTAssertLessThanOrEqual(ys[i], 1)
        }
    }

    func testPassesThroughControlPoints() {
        let c = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.8), SIMD2(1, 1)])
        let ys = c.sample(count: 101)
        XCTAssertEqual(ys[0], 0, accuracy: 1e-4)
        XCTAssertEqual(ys[50], 0.8, accuracy: 1e-3)   // x=0.5 → y=0.8
        XCTAssertEqual(ys[100], 1, accuracy: 1e-4)
    }

    func testRaisedMidtoneBrightens() {
        let c = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.7), SIMD2(1, 1)])
        let ys = c.sample(count: 101)
        XCTAssertGreaterThan(ys[50], 0.5)   // 중간톤이 입력보다 밝아짐
    }
}

// 타일 인터페이스가 호출부에서 동작하는지(설계 §5.3).
final class TileTests: XCTestCase {
    func testTilesCoveringRect() {
        let store = GridTileStore(canvasPixels: SIMD2(1000, 1000), tileSize: 256)
        XCTAssertEqual(store.tilesPerAxis, SIMD2(4, 4))   // ceil(1000/256)=4

        let covering = store.tiles(coveringRect: PixelRect(origin: SIMD2(200, 200), size: SIMD2(120, 120)))
        // x: 200..319 → 타일 0,1 ; y 동일 → 4 타일.
        XCTAssertEqual(Set(covering), Set([
            TileIndex(x: 0, y: 0), TileIndex(x: 1, y: 0),
            TileIndex(x: 0, y: 1), TileIndex(x: 1, y: 1),
        ]))
    }

    func testHasTileBounds() {
        let store = GridTileStore(canvasPixels: SIMD2(300, 300), tileSize: 256)
        XCTAssertTrue(store.hasTile(at: TileIndex(x: 1, y: 1)))
        XCTAssertFalse(store.hasTile(at: TileIndex(x: 2, y: 0)))
    }
}
