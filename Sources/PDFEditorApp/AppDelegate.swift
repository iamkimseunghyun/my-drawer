import AppKit

/// PDF 편집기 앱. 문서 기반(.pdf). 메뉴: 파일·편집·페이지.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        // 시작 시 열기 패널(PDF는 보통 기존 파일을 연다). 취소해도 ⌘N/⌘O 가능.
        if NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.openDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "PDFEditor 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "파일"); fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "새 PDF", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "열기…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "저장…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "다른 이름으로 저장…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        fileMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "편집"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "Z")

        // 페이지 작업(창의 버튼과 동일 — first responder인 윈도우 컨트롤러로 라우팅)
        let pageItem = NSMenuItem(); mainMenu.addItem(pageItem)
        let pageMenu = NSMenu(title: "페이지"); pageItem.submenu = pageMenu
        pageMenu.addItem(withTitle: "회전", action: #selector(PDFEditWindowController.rotatePage), keyEquivalent: "r")
        pageMenu.addItem(withTitle: "페이지 삭제", action: #selector(PDFEditWindowController.deletePage), keyEquivalent: "") // 버튼/메뉴로만(⌫는 도장 삭제용)
        pageMenu.addItem(withTitle: "위로", action: #selector(PDFEditWindowController.movePageUp), keyEquivalent: "[")
        pageMenu.addItem(withTitle: "아래로", action: #selector(PDFEditWindowController.movePageDown), keyEquivalent: "]")
        pageMenu.addItem(withTitle: "이미지 페이지 추가…", action: #selector(PDFEditWindowController.insertImage), keyEquivalent: "")
        pageMenu.addItem(withTitle: "문서 스캔 (사진→반듯한 페이지)…", action: #selector(PDFEditWindowController.scanDocument), keyEquivalent: "")
        pageMenu.addItem(withTitle: "텍스트 인식 (OCR)…", action: #selector(PDFEditWindowController.recognizeText), keyEquivalent: "")
        pageMenu.addItem(withTitle: "PDF 삽입…", action: #selector(PDFEditWindowController.insertPDF), keyEquivalent: "")
        pageMenu.addItem(NSMenuItem.separator())
        pageMenu.addItem(withTitle: "도장/이미지 추가…", action: #selector(PDFEditWindowController.insertStamp), keyEquivalent: "")
        pageMenu.addItem(withTitle: "텍스트 추가…", action: #selector(PDFEditWindowController.insertTextAnnotation), keyEquivalent: "t")
        pageMenu.addItem(withTitle: "선택 도장/이미지 삭제", action: #selector(PDFEditWindowController.deleteSelectedStamp), keyEquivalent: "\u{8}")

        // 보기 (줌 → 윈도우 컨트롤러)
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "보기"); viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "확대", action: #selector(PDFEditWindowController.zoomInAction), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "축소", action: #selector(PDFEditWindowController.zoomOutAction), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "화면에 맞춤", action: #selector(PDFEditWindowController.zoomFitAction), keyEquivalent: "0")

        NSApp.mainMenu = mainMenu
    }
}
