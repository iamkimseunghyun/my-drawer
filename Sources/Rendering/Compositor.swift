import CoreImage
import Core

// MARK: - 합성 (설계 §5) — Core Image 그래프 + 재귀 평가기.
// 평면 back-to-front 루프(v1의 결함)가 아니라 트리를 재귀적으로 CIImage로 환산한다.
// 조정 레이어의 "아래를 읽어 다시 쓰기"와 그룹 버퍼를 자연스럽게 표현한다.
//
// 확장 슬롯(§3.5): 노드를 CIImage로 바꾸는 인터페이스라, v2에서 .vector/.text case를
// "패스 → CG 래스터화 → CIImage"로 같은 자리에 꽂으면 끝난다.

public struct Compositor {
    /// 래스터 노드의 픽셀 소스. 실제로는 ResourceStore가 타일 → CIImage로 제공한다(M0는 주입).
    public var sources: [TileStoreHandle: CIImage]

    public init(sources: [TileStoreHandle: CIImage] = [:]) {
        self.sources = sources
    }

    /// 레이어 배열을 `below` 위에 합성. 뒤(index 0) → 앞 순서.
    public func render(_ nodes: [LayerNode], below: CIImage) -> CIImage {
        var acc = below
        for node in nodes {
            let c = node.common
            guard c.isVisible else { continue }
            switch node {
            case .raster(let n):
                guard let src = sources[n.pixels] else { continue }
                let placed = applyMask(src.transformed(by: affine(c.transform)), c)
                acc = blend(c.blendMode, opacity: c.opacity, placed, over: acc)

            case .adjustment(let n):
                // 누적 결과를 입력으로 → CI 필터 그래프가 read-modify-write를 흡수(설계 §5.1).
                let adjusted = applyAdjustment(n.adjustment, to: acc, opacity: c.opacity)
                acc = mixByMask(adjusted, over: acc, c)   // 마스크 있으면 보정 영역 제한

            case .group(let n):
                // v1 그룹: isolation 없는 단순 묶음. 자식을 투명 위에 합성 후 결과를 블렌드.
                let sub = render(n.children, below: CIImage.empty())
                let placed = applyMask(sub.transformed(by: affine(c.transform)), c)
                acc = blend(c.blendMode, opacity: c.opacity, placed, over: acc)

            case .vector(let n):
                guard let img = VectorRasterizer.rasterize(n) else { continue }
                let placed = applyMask(img.transformed(by: affine(c.transform)), c)
                acc = blend(c.blendMode, opacity: c.opacity, placed, over: acc)

            case .text(let n):
                guard let img = TextRasterizer.rasterize(n) else { continue }
                let placed = applyMask(img.transformed(by: affine(c.transform)), c)
                acc = blend(c.blendMode, opacity: c.opacity, placed, over: acc)
            }
        }
        return acc
    }

