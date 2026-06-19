import XCTest
import CoreGraphics
@testable import ColorPipeline

// 설계 §9 M0의 핵심 증명: sRGB → linear P3 작업공간 → sRGB 왕복이 색을 보존한다.
// 이게 깨지면 이후 만드는 모든 블렌드/보정이 틀린 채 쌓인다(설계 §4 경고).
final class ColorRoundTripTests: XCTestCase {

    private let tolerance: CGFloat = 1.0 / 255.0   // 8-bit 1단계 이내

    func testPrimariesAndGraysRoundTrip() throws {
        let samples: [RGBA] = [
            RGBA(0, 0, 0), RGBA(1, 1, 1), RGBA(0.5, 0.5, 0.5),
            RGBA(1, 0, 0), RGBA(0, 1, 0), RGBA(0, 0, 1),
            RGBA(0.2, 0.4, 0.8), RGBA(0.9, 0.7, 0.1),
        ]
        for c in samples {
            let rt = try XCTUnwrap(ColorConvert.roundTripSRGBThroughWorking(c),
                                   "변환 실패: \(c)")
            let delta = c.maxComponentDelta(to: rt)
            XCTAssertLessThanOrEqual(delta, tolerance,
                "왕복 색 오차 초과: \(c) → \(rt), Δ=\(delta)")
        }
    }

    func testWorkingSpaceIsLinearP3() {
        // 작업 색공간이 실제로 linear Display-P3로 잡혔는지(폴백 DeviceRGB가 아닌지) 확인.
        XCTAssertEqual(ColorSpaces.workingLinearP3.name, CGColorSpace.linearDisplayP3)
        XCTAssertEqual(ColorSpaces.displayP3.name, CGColorSpace.displayP3)
        XCTAssertEqual(ColorSpaces.sRGB.name, CGColorSpace.sRGB)
    }

    func testAlphaPreserved() throws {
        let c = RGBA(0.3, 0.6, 0.9, 0.5)
        let rt = try XCTUnwrap(ColorConvert.roundTripSRGBThroughWorking(c))
        XCTAssertEqual(rt.a, c.a, accuracy: tolerance)
    }
}
