import Vision
import CoreImage
import CoreGraphics

/// 배경 지우기 — Apple Vision 온디바이스 전경 마스크(macOS 14+). 외부 AI/네트워크 불필요.
/// 결과: 그레이스케일 CGImage(흰=전경/주제, 검정=배경) — 그대로 레이어 마스크 커버리지로 쓴다.
enum BackgroundRemover {
    /// 입력 이미지에서 모든 전경 인스턴스의 마스크를 생성. 실패 시 nil.
    static func foregroundMask(of cgImage: CGImage) -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }   // 전경 못 찾음
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances,
                                                               from: handler)
            let ci = CIImage(cvPixelBuffer: buffer)
            return ciContext.createCGImage(ci, from: ci.extent)
        } catch {
            return nil
        }
    }

    /// 클릭한 콘텐츠 픽셀(top-left)을 덮는 단일 개체의 마스크. 개체 자동선택용.
    static func objectMask(of cgImage: CGImage, atContentPixel pt: CGPoint) -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first else { return nil }
        // 각 인스턴스의 스케일 마스크(콘텐츠 크기, top-left)를 만들어 클릭 픽셀이 흰색인 것을 선택.
        for idx in result.allInstances {
            guard let buf = try? result.generateScaledMaskForImage(forInstances: IndexSet(integer: idx),
                                                                   from: handler) else { continue }
            if maskValue(buf, atX: Int(pt.x), y: Int(pt.y)) > 0.5 {
                let ci = CIImage(cvPixelBuffer: buf)
                return ciContext.createCGImage(ci, from: ci.extent)
            }
        }
        return nil
    }

    /// CVPixelBuffer(OneComponent 8/Float)의 픽셀값 0…1. 범위 밖이면 0.
    private static func maskValue(_ buf: CVPixelBuffer, atX x: Int, y: Int) -> Double {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        guard x >= 0, y >= 0, x < w, y < h, let base = CVPixelBufferGetBaseAddress(buf) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(buf)
        let row = base.advanced(by: y * rowBytes)
        if CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_OneComponent32Float {
            return Double(row.advanced(by: x * 4).load(as: Float32.self))
        }
        return Double(row.advanced(by: x).load(as: UInt8.self)) / 255
    }

    private static let ciContext = CIContext(options: nil)
}
