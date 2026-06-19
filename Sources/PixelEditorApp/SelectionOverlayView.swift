import AppKit

/// 선택 레이어의 바운딩 박스 + 모서리 핸들을 그리는 투명 오버레이.
/// 이벤트는 통과시켜(hitTest=nil) 마우스 처리는 전부 CanvasView가 한다.
final class SelectionOverlayView: NSView {
    /// 뷰 좌표계의 4 모서리(BL, BR, TR, TL). nil이면 표시 안 함.
    var corners: [CGPoint]? { didSet { needsDisplay = true } }
    /// 회전 핸들 위치(뷰 좌표). nil이면 표시 안 함(회전 불가 레이어 등).
    var rotationHandle: CGPoint? { didSet { needsDisplay = true } }
    /// 크롭 프레임(뷰 좌표 사각형). 바깥 어둡게 + 격자 + 핸들로 표시.
    var cropFrame: CGRect? { didSet { needsDisplay = true } }
    /// 그라디언트 가이드 선(뷰 좌표 A→B). 드래그 중 방향 표시.
    var gradientLine: (CGPoint, CGPoint)? { didSet { needsDisplay = true } }
    /// 브러시/지우개 커서 원(뷰 좌표 중심 + 반경). 커서 위치·크기 시각화.
    var brushCursor: (center: CGPoint, radius: CGFloat)? { didSet { needsDisplay = true } }
    /// 문서 페이지 경계(뷰 좌표). 무한 평면 속 출력 영역 표시.
    var pageRect: CGRect? { didSet { needsDisplay = true } }

    static let handleSize: CGFloat = 8

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 클릭 통과
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let pr = pageRect {     // 문서 페이지 경계(맨 아래에 옅게)
            NSColor.white.withAlphaComponent(0.22).setStroke()
            let p = NSBezierPath(rect: pr.insetBy(dx: -0.5, dy: -0.5)); p.lineWidth = 1; p.stroke()
        }

        if let cf = cropFrame {
            // 바깥 어둡게(even-odd: 전체 - 크롭영역).
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: cf))
            dim.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.5).setFill(); dim.fill()

            // 3분할 격자.
            let grid = NSBezierPath()
            for k in 1...2 {
                let x = cf.minX + cf.width * CGFloat(k) / 3
                grid.move(to: CGPoint(x: x, y: cf.minY)); grid.line(to: CGPoint(x: x, y: cf.maxY))
                let y = cf.minY + cf.height * CGFloat(k) / 3
                grid.move(to: CGPoint(x: cf.minX, y: y)); grid.line(to: CGPoint(x: cf.maxX, y: y))
            }
            NSColor(white: 1, alpha: 0.4).setStroke(); grid.lineWidth = 0.5; grid.stroke()

            // 테두리.
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: cf); border.lineWidth = 1; border.stroke()

            // 핸들 8개(코너 4 + 변 중점 4).
            let hx = [cf.minX, cf.maxX, cf.maxX, cf.minX, cf.midX, cf.maxX, cf.midX, cf.minX]
            let hy = [cf.minY, cf.minY, cf.maxY, cf.maxY, cf.minY, cf.midY, cf.maxY, cf.midY]
            for i in 0..<8 {
                let r = NSRect(x: hx[i] - 4, y: hy[i] - 4, width: 8, height: 8)
                NSColor.white.setFill(); NSBezierPath(rect: r).fill()
                NSColor.systemBlue.setStroke(); let h = NSBezierPath(rect: r); h.lineWidth = 1; h.stroke()
            }
        }

        if let (a, b) = gradientLine {
            let line = NSBezierPath(); line.move(to: a); line.line(to: b); line.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.5).setStroke(); line.stroke()   // 대비용 그림자
            NSColor.white.setStroke(); line.lineWidth = 1; line.stroke()
            for p in [a, b] {
                let r = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
                NSColor.systemBlue.setStroke(); NSBezierPath(ovalIn: r).stroke()
            }
        }

        if let bc = brushCursor {
            let r = max(1, bc.radius)
            let rect = NSRect(x: bc.center.x - r, y: bc.center.y - r, width: r * 2, height: r * 2)
            // 흑백 이중 원으로 어떤 배경에서도 보이게.
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: -0.5, dy: -0.5))
            NSColor.black.withAlphaComponent(0.6).setStroke(); outer.lineWidth = 1; outer.stroke()
            let inner = NSBezierPath(ovalIn: rect)
            NSColor.white.setStroke(); inner.lineWidth = 1; inner.stroke()
        }

        guard let c = corners, c.count == 4 else { return }
        let box = NSBezierPath()
        box.move(to: c[0]); box.line(to: c[1]); box.line(to: c[2]); box.line(to: c[3]); box.close()
        NSColor.systemBlue.setStroke(); box.lineWidth = 1; box.stroke()

        // 회전 핸들: 윗변(TR-TL) 중점에서 바깥으로 뻗은 선 + 원형 손잡이.
        if let rh = rotationHandle {
            let topMid = CGPoint(x: (c[2].x + c[3].x) / 2, y: (c[2].y + c[3].y) / 2)
            let stem = NSBezierPath(); stem.move(to: topMid); stem.line(to: rh)
            NSColor.systemBlue.setStroke(); stem.lineWidth = 1; stem.stroke()
            let d: CGFloat = 10
            let circle = NSBezierPath(ovalIn: NSRect(x: rh.x - d / 2, y: rh.y - d / 2, width: d, height: d))
            NSColor.white.setFill(); circle.fill()
            NSColor.systemBlue.setStroke(); circle.lineWidth = 1; circle.stroke()
        }

        let s = Self.handleSize
        for p in c {
            let r = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            NSColor.white.setFill(); NSBezierPath(rect: r).fill()
            NSColor.systemBlue.setStroke(); let h = NSBezierPath(rect: r); h.lineWidth = 1; h.stroke()
        }
    }
}