    // MARK: 레이어 마스크 — 캔버스 정렬 그레이스케일(흰=보임). 커버리지 = 마스크 R채널.
    /// 마스크 R채널을 전 채널로 복제한 커버리지(cov,cov,cov,cov). 불투명 마스크라 R=커버리지.
    private func coverage(_ maskHandle: TileStoreHandle?) -> CIImage? {
        guard let mh = maskHandle, let mask = sources[mh] else { return nil }
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
    }
    /// 콘텐츠 레이어: premultiplied 픽셀에 커버리지를 곱해 알파 제한.
    private func applyMask(_ image: CIImage, _ common: CommonLayerProps) -> CIImage {
        guard let cov = coverage(common.maskHandle) else { return image }
        return image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: cov])
    }
    /// 조정 레이어: 마스크 영역에서만 보정 적용 → 커버리지(알파=cov)로 adjusted↔base 보간.
    private func mixByMask(_ adjusted: CIImage, over base: CIImage, _ common: CommonLayerProps) -> CIImage {
        guard let cov = coverage(common.maskHandle) else { return adjusted }
        return adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: cov,
        ])
    }

    // MARK: 블렌드 (설계 §4.1.4: 비분리 모드 수학을 직접 짜지 않고 CI 내장 필터에 맡긴다)
    public func blend(_ mode: BlendMode, opacity: Float, _ src: CIImage, over dst: CIImage) -> CIImage {
        let s = opacity < 1 ? src.applyingAlpha(opacity) : src
        let filterName: String
        switch mode {
        case .normal:    filterName = "CISourceOverCompositing"
        case .multiply:  filterName = "CIMultiplyBlendMode"
        case .screen:    filterName = "CIScreenBlendMode"
        case .overlay:   filterName = "CIOverlayBlendMode"
        case .softLight: filterName = "CISoftLightBlendMode"
        }
        guard let f = CIFilter(name: filterName) else { return s.composited(over: dst) }
        f.setValue(s, forKey: kCIInputImageKey)
        f.setValue(dst, forKey: kCIInputBackgroundImageKey)
        return f.outputImage ?? s.composited(over: dst)
    }

    private func applyAdjustment(_ adj: Adjustment, to image: CIImage, opacity: Float) -> CIImage {
        let out: CIImage
        switch adj {
        case .brightness(let v):
            out = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: v])
        case .contrast(let v):
            out = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + v])
        case .saturation(let v):
            out = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + v])
        case .hue(let v):
            // −1…1 → −π…π 색조 회전.
            out = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: v * .pi])
        case .exposure(let v):
            // −1…1 → −2…2 EV.
            out = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v * 2])
        case .levels(let L):
            out = Self.applyLevels(L, to: image)
        case .curve(let C):
            out = Self.applyCurve(C, to: image)
        case .blur(let v):
            // 0…1 → 0…30px. 가장자리 어두워짐 방지로 extent clamp 후 다시 crop.
            out = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v * 30])
                .cropped(to: image.extent)
        case .sharpen(let v):
            out = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: v * 2])
        }
        // opacity < 1 이면 원본과 보정본을 섞는다(조정 레이어 불투명도).
        guard opacity < 1 else { return out }
        return out.applyingAlpha(opacity).composited(over: image)
    }

    /// 레벨: 입력 매핑(블랙/화이트) → clamp → 감마 → 출력 매핑. CI 필터 체인으로 구성.
    static func applyLevels(_ L: Levels, to image: CIImage) -> CIImage {
        let inRange = max(Float(1e-4), L.inWhite - L.inBlack)
        let sIn = CGFloat(1 / inRange), bIn = CGFloat(-L.inBlack / inRange)
        var img = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: sIn, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: sIn, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: sIn, w: 0),
            "inputBiasVector": CIVector(x: bIn, y: bIn, z: bIn, w: 0),
        ])
        img = img.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        if abs(L.gamma - 1) > 1e-4 {     // gamma>1 → 밝게 (power=1/gamma)
            img = img.applyingFilter("CIGammaAdjust", parameters: ["inputPower": CGFloat(1 / max(Float(1e-3), L.gamma))])
        }
        let oRange = CGFloat(L.outWhite - L.outBlack), bOut = CGFloat(L.outBlack)
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: oRange, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: oRange, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: oRange, w: 0),
            "inputBiasVector": CIVector(x: bOut, y: bOut, z: bOut, w: 0),
        ])
    }

    /// 톤 커브: 256-샘플 LUT → CIColorCurves(sRGB 톤 공간에서 적용, 포토샵류 기대치와 일치).
    static func applyCurve(_ C: ToneCurve, to image: CIImage) -> CIImage {
        let n = 256
        let ys = C.sample(count: n)
        var data = [Float](repeating: 0, count: n * 3)
        for i in 0..<n { let y = ys[i]; data[i * 3] = y; data[i * 3 + 1] = y; data[i * 3 + 2] = y }
        let curveData = data.withUnsafeBytes { Data($0) }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": curveData,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    private func affine(_ t: DecomposedTransform) -> CGAffineTransform {
        let m = t.matrix
        return CGAffineTransform(
            a: CGFloat(m[0][0]), b: CGFloat(m[0][1]),
            c: CGFloat(m[1][0]), d: CGFloat(m[1][1]),
            tx: CGFloat(m[2][0]), ty: CGFloat(m[2][1])
        )
    }
}

extension CIImage {
    /// 알파 곱 (premultiplied 유지). opacity 적용용.
    func applyingAlpha(_ alpha: Float) -> CIImage {
        let v = CGFloat(max(0, min(1, alpha)))
        return applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: v)
        ])
    }
}
