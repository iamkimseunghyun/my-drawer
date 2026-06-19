import CoreGraphics
import Core

// MARK: - 색 관리 (설계 §4) — M0에서 못 박는다. 틀리면 그 전에 만든 모든 블렌드/보정이 틀린 채 쌓인다.

public enum ColorSpaces {
    /// 작업 색공간: linear Display-P3. 모든 합성/블렌드/필터 수학이 여기서 일어난다(§4.1).
    public static let workingLinearP3: CGColorSpace =
        CGColorSpace(name: CGColorSpace.linearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// 출력(디스플레이) — 실제로는 NSScreen 프로파일로 변환해야 하나, 기준 P3를 둔다(§4.1.6).
    public static let displayP3: CGColorSpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// 일반 입력 기준.
    public static let sRGB: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public static func cgColorSpace(for w: WorkingColorSpace) -> CGColorSpace {
        switch w {
        case .linearP3: return workingLinearP3
        }
    }
}

// MARK: - 왕복(round-trip) 검증용 헬퍼
// 설계 §4 / §9 M0: sRGB → linearP3(작업) → sRGB 왕복이 색을 보존함을 증명한다.

public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: CGFloat
    public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public func maxComponentDelta(to other: RGBA) -> CGFloat {
        max(abs(r - other.r), abs(g - other.g), abs(b - other.b), abs(a - other.a))
    }
}

public enum ColorConvert {
    /// `from` 색공간의 색을 `to` 색공간으로 변환(CPU, 결정적). ColorSync 사용.
    public static func convert(_ c: RGBA, from: CGColorSpace, to: CGColorSpace) -> RGBA? {
        guard let src = CGColor(colorSpace: from, components: [c.r, c.g, c.b, c.a]) else { return nil }
        guard let dst = src.converted(to: to, intent: .relativeColorimetric, options: nil),
              let comps = dst.components, comps.count >= 3 else { return nil }
        let a = comps.count >= 4 ? comps[3] : 1
        return RGBA(comps[0], comps[1], comps[2], a)
    }

    /// sRGB → linear P3 작업공간 → sRGB 왕복. 반환값은 입력과 같아야 한다(허용오차 내).
    public static func roundTripSRGBThroughWorking(_ c: RGBA) -> RGBA? {
        guard let working = convert(c, from: ColorSpaces.sRGB, to: ColorSpaces.workingLinearP3) else { return nil }
        return convert(working, from: ColorSpaces.workingLinearP3, to: ColorSpaces.sRGB)
    }
}
