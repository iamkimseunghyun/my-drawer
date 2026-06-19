import Foundation
import simd

// MARK: - 텍스트 레이어 (V1b-3)
// 단일 라인 텍스트. 렌더링은 Rendering 모듈의 Core Text 래스터화로(측정도 거기서).

public struct TextNode: Codable, Sendable, Equatable {
    public var common: CommonLayerProps
    public var text: String
    public var fontSize: Double
    public var fontName: String?          // nil = 시스템 폰트
    public var color: RGBA8
    public var origin: SIMD2<Double>      // 텍스트 박스 좌하단(document 좌표)

    public init(common: CommonLayerProps, text: String, fontSize: Double = 48,
                fontName: String? = nil, color: RGBA8 = .red, origin: SIMD2<Double>) {
        self.common = common; self.text = text; self.fontSize = fontSize
        self.fontName = fontName; self.color = color; self.origin = origin
    }
}
