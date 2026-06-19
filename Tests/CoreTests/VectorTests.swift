import XCTest
import simd
@testable import Core

final class VectorTests: XCTestCase {

    func testShapeBoundingBoxNormalizes() {
        // p0가 p1보다 우상단이어도 정규화된 bbox.
        let s = VectorShape(kind: .rectangle, p0: SIMD2(100, 100), p1: SIMD2(40, 30),
                            fill: RGBA8(0, 0, 0), stroke: nil)
        let b = s.boundingBox
        XCTAssertEqual(b.origin.x, 40 - 1, accuracy: 1e-9)   // pad=1 (stroke 없음)
        XCTAssertEqual(b.origin.y, 30 - 1, accuracy: 1e-9)
        XCTAssertEqual(b.size.x, 60 + 2, accuracy: 1e-9)
        XCTAssertEqual(b.size.y, 70 + 2, accuracy: 1e-9)
    }

    func testStrokePadsBoundingBox() {
        let s = VectorShape(kind: .line, p0: SIMD2(0, 0), p1: SIMD2(10, 0),
                            fill: nil, stroke: VectorStroke(color: RGBA8(0, 0, 0), width: 8))
        let b = s.boundingBox
        XCTAssertEqual(b.origin.y, -5, accuracy: 1e-9)         // pad = 8/2 + 1 = 5
        XCTAssertEqual(b.size.y, 10, accuracy: 1e-9)
    }

    func testUnionBounds() {
        let a = VectorShape(kind: .rectangle, p0: SIMD2(0, 0), p1: SIMD2(10, 10), fill: RGBA8(0, 0, 0), stroke: nil)
        let b = VectorShape(kind: .oval, p0: SIMD2(20, 20), p1: SIMD2(30, 30), fill: RGBA8(0, 0, 0), stroke: nil)
        let node = VectorNode(common: CommonLayerProps(name: "v"), shapes: [a, b])
        let u = node.unionBounds!
        XCTAssertEqual(u.origin.x, -1, accuracy: 1e-9)
        XCTAssertEqual(u.origin.x + u.size.x, 31, accuracy: 1e-9)
    }

    func testEmptyNodeHasNoBounds() {
        XCTAssertNil(VectorNode(common: CommonLayerProps(name: "v"), shapes: []).unionBounds)
    }
}
