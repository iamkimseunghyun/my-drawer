import Foundation
import simd

// MARK: - 값 모델 (Codable · Sendable · 스냅샷 가능)
// 설계 §3: GPU 리소스를 담지 않는 순수 데이터. 픽셀은 핸들(UUID)로만 참조한다.

public enum WorkingColorSpace: String, Codable, Sendable {
    case linearP3   // 설계 §4.1: 모든 합성/블렌드/보정 수학은 linear Display-P3에서
}

public struct CanvasSettings: Codable, Sendable, Equatable {
    public var pixelSize: SIMD2<Int>          // device pixels 기준
    public var dpi: Double                     // 메타데이터 전용(화면 렌더에 영향 없음)
    public var workingColorSpace: WorkingColorSpace

    public init(pixelSize: SIMD2<Int>, dpi: Double = 72, workingColorSpace: WorkingColorSpace = .linearP3) {
        self.pixelSize = pixelSize
        self.dpi = dpi
        self.workingColorSpace = workingColorSpace
    }
}

// 픽셀 데이터는 ResourceStore가 소유. 모델에는 핸들만 직렬화된다.
public struct TileStoreHandle: Codable, Sendable, Hashable {
    public var id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, multiply, screen, overlay, softLight   // 설계 §1.3: MVP 5종
}

public enum Adjustment: Codable, Sendable, Equatable {
    case brightness(Float)
    case contrast(Float)
    case saturation(Float)
    case hue(Float)
    case exposure(Float)
    case levels(Levels)
    case curve(ToneCurve)
    case blur(Float)        // 0…1 → 반경
    case sharpen(Float)     // 0…1 → 강도

    /// 단일 강도 값. 레벨/커브는 단일 값이 아니라 0. 블러/샤픈은 0…1 반경/강도.
    public var value: Float {
        switch self {
        case .brightness(let v), .contrast(let v), .saturation(let v),
             .hue(let v), .exposure(let v), .blur(let v), .sharpen(let v): return v
        case .levels, .curve: return 0
        }
    }
    public func withValue(_ v: Float) -> Adjustment {
        switch self {
        case .brightness: return .brightness(v)
        case .contrast: return .contrast(v)
        case .saturation: return .saturation(v)
        case .hue: return .hue(v)
        case .exposure: return .exposure(v)
        case .blur: return .blur(v)
        case .sharpen: return .sharpen(v)
        case .levels, .curve: return self
        }
    }
    /// 패널의 −1…1 강도 슬라이더로 조절 가능한가(레벨/커브/블러/샤픈은 인스펙터 전용 UI).
    public var isSimpleSlider: Bool {
        switch self {
        case .levels, .curve, .blur, .sharpen: return false
        default: return true
        }
    }
    /// 0…1 단일 슬라이더(반경/강도)를 인스펙터에 쓰는 조정인가.
    public var isRadiusAdjust: Bool {
        switch self { case .blur, .sharpen: return true; default: return false }
    }
    public var displayName: String {
        switch self {
        case .brightness: return "밝기"
        case .contrast: return "대비"
        case .saturation: return "채도"
        case .hue: return "색조"
        case .exposure: return "노출"
        case .levels: return "레벨"
        case .curve: return "커브"
        case .blur: return "블러"
        case .sharpen: return "샤픈"
        }
    }
}

/// 레벨 보정: 입력 범위(블랙/화이트/감마)를 출력 범위로 매핑. 모두 0…1(감마 제외).
public struct Levels: Codable, Sendable, Equatable {
    public var inBlack: Float
    public var inWhite: Float
    public var gamma: Float          // 중간톤. 1 = 중립. >1 밝게, <1 어둡게.
    public var outBlack: Float
    public var outWhite: Float
    public init(inBlack: Float = 0, inWhite: Float = 1, gamma: Float = 1,
                outBlack: Float = 0, outWhite: Float = 1) {
        self.inBlack = inBlack; self.inWhite = inWhite; self.gamma = gamma
        self.outBlack = outBlack; self.outWhite = outWhite
    }
    public static let identity = Levels()
}

