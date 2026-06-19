import SwiftUI
import Core

/// 톤 커브 그래프 편집기. 점 드래그=이동 · 빈 곳 더블클릭=추가 · 점 더블클릭=삭제.
/// 좌표: 커브공간 (x,y)∈0…1 ↔ 뷰 (x*W, (1-y)*H). 모델 점은 x 오름차순 불변.
struct CurveEditor: View {
    let vm: DocumentViewModel
    @State private var activeIndex: Int?

    private let grabRadius: CGFloat = 14

    var body: some View {
        let curve = vm.insCurve            // 관찰 의존성 등록(변경 시 재드로우)
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, sz in draw(curve, ctx, sz) }
                .background(Color(white: 0.12))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if activeIndex == nil {
                                guard let i = nearest(to: g.startLocation, size: size) else { return }
                                activeIndex = i; vm.curveBeginEdit()
                            }
                            moveActive(to: g.location, size: size)
                        }
                        .onEnded { _ in
                            if activeIndex != nil { vm.curveCommit(); activeIndex = nil }
                        }
                )
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { e in doubleClick(e.location, size: size) }
                )
        }
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.3)))
    }

    // MARK: 좌표 변환
    private func viewPoint(_ p: SIMD2<Float>, _ size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
    }

    private func nearest(to loc: CGPoint, size: CGSize) -> Int? {
        let pts = vm.insCurve.points
        var best: Int?; var bestD = grabRadius
        for (i, p) in pts.enumerated() {
            let v = viewPoint(p, size)
            let d = hypot(v.x - loc.x, v.y - loc.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    // MARK: 편집
    private func moveActive(to loc: CGPoint, size: CGSize) {
        guard let i = activeIndex else { return }
        var pts = vm.insCurve.points
        guard i < pts.count else { return }
        var nx = Float(min(max(loc.x / size.width, 0), 1))
        let ny = Float(min(max(1 - loc.y / size.height, 0), 1))
        if i == 0 { nx = 0 }                                  // 양 끝점은 x 고정
        else if i == pts.count - 1 { nx = 1 }
        else { nx = min(max(nx, pts[i - 1].x + 0.001), pts[i + 1].x - 0.001) }
        pts[i] = SIMD2(nx, ny)
        vm.curveLive(ToneCurve(points: pts))
    }

    private func doubleClick(_ loc: CGPoint, size: CGSize) {
        var pts = vm.insCurve.points
        if let i = nearest(to: loc, size: size) {
            if i != 0 && i != pts.count - 1 {                 // 내부 점 삭제(끝점은 유지)
                pts.remove(at: i); vm.curveSetCommitted(ToneCurve(points: pts))
            }
            return
        }
        let nx = Float(min(max(loc.x / size.width, 0), 1))
        let ny = Float(min(max(1 - loc.y / size.height, 0), 1))
        guard nx > 0.001, nx < 0.999 else { return }          // 끝점 자리엔 추가 안 함
        pts.append(SIMD2(nx, ny)); pts.sort { $0.x < $1.x }
        vm.curveSetCommitted(ToneCurve(points: pts))
    }

    // MARK: 드로잉
    private func draw(_ curve: ToneCurve, _ ctx: GraphicsContext, _ size: CGSize) {
        // 3분할 격자
        var grid = Path()
        for k in 1...2 {
            let x = size.width * CGFloat(k) / 3, y = size.height * CGFloat(k) / 3
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(grid, with: .color(Color(white: 0.25)), lineWidth: 0.5)

        // 항등 대각선(점선)
        var diag = Path()
        diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
        ctx.stroke(diag, with: .color(Color(white: 0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // 커브
        let ys = curve.sample(count: 65)
        var path = Path()
        for (i, y) in ys.enumerated() {
            let x = CGFloat(i) / CGFloat(ys.count - 1) * size.width
            let py = (1 - CGFloat(y)) * size.height
            if i == 0 { path.move(to: CGPoint(x: x, y: py)) } else { path.addLine(to: CGPoint(x: x, y: py)) }
        }
        ctx.stroke(path, with: .color(.white), lineWidth: 1.5)

        // 제어점
        for p in curve.points {
            let v = viewPoint(p, size)
            let r = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: r), with: .color(.white))
            ctx.stroke(Path(ellipseIn: r), with: .color(.accentColor), lineWidth: 1.5)
        }
    }
}
