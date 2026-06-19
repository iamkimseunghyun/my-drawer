import Foundation
import simd

// MARK: - 벡터 도형 (설계 §3.5 확장 슬롯, V1a)
// 가벼운 벡터: 사각형·원·선. 좌표는 document space(좌하단). 펜/노드편집은 추후.

public enum VectorKind: String, Codable, Sendable, Equatable {
    case rectangle, oval, line

    public var displayName: String {
        switch self {
        case .rectangle: return "사각형"
        case .oval: return "원"
        case .line: return "선"
        }
    }
}

public struct VectorStroke: Codable, Sendable, Equatable {
    public var color: RGBA8
    public var width: Double
    public init(color: RGBA8, width: Double) { self.color = color; self.width = width }
}

public struct VectorShape: Codable, Sendable, Equatable {
    public var kind: VectorKind
    public var p0: SIMD2<Double>          // 드래그 시작
    public var p1: SIMD2<Double>          // 드래그 끝
    public var fill: RGBA8?               // nil = 채움 없음(선)
    public var stroke: VectorStroke?

    public init(kind: VectorKind, p0: SIMD2<Double>, p1: SIMD2<Double>,
                fill: RGBA8?, stroke: VectorStroke?) {
        self.kind = kind; self.p0 = p0; self.p1 = p1; self.fill = fill; self.stroke = stroke
    }

    /// 정규화 bbox(stroke 패딩 포함, document 좌표).
    public var boundingBox: (origin: SIMD2<Double>, size: SIMD2<Double>) {
        let minX = min(p0.x, p1.x), minY = min(p0.y, p1.y)
        let w = abs(p1.x - p0.x), h = abs(p1.y - p0.y)
        let pad = (stroke?.width ?? 0) / 2 + 1
        return (SIMD2(minX - pad, minY - pad), SIMD2(w + pad * 2, h + pad * 2))
    }
}

public struct VectorNode: Codable, Sendable, Equatable {
    public var common: CommonLayerProps
    public var shapes: [VectorShape]
    public init(common: CommonLayerProps, shapes: [VectorShape]) {
        self.common = common; self.shapes = shapes
    }

    /// 모든 도형을 덮는 합집합 bbox.
    public var unionBounds: (origin: SIMD2<Double>, size: SIMD2<Double>)? {
        guard !shapes.isEmpty else { return nil }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for s in shapes {
            let b = s.boundingBox
            minX = min(minX, b.origin.x); minY = min(minY, b.origin.y)
            maxX = max(maxX, b.origin.x + b.size.x); maxY = max(maxY, b.origin.y + b.size.y)
        }
        return (SIMD2(minX, minY), SIMD2(maxX - minX, maxY - minY))
    }
}