/// 톤 커브: 0…1 제어점들(x 오름차순). 단조 3차(Fritsch–Carlson)로 보간 → 오버슈트 없음.
public struct ToneCurve: Codable, Sendable, Equatable {
    public var points: [SIMD2<Float>]
    public init(points: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 1)]) { self.points = points }
    public static let identity = ToneCurve()

    /// 커브를 [0,1]에서 count개로 균일 샘플(각 0…1). LUT(CIColorCurves) 생성용.
    public func sample(count: Int) -> [Float] {
        let pts = points.sorted { $0.x < $1.x }
        guard pts.count >= 2, count >= 2 else {
            return [Float](repeating: pts.first?.y ?? 0, count: max(1, count))
        }
        let n = pts.count
        // 구간 기울기(secant).
        var delta = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let h = pts[i + 1].x - pts[i].x
            delta[i] = h > 1e-6 ? (pts[i + 1].y - pts[i].y) / h : 0
        }
        // 접선(tangent) + 단조성 보정.
        var m = [Float](repeating: 0, count: n)
        m[0] = delta[0]; m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) { m[i] = (delta[i - 1] + delta[i]) / 2 }
        for i in 0..<(n - 1) {
            if delta[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * delta[i]; m[i + 1] = t * b * delta[i] }
        }
        var out = [Float](repeating: 0, count: count)
        var seg = 0
        for k in 0..<count {
            let x = Float(k) / Float(count - 1)
            if x <= pts[0].x { out[k] = pts[0].y.clamped01; continue }
            if x >= pts[n - 1].x { out[k] = pts[n - 1].y.clamped01; continue }
            while seg < n - 2 && x > pts[seg + 1].x { seg += 1 }
            while seg > 0 && x < pts[seg].x { seg -= 1 }
            let h = pts[seg + 1].x - pts[seg].x
            let t = h > 1e-6 ? (x - pts[seg].x) / h : 0
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
            let y = h00 * pts[seg].y + h10 * h * m[seg] + h01 * pts[seg + 1].y + h11 * h * m[seg + 1]
            out[k] = y.clamped01
        }
        return out
    }
}

private extension Float {
    var clamped01: Float { Swift.max(0, Swift.min(1, self)) }
}

public struct CommonLayerProps: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var transform: DecomposedTransform   // 설계 §3.3: TRS 분해 저장, 행렬은 렌더 시 합성
    public var opacity: Float
    public var blendMode: BlendMode
    public var isVisible: Bool
    public var isLocked: Bool
    public var maskHandle: TileStoreHandle?      // 레이어 마스크(캔버스 크기 그레이스케일 paint canvas). nil=마스크 없음.

    public init(id: UUID = UUID(), name: String, transform: DecomposedTransform = .identity,
                opacity: Float = 1, blendMode: BlendMode = .normal,
                isVisible: Bool = true, isLocked: Bool = false, maskHandle: TileStoreHandle? = nil) {
        self.id = id; self.name = name; self.transform = transform
        self.opacity = opacity; self.blendMode = blendMode
        self.isVisible = isVisible; self.isLocked = isLocked; self.maskHandle = maskHandle
    }
}

public struct RasterNode: Codable, Sendable, Equatable {
    public var common: CommonLayerProps
    public var pixels: TileStoreHandle
    public init(common: CommonLayerProps, pixels: TileStoreHandle) {
        self.common = common; self.pixels = pixels
    }
}

public struct AdjustmentNode: Codable, Sendable, Equatable {
    public var common: CommonLayerProps
    public var adjustment: Adjustment
    public init(common: CommonLayerProps, adjustment: Adjustment) {
        self.common = common; self.adjustment = adjustment
    }
}

public struct GroupNode: Codable, Sendable, Equatable {
    public var common: CommonLayerProps
    public var children: [LayerNode]            // 설계 §5.1: v1 그룹은 isolation 없는 단순 묶음
    public init(common: CommonLayerProps, children: [LayerNode]) {
        self.common = common; self.children = children
    }
}

// 폴리모픽 레이어를 enum으로 → Codable 자동 합성. 미래 case 추가가 곧 벡터 확장 슬롯(설계 §3.5).
public enum LayerNode: Codable, Sendable, Equatable, Identifiable {
    case raster(RasterNode)
    case adjustment(AdjustmentNode)
    case group(GroupNode)
    case vector(VectorNode)      // V1a: 가벼운 벡터(도형)
    case text(TextNode)          // V1b-3: 텍스트

    public var id: UUID { common.id }

    public var common: CommonLayerProps {
        switch self {
        case .raster(let n): return n.common
        case .adjustment(let n): return n.common
        case .group(let n): return n.common
        case .vector(let n): return n.common
        case .text(let n): return n.common
        }
    }
}

public struct Document: Codable, Sendable, Equatable {
    public var canvas: CanvasSettings
    public var layers: [LayerNode]              // z-order: 뒤(0) → 앞
    public init(canvas: CanvasSettings, layers: [LayerNode] = []) {
        self.canvas = canvas; self.layers = layers
    }
}

extension LayerNode {
    /// 공통 속성만 교체한 새 노드 반환(값 의미 유지). 편집 헬퍼용.
    public func withCommon(_ c: CommonLayerProps) -> LayerNode {
        switch self {
        case .raster(var n): n.common = c; return .raster(n)
        case .adjustment(var n): n.common = c; return .adjustment(n)
        case .group(var n): n.common = c; return .group(n)
        case .vector(var n): n.common = c; return .vector(n)
        case .text(var n): n.common = c; return .text(n)
        }
    }

    /// 이 노드(및 하위 그룹)가 참조하는 모든 픽셀 핸들(마스크 포함).
    public var referencedHandles: Set<TileStoreHandle> {
        var out: Set<TileStoreHandle> = []
        if let m = common.maskHandle { out.insert(m) }
        switch self {
        case .raster(let n): out.insert(n.pixels)
        case .group(let n): for c in n.children { out.formUnion(c.referencedHandles) }
        case .adjustment, .vector, .text: break
        }
        return out
    }
}
