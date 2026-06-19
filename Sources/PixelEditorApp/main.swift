import AppKit

// 번들 없는 SwiftPM 실행파일에서 AppKit 앱을 프로그램 방식으로 구동.
// `swift run PixelEditor` 로 실행 → 윈도우가 뜬다(파일 > 열기 ⌘O).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
