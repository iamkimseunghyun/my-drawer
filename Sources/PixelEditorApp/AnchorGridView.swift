import AppKit

/// 캔버스 크기 다이얼로그의 3×3 앵커 그리드 (포토샵식). 방향 아이콘 + 선택 하이라이트.
/// 셀을 클릭하면 그 위치로 내용이 고정된다.
final class AnchorGridView: NSView {
    private(set) var selectedIndex = 4         // 가운데
    private let cell: CGFloat = 22, gap: CGFloat = 3
    private let symbols = ["arrow.up.left", "arrow.up", "arrow.up.right",
                           "arrow.left", "smallcircle.filled.circle", "arrow.right",
                           "arrow.down.left", "arrow.down", "arrow.down.right"]
    private let anchors: [PixelEditorDocument.CanvasAnchor] =
        [.topLeft, .top, .topRight, .left, .center, .right, .bottomLeft, .bottom, .bottomRight]

    var anchor: PixelEditorDocument.CanvasAnchor { anchors[selectedIndex] }
    override var intrinsicContentSize: NSSize { NSSize(width: 3 * cell + 2 * gap, height: 3 * cell + 2 * gap) }

    /// 셀 i(행우선, 0=좌상)의 사각형. 비플립 뷰라 행0(상단)을 높은 y로 매핑.
    private func cellRect(_ i: Int) -> CGRect {
        let col = CGFloat(i % 3), yTop = CGFloat(2 - i / 3)
        return CGRect(x: col * (cell + gap), y: yTop * (cell + gap), width: cell, height: cell)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0..<9 where cellRect(i).contains(p) { selectedIndex = i; needsDisplay = true; break }
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<9 {
            let r = cellRect(i), sel = i == selectedIndex
            let box = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            (sel ? NSColor.controlAccentColor : NSColor.gridColor.withAlphaComponent(0.4)).setFill(); box.fill()
            NSColor.separatorColor.setStroke(); box.lineWidth = 1; box.stroke()
            let color: NSColor = sel ? .white : .secondaryLabelColor
            if let img = NSImage(systemSymbolName: symbols[i], accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color])) {
                img.draw(in: r.insetBy(dx: 5, dy: 5))
            }
        }
    }
}
