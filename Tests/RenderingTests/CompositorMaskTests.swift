import XCTest
import CoreImage
import Core
@testable import Rendering

/// 레이어 마스크 합성 (TODO #10). 흰=보임·검정=숨김·회색=부분. 조정 마스킹도 함께 검증.
final class CompositorMaskTests: XCTestCase {
    let ctx = CIContext(options: nil)
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func solid(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    private func sample(_ img: CIImage) -> (r: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: sRGB)
        return (Int(px[0]), Int(px[3]))
    }

    private func maskedRaster(_ maskGray: Double) -> (r: Int, a: Int) {
        let layerH = TileStoreHandle(), maskH = TileStoreHandle()
        var common = CommonLayerProps(name: "L"); common.maskHandle = maskH
        let node = LayerNode.raster(RasterNode(common: common, pixels: layerH))
        let comp = Compositor(sources: [layerH: solid(1, 0, 0, 1), maskH: solid(maskGray, maskGray, maskGray, 1)])
        return sample(comp.render([node], below: CIImage.empty()))
    }

    func testWhiteMaskReveals() {
        let s = maskedRaster(1)
        XCTAssertGreaterThan(s.a, 250, "흰 마스크 = 불투명")
        XCTAssertGreaterThan(s.r, 250, "빨강 보임")
    }
    func testBlackMaskHides() {
        XCTAssertLessThan(maskedRaster(0).a, 5, "검정 마스크 = 숨김(알파 0)")
    }
    func testGrayMaskPartial() {
        let a = maskedRaster(0.5).a
        XCTAssertTrue(a > 5 && a < 250, "회색 마스크 = 부분 투명(\(a))")
    }

    func testAdjustmentMaskLimitsRegion() {
        // 밝기 +0.5 조정 레이어 + 마스크. 검정=보정 없음, 흰=보정 적용.
        let baseH = TileStoreHandle(), maskH = TileStoreHandle()
        let base = LayerNode.raster(RasterNode(common: CommonLayerProps(name: "B"), pixels: baseH))
        func adjLayer(_ mask: Double) -> (r: Int, a: Int) {
            var c = CommonLayerProps(name: "A"); c.maskHandle = maskH
            let adj = LayerNode.adjustment(AdjustmentNode(common: c, adjustment: .brightness(0.5)))
            let comp = Compositor(sources: [baseH: solid(0.4, 0.4, 0.4, 1),
                                            maskH: solid(mask, mask, mask, 1)])
            return sample(comp.render([base, adj], below: CIImage.empty()))
        }
        let black = adjLayer(0).r, white = adjLayer(1).r
        XCTAssertGreaterThan(white, black + 20, "흰 마스크에서만 밝아짐(black=\(black) white=\(white))")
    }
}
