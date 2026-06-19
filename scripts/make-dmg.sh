#!/bin/bash
# 릴리즈 .app 번들 + .dmg 생성 — 지인 테스트 배포용(미서명/애드혹).
# 정식 배포(Gatekeeper 무경고)는 Apple Developer ID 인증서 + 공증(notarize)이 필요하다.
# 여기선 무료 '애드혹 서명'까지만 → Apple Silicon에서 실행 가능, 단 첫 실행 시 사용자가 Gatekeeper 우회 필요(읽어보세요.txt).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶︎ 릴리즈 빌드…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

assemble() {
  local name="$1" plist="$2"
  local app="$STAGE/${name}.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN/$name" "$app/Contents/MacOS/$name"
  cp "Resources/$plist" "$app/Contents/Info.plist"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  [ -f "Resources/${name}.icns" ] && cp "Resources/${name}.icns" "$app/Contents/Resources/AppIcon.icns"   # 앱별 아이콘
  # 애드혹 서명(무료) — Apple Silicon 실행 가능 + '손상됨' 경고 완화. 공증은 아님.
  codesign --force --deep --sign - "$app"
  echo "  ✅ ${name}.app"
}

echo "▶︎ 앱 번들 조립 + 애드혹 서명…"
assemble PixelEditor PixelEditor-Info.plist
assemble PDFEditor   PDFEditor-Info.plist

# 드래그 설치용 Applications 심볼릭 링크 + 안내문
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/읽어보세요.txt" <<'TXT'
■ 설치
  PixelEditor.app / PDFEditor.app 를 같은 창의 Applications 폴더로 드래그하세요.

■ 처음 열 때 (미서명 앱 안내)
  아직 Apple 공증 전이라 처음엔 "확인할 수 없는 개발자" 경고가 뜹니다. 둘 중 하나로 엽니다.
  1) 앱 더블클릭 → 경고 → 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 맨 아래 "확인 없이 열기"
  2) 또는 터미널에서 한 번:
       xattr -dr com.apple.quarantine /Applications/PixelEditor.app
       xattr -dr com.apple.quarantine /Applications/PDFEditor.app

■ 참고
  - 저장/실행취소 등은 .app 번들로 실행해야 정상 동작합니다(이미 .app 형태).
  - PixelEditor의 EPS 가져오기는 Ghostscript 필요: brew install ghostscript
TXT

VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/PixelEditor-Info.plist 2>/dev/null || echo 0.1)"
DMG="LAAF-Editors-${VER}.dmg"
echo "▶︎ DMG 생성: $DMG"
rm -f "$DMG"
hdiutil create -volname "LAAF Editors ${VER}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✅ $DMG"
echo "   → 지인에게 파일 전달하거나 홈페이지에 업로드하세요. (받는 사람은 DMG 안 '읽어보세요.txt' 참고)"
