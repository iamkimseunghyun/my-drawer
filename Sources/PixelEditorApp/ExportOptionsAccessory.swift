import AppKit
import simd

/// 내보내기(⌘E) NSSavePanel 액세서리 — 포맷(PNG/JPEG) · 크기(배율) · JPEG 품질.
/// "쉽고 빠른 배포"(설계 §1.2): 흔한 선택을 프리셋으로 1~2클릭에 끝낸다.
final class ExportOptionsAccessory: NSView {
    private let basePixels: SIMD2<Int>
    private weak var panel: NSSavePanel?

    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let qualityValue = NSTextField(labelWithString: "")

    private let scales: [Double] = [1.0, 0.75, 0.5, 0.25]

    var isJPEG: Bool { formatPopup.indexOfSelectedItem == 1 }
    var scale: Double { scales[max(0, scalePopup.indexOfSelectedItem)] }
    var quality: Double { qualitySlider.doubleValue }

    /// 배율 적용 후 출력 픽셀 크기(최소 1).
    var outputPixels: SIMD2<Int> {
        SIMD2(max(1, Int((Double(basePixels.x) * scale).rounded())),
              max(1, Int((Double(basePixels.y) * scale).rounded())))
    }

    init(basePixels: SIMD2<Int>, panel: NSSavePanel) {
        self.basePixels = basePixels
        self.panel = panel
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 104))

        func label(_ s: String, x: CGFloat, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.frame = NSRect(x: x, y: y, width: 64, height: 20)
            l.alignment = .right; addSubview(l); return l
        }

        // 포맷
        _ = label("포맷:", x: 8, y: 72)
        formatPopup.frame = NSRect(x: 80, y: 68, width: 130, height: 26)
        formatPopup.addItems(withTitles: ["PNG", "JPEG"])
        formatPopup.target = self; formatPopup.action = #selector(formatChanged)
        addSubview(formatPopup)

        // 크기(배율)
        _ = label("크기:", x: 8, y: 40)
        scalePopup.frame = NSRect(x: 80, y: 36, width: 130, height: 26)
        scalePopup.addItems(withTitles: ["100%", "75%", "50%", "25%"])
        scalePopup.target = self; scalePopup.action = #selector(scaleChanged)
        addSubview(scalePopup)
        sizeLabel.frame = NSRect(x: 218, y: 40, width: 154, height: 20)
        sizeLabel.textColor = .secondaryLabelColor; addSubview(sizeLabel)

        // JPEG 품질
        _ = label("품질:", x: 8, y: 8)
        qualitySlider.frame = NSRect(x: 80, y: 6, width: 130, height: 24)
        qualitySlider.target = self; qualitySlider.action = #selector(qualityChanged)
        addSubview(qualitySlider)
        qualityValue.frame = NSRect(x: 218, y: 8, width: 154, height: 20)
        qualityValue.textColor = .secondaryLabelColor; addSubview(qualityValue)

        updateSizeLabel(); updateQualityLabel(); updateQualityEnabled()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func formatChanged() {
        // 파일명 확장자를 포맷에 맞춰 교체 + 허용 타입 갱신.
        if let panel {
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + (isJPEG ? ".jpg" : ".png")
            panel.allowedContentTypes = isJPEG ? [.jpeg] : [.png]
        }
        updateQualityEnabled()
    }
    @objc private func scaleChanged() { updateSizeLabel() }
    @objc private func qualityChanged() { updateQualityLabel() }

    private func updateSizeLabel() {
        let p = outputPixels; sizeLabel.stringValue = "→ \(p.x) × \(p.y) px"
    }
    private func updateQualityLabel() {
        qualityValue.stringValue = isJPEG ? String(format: "%.0f%%", quality * 100) : "PNG (무손실)"
    }
    private func updateQualityEnabled() {
        qualitySlider.isEnabled = isJPEG; updateQualityLabel()
    }
}
