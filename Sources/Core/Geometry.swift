import Foundation
import simd

// MARK: - 분해 변환 (설계 §3.3)
// 원시 행렬 대신 TRS로 저장 → 직렬화·히트테스트·핸들 UI·누적오차에 유리. 행렬은 렌더 시 합성.
public struct DecomposedTransform: Codable, Sendable, Equatable {
    public var translation: SIMD2<Double>
    public var rotation: Double                 // radians
    public var scale: SIMD2<Double>
    public var anchor: SIMD2<Double>            // 회전/스케일 기준점 (document px)

    public init(translation: SIMD2<Double> = .zero, rotation: Double = 0,
                scale: SIMD2<Double> = .one, anchor: SIMD2<Double> = .zero) {
        self.translation = translation; self.rotation = rotation
        self.scale = scale; self.anchor = anchor
    }

    public static let identity = DecomposedTransform()

    /// document space affine 행렬 (열 우선 simd). anchor 기준 스케일·회전 후 translate.
    public var matrix: simd_double3x3 {
        let c = cos(rotation), s = sin(rotation)
        // T(translation) * T(anchor) * R * S * T(-anchor)
        let scaleRot = simd_double3x3(
            SIMD3(c * scale.x,  s * scale.x, 0),
            SIMD3(-s * scale.y, c * scale.y, 0),
            SIMD3(0,            0,           1)
        )
        let toOrigin = Self.translationMatrix(-anchor)
        let back = Self.translationMatrix(anchor + translation)
        return back * (scaleRot * toOrigin)
    }

    private static func translationMatrix(_ t: SIMD2<Double>) -> simd_double3x3 {
        simd_double3x3(
            SIMD3(1, 0, 0),
            SIMD3(0, 1, 0),
            SIMD3(t.x, t.y, 1)
        )
    }
}

// MARK: - 좌표계 (설계 §5.2) — M0에서 확정. 틀리면 전 도구 재작성.
//
// 세 공간:
//   view space   : AppKit 포인트. 원점 좌하단(AppKit 기본 = CoreImage와 동일 → Y 플립 불필요).
//   device space : 물리 픽셀. devicePixel = viewPoint * backingScale.
//   document space: 캔버스 픽셀. 줌은 "document px 당 device px"로 정의(레티나 정확).
//
//   devicePixel = documentPoint * zoom + panDevice
//   viewPoint   = devicePixel / backingScale
public struct Viewport: Sendable, Equatable {
    public var zoom: Double                      // 1.0 == 100% (1 document px : 1 device px)
    public var panDevice: SIMD2<Double>          // device pixel 단위 평행이동
    public var backingScale: Double              // NSScreen.backingScaleFactor (레티나 = 2)

    public init(zoom: Double = 1, panDevice: SIMD2<Double> = .zero, backingScale: Double = 2) {
        self.zoom = zoom; self.panDevice = panDevice; self.backingScale = backingScale
    }

    // device ↔ document
    public func devicePixel(fromDocument d: SIMD2<Double>) -> SIMD2<Double> {
        d * zoom + panDevice
    }
    public func documentPoint(fromDevice px: SIMD2<Double>) -> SIMD2<Double> {
        (px - panDevice) / zoom
    }

    // view ↔ document (도구가 받는 좌표는 항상 document space)
    public func documentPoint(fromView v: SIMD2<Double>) -> SIMD2<Double> {
        documentPoint(fromDevice: v * backingScale)
    }
    public func viewPoint(fromDocument d: SIMD2<Double>) -> SIMD2<Double> {
        devicePixel(fromDocument: d) / backingScale
    }

    /// 특정 document 지점을 고정한 채 줌 변경 (커서 기준 줌). 설계 §5.2 device-pixel 줌.
    public mutating func setZoom(_ newZoom: Double, pinningDocument anchor: SIMD2<Double>) {
        let before = devicePixel(fromDocument: anchor)
        zoom = max(0.01, min(newZoom, 256))
        let after = devicePixel(fromDocument: anchor)
        panDevice += before - after
    }

    /// 캔버스를 뷰에 맞춰 중앙 정렬 (fit). viewSize는 포인트 단위.
    public mutating func fit(canvasPixels: SIMD2<Int>, inViewSize viewSize: SIMD2<Double>) {
        let viewDevice = viewSize * backingScale
        let cw = Double(canvasPixels.x), ch = Double(canvasPixels.y)
        guard cw > 0, ch > 0 else { return }
        zoom = min(viewDevice.x / cw, viewDevice.y / ch) * 0.95
        let canvasDevice = SIMD2(cw, ch) * zoom
        panDevice = (viewDevice - canvasDevice) / 2
    }
}
