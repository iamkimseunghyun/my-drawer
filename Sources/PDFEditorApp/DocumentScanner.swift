import Vision
import CoreImage
import CoreGraphics

/// 문서 스캔 — Apple Vision 온디바이스로 사진 속 문서 경계를 찾아 원근 보정(deskew).
/// 시스템 프레임워크만 사용(우리 모듈 의존 없음 — PDFEditor 규약 유지).
enum DocumentScanner {
    /// 문서 경계를 찾아 원근 보정한 CGImage. 경계를 못 찾으면 nil(호출부에서 원본 사용).
    static func scan(_ cgImage: CGImage) -> CGImage? {
        guard #available(macOS 13.0, *) else { return nil }
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first else { return nil }
        let ci = CIImage(cgImage: cgImage)
        return perspectiveCorrect(ci, obs)
    }

    /// 정규화 코너(0…1, 좌하단 원점)를 픽셀로 환산해 CIPerspectiveCorrection 적용.
    private static func perspectiveCorrect(_ ci: CIImage, _ obs: VNRectangleObservation) -> CGImage? {
        let w = ci.extent.width, h = ci.extent.height
        func px(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        let corrected = ci.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": px(obs.topLeft),
            "inputTopRight": px(obs.topRight),
            "inputBottomLeft": px(obs.bottomLeft),
            "inputBottomRight": px(obs.bottomRight),
        ])
        return ciContext.createCGImage(corrected, from: corrected.extent)
    }

    private static let ciContext = CIContext(options: nil)
}
