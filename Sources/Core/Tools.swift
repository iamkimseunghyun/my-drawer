import Foundation
import simd

// MARK: - 도구 시스템 (설계 §6)

public struct RGBA8: Equatable, Sendable, Codable {
    public var r, g, b, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let red = RGBA8(220, 50, 50)
}

public enum ToolKind: Sendable, Equatable {
    case pan, brush, eraser, eyedropper, fill, shape, move, text, crop, gradient, objectSelect
}

public struct BrushSettings: Sendable, Equatable {
    public var radius: Double
    public var hardness: Double     // 0(soft) … 1(hard edge)
    public var flow: Double         // 0…1
    public var spacing: Double      // dab 간격 = radius × spacing (0.05 촘촘 … 1 성김)
    public var color: RGBA8
    public init(radius: Double = 20, hardness: Double = 0.8, flow: Double = 1,
                spacing: Double = 0.25, color: RGBA8 = .red) {
        self.radius = radius; self.hardness = hardness; self.flow = flow
        self.spacing = spacing; self.color = color
    }
}

/// 도구가 받는 입력 (설계 §6: bare point가 아니라 압력/틸트/속도까지). M2a는 point+pressure만 사용.
public struct ToolEvent: Sendable {
    public var documentPoint: SIMD2<Double>
    public var pressure: Float
    public var timestamp: TimeInterval
    public init(documentPoint: SIMD2<Double>, pressure: Float = 1, timestamp: TimeInterval = 0) {
        self.documentPoint = documentPoint; self.pressure = pressure; self.timestamp = timestamp
    }
}

/// 스트로크 경로를 일정 간격 dab 중심으로 샘플 (설계 §5.3).
public enum StrokeSampler {
    public static func dabCenters(from a: SIMD2<Double>, to b: SIMD2<Double>, spacing: Double) -> [SIMD2<Double>] {
        let d = b - a
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        if len == 0 { return [] }
        let s = max(0.5, spacing)
        let n = max(1, Int(len / s))
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        for k in 1...n {
            let t = min(1.0, Double(k) * s / len)
            out.append(a + d * t)
        }
        return out
    }
}
