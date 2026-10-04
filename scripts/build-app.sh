#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
DOT_WAKE_BUILD_FLAGS=()
if [[ "${DOT_WAKE_DIAGNOSTICS:-0}" == 1 ]]; then DOT_WAKE_BUILD_FLAGS=(-Xswiftc -DDOT_WAKE_DIAGNOSTICS); fi
swift build --disable-sandbox -c release --product DotWake ${DOT_WAKE_BUILD_FLAGS[@]}
app="${DOT_WAKE_APP_OUTPUT:-$PWD/dist/Dot Wake.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Model"
cp .build/release/DotWake "$app/Contents/MacOS/DotWake"
model="${DOT_WAKE_MODEL_DIR:-$PWD/Models}"
for part in encoder decoder joiner; do
 cp "$model/$part-epoch-12-avg-2-chunk-16-left-64.onnx" "$app/Contents/Resources/Model/"
done
cp "$model/bpe-scores.json" "$app/Contents/Resources/Model/"
cp "$model/tokens.txt" "$app/Contents/Resources/Model/"
/usr/libexec/PlistBuddy -c 'Clear dict' "$app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string DotWake' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.dotwake.menubarpreview' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Dot Wake' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Dot Wake' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 12' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.4.10' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string Dot Wake detects Hey, Mute and Bye plus your chosen name locally, only after you click Start Listening. Audio is never saved or uploaded.' "$app/Contents/Info.plist"
if [[ "${DOT_WAKE_DIAGNOSTICS:-0}" != 1 ]]; then strip -S -x "$app/Contents/MacOS/DotWake"; fi
mkdir -p "$app/Contents/Resources/Licenses"
chmod -R u+w "$app/Contents/Resources/Licenses"
cp licenses/*.txt "$app/Contents/Resources/Licenses/"
codesign --force --sign - "$app"
print "$app"
