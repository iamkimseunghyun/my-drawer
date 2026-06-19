import AppKit

/// 문서 기반 앱 (설계 §7). 윈도우는 NSDocument가 만든다 — AppDelegate는 메뉴만 구성.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        startMemoryPressureMonitoring()
        // 시작 시 빈 문서 하나 (문서 기반 앱 기본 동작과 동일하게).
        if NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.newDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 메모리 압박(warning/critical) 시 열린 문서들의 파생 캐시를 비운다(설계 §8, M3).
    private func startMemoryPressureMonitoring() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler {
            for case let doc as PixelEditorDocument in NSDocumentController.shared.documents {
                doc.handleMemoryPressure()
            }
        }
        src.resume()
        memoryPressureSource = src
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // 새 문서 — 크기 지정 다이얼로그(프리셋 또는 사용자 W×H).
    @objc func newSizedDocument(_ sender: Any?) {
        let presets: [(String, Int, Int)] = [
            ("사용자 지정", 0, 0), ("A4 300dpi (2480×3508)", 2480, 3508), ("A4 150dpi (1240×1754)", 1240, 1754),
            ("Letter 300dpi (2550×3300)", 2550, 3300), ("1920×1080", 1920, 1080),
            ("1024×768", 1024, 768), ("정사각 1000", 1000, 1000),
        ]
        let alert = NSAlert(); alert.messageText = "새 문서"; alert.informativeText = "캔버스(페이지) 크기를 지정하세요."
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 84))
        let preset = NSPopUpButton(frame: NSRect(x: 0, y: 54, width: 260, height: 26))
        preset.addItems(withTitles: presets.map { $0.0 }); preset.selectItem(at: 5)
        let wL = NSTextField(labelWithString: "너비"); wL.frame = NSRect(x: 0, y: 22, width: 36, height: 18)
        let wF = NSTextField(frame: NSRect(x: 40, y: 20, width: 80, height: 24)); wF.integerValue = 1024
        let hL = NSTextField(labelWithString: "높이"); hL.frame = NSRect(x: 134, y: 22, width: 36, height: 18)
        let hF = NSTextField(frame: NSRect(x: 174, y: 20, width: 80, height: 24)); hF.integerValue = 768
        [preset, wL, wF, hL, hF].forEach(v.addSubview)
        alert.accessoryView = v
        alert.addButton(withTitle: "만들기"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let idx = preset.indexOfSelectedItem
        let (w, h) = idx > 0 ? (presets[idx].1, presets[idx].2) : (wF.integerValue, hF.integerValue)
        createDocument(width: w, height: h)
    }

    private func createDocument(width: Int, height: Int) {
        let dc = NSDocumentController.shared
        // makeUntitledDocument 으로 생성하면 fileType 이 잡혀 저장이 정상 동작.
        let doc = (dc.defaultType.flatMap { try? dc.makeUntitledDocument(ofType: $0) } as? PixelEditorDocument)
            ?? PixelEditorDocument()
        doc.setNewCanvasSize(width, height)
        dc.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App 메뉴
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "PixelEditor 종료",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 파일
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "파일"); fileItem.submenu = fileMenu
        let newItem = fileMenu.addItem(withTitle: "새로 만들기 (크기 지정)…", action: #selector(newSizedDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(withTitle: "열기…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "가져오기 (이미지·PDF·EPS)…", action: #selector(PixelEditorDocument.importImageDialog(_:)), keyEquivalent: "i")
        let paintItem = fileMenu.addItem(withTitle: "새 페인트 레이어", action: #selector(PixelEditorDocument.newPaintLayer(_:)), keyEquivalent: "n")
        paintItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "저장…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "다른 이름으로 저장…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        fileMenu.addItem(withTitle: "내보내기 (PNG/JPEG)…", action: #selector(PixelEditorDocument.exportImage(_:)), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 편집 (Undo/Redo → 책임 연쇄로 문서 UndoManager에 도달)
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "편집"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "붙여넣기 (새 레이어)", action: #selector(PixelEditorDocument.pasteImage(_:)), keyEquivalent: "v")

        // 도구
        let toolItem = NSMenuItem(); mainMenu.addItem(toolItem)
        let toolMenu = NSMenu(title: "도구"); toolItem.submenu = toolMenu
        toolMenu.addItem(withTitle: "색상…", action: #selector(NSApplication.orderFrontColorPanel(_:)), keyEquivalent: "")
        let hint = toolMenu.addItem(withTitle: "단축키: V 손 · M 이동/크기/회전 · B 브러시 · E 지우개 · I 스포이드 · G 채우기 · ⇧G 그라디언트 · R/O/L 도형 · T 텍스트 · C 자르기(프레임 조절→Enter 적용, Esc 리셋) · A 개체 선택(클릭→새 레이어 추출) · [ ] 크기", action: nil, keyEquivalent: "")
        hint.isEnabled = false

        // 조정 (조정 레이어 추가 → document)
        let adjItem = NSMenuItem(); mainMenu.addItem(adjItem)
        let adjMenu = NSMenu(title: "조정"); adjItem.submenu = adjMenu
        adjMenu.addItem(withTitle: "밝기 조정 레이어", action: #selector(PixelEditorDocument.addBrightness(_:)), keyEquivalent: "")
        adjMenu.addItem(withTitle: "대비 조정 레이어", action: #selector(PixelEditorDocument.addContrast(_:)), keyEquivalent: "")
        adjMenu.addItem(withTitle: "채도 조정 레이어", action: #selector(PixelEditorDocument.addSaturation(_:)), keyEquivalent: "")
        adjMenu.addItem(withTitle: "색조 조정 레이어", action: #selector(PixelEditorDocument.addHue(_:)), keyEquivalent: "")
        adjMenu.addItem(withTitle: "노출 조정 레이어", action: #selector(PixelEditorDocument.addExposure(_:)), keyEquivalent: "")
        adjMenu.addItem(NSMenuItem.separator())
        adjMenu.addItem(withTitle: "레벨 조정 레이어", action: #selector(PixelEditorDocument.addLevels(_:)), keyEquivalent: "")
        adjMenu.addItem(withTitle: "커브 조정 레이어", action: #selector(PixelEditorDocument.addCurve(_:)), keyEquivalent: "")
        adjMenu.addItem(NSMenuItem.separator())
        adjMenu.addItem(withTitle: "블러 조정 레이어", action: #selector(PixelEditorDocument.addBlur(_:)), keyEquivalent: "")
        adjMenu.addItem(withTitle: "샤픈 조정 레이어", action: #selector(PixelEditorDocument.addSharpen(_:)), keyEquivalent: "")

        // 레이어
        let layerItem = NSMenuItem(); mainMenu.addItem(layerItem)
        let layerMenu = NSMenu(title: "레이어"); layerItem.submenu = layerMenu
        layerMenu.addItem(withTitle: "마스크 추가", action: #selector(PixelEditorDocument.addLayerMask(_:)), keyEquivalent: "")
        layerMenu.addItem(withTitle: "배경 지우기 (AI)", action: #selector(PixelEditorDocument.removeBackground(_:)), keyEquivalent: "")

        // 이미지 (문서/페이지 수준)
        let imageItem = NSMenuItem(); mainMenu.addItem(imageItem)
        let imageMenu = NSMenu(title: "이미지"); imageItem.submenu = imageMenu
        imageMenu.addItem(withTitle: "캔버스 크기…", action: #selector(PixelEditorDocument.resizeCanvasDialog(_:)), keyEquivalent: "")

        // 보기 (줌 → first responder인 CanvasView로)
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "보기"); viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "확대", action: #selector(CanvasView.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "축소", action: #selector(CanvasView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "화면에 맞춤", action: #selector(CanvasView.zoomToFit(_:)), keyEquivalent: "0")

        NSApp.mainMenu = mainMenu
    }
}
