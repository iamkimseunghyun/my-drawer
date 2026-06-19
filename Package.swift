// swift-tools-version: 6.0
import PackageDescription

// M0 골격. 모듈 의존 방향은 DESIGN.md 부록 A를 따른다:
//   Core(leaf) ← ColorPipeline ← Rendering ← App
// Swift 6 strict concurrency는 M3에서 켠다(설계 §2). M0는 .v5 모드로 골격에 집중.
let package = Package(
    name: "PixelEditor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PixelEditor", targets: ["PixelEditorApp"]),   // 이미지 편집기
        .executable(name: "PDFEditor", targets: ["PDFEditorApp"]),       // PDF 편집기(PDFKit)
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "ColorPipeline", dependencies: ["Core"]),
        .target(name: "Rendering", dependencies: ["Core", "ColorPipeline"]),
        .executableTarget(
            name: "PixelEditorApp",
            dependencies: ["Core", "ColorPipeline", "Rendering"]
        ),
        // PDF 편집기는 PDFKit/AppKit만 사용 — 우리 모듈에 의존하지 않음(거의 독립).
        .executableTarget(name: "PDFEditorApp"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "ColorPipelineTests", dependencies: ["ColorPipeline", "Core"]),
        .testTarget(name: "RenderingTests", dependencies: ["Rendering", "Core"]),
    ],
    swiftLanguageModes: [.v5]
)
