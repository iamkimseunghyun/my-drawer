import Vision
import CoreGraphics

/// OCR — Apple Vision 온디바이스 텍스트 인식(한국어+영어). 시스템 프레임워크만(우리 모듈 의존 없음).
enum TextRecognizer {
    /// 이미지에서 인식한 텍스트 줄들(위→아래 대략 순서). 못 찾으면 빈 배열.
    static func recognize(_ cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR", "en-US"]      // 지원 안 되면 Vision이 폴백
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = request.results ?? []
        // 위에서 아래로(Vision normalized 좌표는 좌하단 원점 → y 큰 게 위).
        return observations
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
