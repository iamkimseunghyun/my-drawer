import SwiftUI
import Core

/// 도구 팔레트 (좌측 세로 툴바). 포토샵류 — 아이콘 클릭으로 도구 선택, 활성 도구 하이라이트.
/// 단축키와 동기화(vm.currentTool 관찰) — 키보드로 바꿔도 버튼 하이라이트가 따라온다.
struct ToolPaletteView: View {
    @Bindable var vm: DocumentViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                button("hand.raised", "손 · 팬 (V)", vm.currentTool == .pan) { vm.selectTool(.pan) }
                button("arrow.up.and.down.and.arrow.left.and.right", "이동·크기·회전 (M)", vm.currentTool == .move) { vm.selectTool(.move) }

                divider
                button("paintbrush.pointed.fill", "브러시 (B)", vm.currentTool == .brush) { vm.selectTool(.brush) }
                button("eraser.fill", "지우개 (E)", vm.currentTool == .eraser) { vm.selectTool(.eraser) }
                button("drop.fill", "채우기 (G)", vm.currentTool == .fill) { vm.selectTool(.fill) }
                button("square.lefthalf.filled", "그라디언트 (⇧G)", vm.currentTool == .gradient) { vm.selectTool(.gradient) }
                button("eyedropper", "스포이드 (I)", vm.currentTool == .eyedropper) { vm.selectTool(.eyedropper) }

                divider
                button("rectangle", "사각형 (R)", isShape(.rectangle)) { vm.selectShape(.rectangle) }
                button("circle", "원 (O)", isShape(.oval)) { vm.selectShape(.oval) }
                button("line.diagonal", "선 (L)", isShape(.line)) { vm.selectShape(.line) }
                button("textformat", "텍스트 (T)", vm.currentTool == .text) { vm.selectTool(.text) }

                divider
                button("crop", "자르기 (C)", vm.currentTool == .crop) { vm.selectTool(.crop) }
                button("wand.and.stars", "개체 선택 (A)", vm.currentTool == .objectSelect) { vm.selectTool(.objectSelect) }

                divider
                ColorPicker(selection: brushColorBinding, supportsOpacity: true) { EmptyView() }
                    .labelsHidden()
                    .frame(width: 36, height: 28)
                    .help("브러시/전경 색")

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
    }

    private var brushColorBinding: Binding<Color> {
        Binding(get: { vm.brush.color.color }, set: { vm.brush.color = $0.rgba8 })
    }

    private func isShape(_ k: VectorKind) -> Bool { vm.currentTool == .shape && vm.shapeKind == k }

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 28, height: 1).padding(.vertical, 2)
    }

    private func button(_ icon: String, _ help: String, _ active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 32)
                .background(active ? Color.accentColor : Color.clear)
                .foregroundStyle(active ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
