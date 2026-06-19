import SwiftUI
import Core

/// 레이어 패널 (SwiftUI). 캔버스(AppKit) 오른쪽에 NSHostingView로 박힌다(설계 §1 하이브리드).
struct LayerPanelView: View {
    @Bindable var vm: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            PageSizeView(vm: vm)
            Divider()
            HStack {
                Text("레이어").font(.headline)
                Spacer()
            }
            .padding(8)
            Divider()

            List(selection: $vm.selectedID) {
                ForEach(vm.rows) { row in
                    LayerRowView(vm: vm, row: row).tag(row.id)
                }
            }
            .listStyle(.inset)
            .onChange(of: vm.selectedID) { vm.reloadInspector(); vm.onSelectionChanged?() }

            if vm.currentTool == .brush || vm.currentTool == .eraser {
                Divider()
                BrushOptionsView(vm: vm)
            }

            if vm.selectedHasSize {
                Divider()
                LayerSizeView(vm: vm)
            }

            if let row = vm.rows.first(where: { $0.id == vm.selectedID }) {
                Divider()
                MaskControlsView(vm: vm, row: row)
            }

            if vm.inspectorKind != .none {
                Divider()
                InspectorView(vm: vm)
            }

            Divider()
            HStack(spacing: 8) {
                Button { if let s = vm.selectedID { vm.moveDown(s) } } label: {
                    Image(systemName: "chevron.down")
                }
                Button { if let s = vm.selectedID { vm.moveUp(s) } } label: {
                    Image(systemName: "chevron.up")
                }
                Spacer()
                Button { if let s = vm.selectedID { vm.delete(s) } } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            .disabled(vm.selectedID == nil)
            .padding(8)
        }
        .frame(minWidth: 220)
    }
}

/// 페이지(문서/캔버스) 크기 — 패널 상단 고정. 앵커 선택은 "⋯"로 전체 다이얼로그.
private struct PageSizeView: View {
    @Bindable var vm: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("페이지").font(.headline)
                Spacer()
                Button { vm.openCanvasSizeDialog() } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(.borderless).help("앵커 선택 등 상세")
            }
            HStack(spacing: 4) {
                Text("W").font(.caption).foregroundStyle(.secondary)
                TextField("", value: vm.pageWBinding(), format: .number)
                    .frame(width: 54).onSubmit { vm.applyPageSize() }
                Text("H").font(.caption).foregroundStyle(.secondary)
                TextField("", value: vm.pageHBinding(), format: .number)
                    .frame(width: 54).onSubmit { vm.applyPageSize() }
                Text("px").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("적용") { vm.applyPageSize() }
            }
        }
        .padding(8)
    }
}

/// 레이어 크기 숫자 입력 (W×H px, 비율 잠금). 리사이즈 핸들의 정밀 입력 버전.
private struct LayerSizeView: View {
    @Bindable var vm: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("크기").font(.headline)
            HStack(spacing: 4) {
                Text("W").font(.caption).foregroundStyle(.secondary)
                TextField("", value: vm.sizeWBinding(), format: .number)
                    .frame(width: 54).onSubmit { vm.applyLayerSize() }
                Text("H").font(.caption).foregroundStyle(.secondary)
                TextField("", value: vm.sizeHBinding(), format: .number)
                    .frame(width: 54).onSubmit { vm.applyLayerSize() }
                Text("px").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Toggle(isOn: $vm.insAspectLock) { Text("비율 잠금").font(.caption) }
                Spacer()
                Button("적용") { vm.applyLayerSize() }
            }
        }
        .padding(8)
    }
}

/// 레이어 마스크 컨트롤 (추가/제거/편집). 마스크 = 비파괴 가리기(흰=보임/검정=숨김).
private struct MaskControlsView: View {
    @Bindable var vm: DocumentViewModel
    let row: LayerRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("마스크").font(.headline)
                Spacer()
                if row.hasMask { Button("제거") { vm.removeMask() } }
                else { Button("추가") { vm.addMask() } }
            }
            if row.hasMask {
                Toggle(isOn: $vm.editingMask) { Text("마스크 편집").font(.caption) }
                if vm.editingMask {
                    Text("브러시=숨김(검정) · 지우개=보임(흰색)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button { vm.removeBackground() } label: {
                Label("배경 지우기 (AI)", systemImage: "person.and.background.dotted")
            }
            .help("Vision 온디바이스로 전경을 분리해 마스크로 배경을 가립니다")
        }
        .padding(8)
    }
}

/// 브러시/지우개 옵션 (크기·경도·간격·플로우). per-view 상태라 undo 없음 — 직접 바인딩.
private struct BrushOptionsView: View {
    @Bindable var vm: DocumentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.currentTool == .eraser ? "지우개" : "브러시").font(.headline)
            row("크기", value: $vm.brush.radius, range: 1...400, fmt: "%.0f")
            row("경도", value: $vm.brush.hardness, range: 0...1, fmt: "%.2f")
            row("간격", value: $vm.brush.spacing, range: 0.05...1, fmt: "%.2f")
            row("플로우", value: $vm.brush.flow, range: 0...1, fmt: "%.2f")
        }
        .padding(8)
    }

    private func row(_ label: String, value: Binding<Double>,
                     range: ClosedRange<Double>, fmt: String) -> some View {
        HStack {
            Text(label).frame(width: 40, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue)).monospacedDigit().font(.caption).frame(width: 36)
        }
    }
}

private struct LayerRowView: View {
    let vm: DocumentViewModel
    let row: LayerRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { vm.toggleVisible(row.id) } label: {
                    Image(systemName: row.visible ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                thumbnail
                Text(row.name).lineLimit(1)
                Spacer()
                if row.hasMask {
                    Image(systemName: "circle.lefthalf.filled").font(.caption2).foregroundStyle(.secondary)
                        .help("마스크 있음")
                }
            }
            if row.isAdjustment && row.isSimpleSlider {
                HStack(spacing: 6) {
                    Text("강도").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: vm.adjustmentBinding(row.id), in: -1...1,
                        onEditingChanged: { vm.adjustmentEditing(row.id, $0) }
                    )
                }
            } else if row.isAdjustment {
                HStack(spacing: 6) {
                    Text("불투명도").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: vm.opacityBinding(row.id), in: 0...1,
                        onEditingChanged: { vm.opacityEditing(row.id, $0) }
                    )
                }
            } else {
                HStack(spacing: 6) {
                    Picker("", selection: blendBinding) {
                        ForEach(Core.BlendMode.allCases, id: \.self) { Text(label($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    Slider(
                        value: vm.opacityBinding(row.id), in: 0...1,
                        onEditingChanged: { vm.opacityEditing(row.id, $0) }
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(row.visible ? 1 : 0.5)
    }

    @ViewBuilder private var thumbnail: some View {
        if let img = row.thumbnail {
            Image(nsImage: img).resizable().interpolation(.medium).scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3)))
        } else {
            // 조정 레이어 등: 아이콘
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.secondary))
        }
    }

    private var blendBinding: Binding<Core.BlendMode> {
        Binding(get: { row.blend }, set: { vm.setBlend(row.id, $0) })
    }

    private func label(_ m: Core.BlendMode) -> String {
        switch m {
        case .normal: return "보통"
        case .multiply: return "곱하기"
        case .screen: return "스크린"
        case .overlay: return "오버레이"
        case .softLight: return "소프트라이트"
        }
    }
}
