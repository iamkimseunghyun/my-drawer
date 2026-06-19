import XCTest
@testable import Core

// M3 측정: 마우스무브당 비용(스탬프 + 페인트 레이어 CGImage 재생성)을 큰 캔버스로 잰다.
// 무작정 Metal로 최적화하기 전에 실제 병목을 확인(설계 measure-first).
final class PaintPerfTests: XCTestCase {

    // 한 스트로크 구간(드래그 한 스텝 = dab 여러 개)의 스탬프 비용.
    func testStampThroughput() {
        let c = PaintCanvas(width: 2048, height: 2048)
        measure {
            c.beginStroke()
            for i in 0..<50 { c.stampDab(cx: Double(20 + i * 30), cy: 1024, radius: 30,
                                         hardness: 0.8, color: .red, flow: 1, erase: false) }
            _ = c.endStroke()
        }
    }

    // 마우스무브마다 recompose가 호출하는 makeCGImage 비용(2048² 풀캔버스).
    func testMakeCGImageCost() {
        let c = PaintCanvas(width: 2048, height: 2048)
        c.beginStroke()
        c.stampDab(cx: 1024, cy: 1024, radius: 200, hardness: 1, color: .red, flow: 1, erase: false)
        _ = c.endStroke()
        measure { _ = c.makeCGImage() }
    }

    // 더 큰 캔버스(600 DPI 로고 문서급, 4000²).
    func testMakeCGImageCostLarge() {
        let c = PaintCanvas(width: 4000, height: 4000)
        c.beginStroke()
        c.stampDab(cx: 2000, cy: 2000, radius: 300, hardness: 1, color: .red, flow: 1, erase: false)
        _ = c.endStroke()
        measure { _ = c.makeCGImage() }
    }
}
