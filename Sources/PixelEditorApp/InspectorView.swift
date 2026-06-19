import SwiftUI
import AppKit
import Core

// RGBA8 ↔ SwiftUI Color
extension RGBA8 {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
extension Color {
    var rgba8: RGBA8 {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return RGBA8(UInt8((ns.redComponent * 255).rounded()), UInt8((ns.greenComponent * 255).rounded()),
                     UInt8((ns.blueComponent * 255).rounded()), UInt8((ns.alphaComponent * 255).rounded()))
    }
}

/// 선택 레이어 인스펙터 (V1b-4). 텍스트=폰트/크기/색, 도형=채움/테두리.
struct InspectorView: View {
    @Bindable var vm: DocumentViewModel

    var body: some View {
        switch vm.inspectorKind {
        case .text: textInspector
        case .shape: shapeInspector
        case .levels: levelsInspector
        case .curve: curveInspector
        case .radius: radiusInspector
        case .none: EmptyView()
        }
    }

    private var radiusInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.insRadiusTitle).font(.headline)
            HStack {
                Text(vm.insRadiusTitle == "블러" ? "반경" : "강도")
                    .frame(width: 36, alignment: .leading).font(.caption)
                Slider(value: vm.radiusBinding(), in: 0...1,
                       onEditingChanged: { vm.sliderEditing($0, vm.insRadiusTitle) })
                Text("\(Int(vm.insRadius * 100))").monospacedDigit().font(.caption).frame(width: 32)
            }
        }
        .padding(8)
    }

    private var levelsInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("레벨").font(.headline); Spacer(); Button("리셋") { vm.resetLevels() } }
            levelsSlider("입력 검정", \.inBlack, 0...1)
            levelsSlider("입력 흰색", \.inWhite, 0...1)
            levelsSlider("감마", \.gamma, 0.1...3)
            levelsSlider("출력 검정", \.outBlack, 0...1)
            levelsSlider("출력 흰색", \.outWhite, 0...1)
        }
        .padding(8)
    }

    private func levelsSlider(_ label: String, _ kp: WritableKeyPath<Levels, Float>,
                              _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 64, alignment: .leading).font(.caption)
            Slider(value: vm.levelsBinding(kp), in: range,
                   onEditingChanged: { vm.sliderEditing($0, "레벨") })
            Text(String(format: "%.2f", vm.insLevels[keyPath: kp])).monospacedDigit()
                .font(.caption).frame(width: 36)
        }
    }

    private var curveInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("커브").font(.headline); Spacer(); Button("리셋") { vm.resetCurve() } }
            CurveEditor(vm: vm).frame(height: 200)
            Text("점 드래그=이동 · 빈 곳 더블클릭=추가 · 점 더블클릭=삭제")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private var textInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("텍스트").font(.headline)
            TextField("내용", text: $vm.insText).onSubmit { vm.commitTextString() }
            HStack {
                Text("글꼴").frame(width: 36, alignment: .leading)
                Picker("", selection: fontBinding) {
                    Text("시스템").tag(String?.none)
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { f in
                        Text(f).tag(String?.some(f))
                    }
                }.labelsHidden()
            }
            HStack {
                Text("크기").frame(width: 36, alignment: .leading)
                Slider(value: vm.fontSizeBinding(), in: 8...400,
                       onEditingChanged: { vm.sliderEditing($0, "글꼴 크기") })
                Text("\(Int(vm.insFontSize))").monospacedDigit().frame(width: 34)
            }
            ColorPicker("글자색", selection: textColorBinding, supportsOpacity: true)
        }
        .padding(8)
    }

    private var shapeInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("도형").font(.headline)
            ColorPicker("채움", selection: fillBinding, supportsOpacity: true)
            ColorPicker("테두리 색", selection: strokeColorBinding, supportsOpacity: true)
            HStack {
                Text("테두리").frame(width: 44, alignment: .leading)
                Slider(value: vm.strokeWidthBinding(), in: 0...40,
                       onEditingChanged: { vm.sliderEditing($0, "테두리 두께") })
                Text("\(Int(vm.insStrokeWidth))").monospacedDigit().frame(width: 28)
            }
        }
        .padding(8)
    }

    // MARK: bindings
    private var fontBinding: Binding<String?> {
        Binding(get: { vm.insFontName }, set: { vm.setFont($0) })
    }
    private var textColorBinding: Binding<Color> {
        Binding(get: { vm.insColor.color }, set: { vm.setTextColor($0.rgba8) })
    }
    private var fillBinding: Binding<Color> {
        Binding(get: { (vm.insFill ?? RGBA8(0, 0, 0, 0)).color }, set: { vm.setFill($0.rgba8) })
    }
    private var strokeColorBinding: Binding<Color> {
        Binding(get: { (vm.insStrokeColor ?? RGBA8(0, 0, 0, 0)).color }, set: { vm.setStrokeColor($0.rgba8) })
    }
}
