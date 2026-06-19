#!/bin/bash
# SwiftPM 바이너리를 macOS .app 번들로 조립한다(NSDocument는 Info.plist 번들 필요).
# 두 앱: PixelEditor(이미지) / PDFEditor(PDF).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
BIN="$(swift build --show-bin-path)"

assemble() {
  local name="$1" plist="$2"
  local app="${name}.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN/$name" "$app/Contents/MacOS/$name"
  cp "Resources/$plist" "$app/Contents/Info.plist"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  [ -f "Resources/${name}.icns" ] && cp "Resources/${name}.icns" "$app/Contents/Resources/AppIcon.icns"   # 앱별 아이콘
  echo "✅ $app"
}

assemble PixelEditor PixelEditor-Info.plist
assemble PDFEditor   PDFEditor-Info.plist
echo "실행: open PixelEditor.app  또는  open PDFEditor.app"
