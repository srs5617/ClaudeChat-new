#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "错误：iOS 必须在 macOS + Xcode 环境中编译。" >&2
  exit 2
fi

for command_name in xcodebuild xcrun ditto plutil shasum unzip; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "错误：缺少构建命令 $command_name。请先安装完整 Xcode。" >&2
    exit 2
  fi
done

if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  echo "错误：找不到 Flutter：$FLUTTER_BIN" >&2
  exit 2
fi

cd "$PROJECT_ROOT"

echo "==> Flutter / Xcode 环境"
"$FLUTTER_BIN" --version
xcodebuild -version

echo "==> 获取依赖"
"$FLUTTER_BIN" pub get

echo "==> 静态检查与自动测试"
"$FLUTTER_BIN" analyze --no-pub
"$FLUTTER_BIN" test --no-pub

echo "==> 编译未签名的 Release iOS 应用"
"$FLUTTER_BIN" build ios --release --no-codesign --no-pub

APP_PATH="$PROJECT_ROOT/build/ios/iphoneos/Runner.app"
INFO_PLIST="$APP_PATH/Info.plist"
WIDGET_PATH="$APP_PATH/PlugIns/ClaudeChatWidget.appex"
WIDGET_PLIST="$WIDGET_PATH/Info.plist"
GENERATED_XCCONFIG="$PROJECT_ROOT/ios/Flutter/Generated.xcconfig"

if [[ ! -d "$APP_PATH" || ! -f "$INFO_PLIST" ]]; then
  echo "错误：没有生成 Runner.app。" >&2
  exit 3
fi
if [[ ! -d "$WIDGET_PATH" || ! -f "$WIDGET_PLIST" ]]; then
  echo "错误：IPA 缺少 ClaudeChatWidget.appex；拒绝输出不完整安装包。" >&2
  exit 3
fi

generated_setting() {
  local setting_name="$1"
  awk -v key="$setting_name" \
    'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' \
    "$GENERATED_XCCONFIG"
}

ensure_plist_string() {
  local plist_path="$1"
  local key="$2"
  local value="$3"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist_path"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist_path"
  fi
}

if [[ ! -f "$GENERATED_XCCONFIG" ]]; then
  echo "错误：缺少 Flutter 生成的构建配置：$GENERATED_XCCONFIG" >&2
  exit 3
fi

APP_VERSION="$(generated_setting FLUTTER_BUILD_NAME)"
BUILD_NUMBER="$(generated_setting FLUTTER_BUILD_NUMBER)"
if [[ -z "$APP_VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "错误：无法从 Generated.xcconfig 读取应用版本与构建号。" >&2
  exit 3
fi

# 某些 Xcode/Flutter 组合会从未签名产物的 Info.plist 中省略版本字段。
# 全能签重新签名之前必须让主应用与小组件都拥有完整且一致的版本元数据。
ensure_plist_string "$INFO_PLIST" CFBundleShortVersionString "$APP_VERSION"
ensure_plist_string "$INFO_PLIST" CFBundleVersion "$BUILD_NUMBER"
ensure_plist_string "$WIDGET_PLIST" CFBundleShortVersionString "$APP_VERSION"
ensure_plist_string "$WIDGET_PLIST" CFBundleVersion "$BUILD_NUMBER"

MAIN_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
WIDGET_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WIDGET_PLIST")"
WIDGET_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$WIDGET_PLIST")"
WIDGET_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WIDGET_PLIST")"
WIDGET_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WIDGET_PLIST")"

if [[ "$MAIN_BUNDLE_ID" != "com.susuclaude.app" ]]; then
  echo "错误：主应用 Bundle ID 异常：$MAIN_BUNDLE_ID" >&2
  exit 3
fi
if [[ "$WIDGET_BUNDLE_ID" != "com.susuclaude.app.widget" ]]; then
  echo "错误：小组件 Bundle ID 异常：$WIDGET_BUNDLE_ID" >&2
  exit 3
fi
if [[ "$WIDGET_VERSION" != "$APP_VERSION" || "$WIDGET_BUILD_NUMBER" != "$BUILD_NUMBER" ]]; then
  echo "错误：小组件版本 $WIDGET_VERSION+$WIDGET_BUILD_NUMBER 与主应用 $APP_VERSION+$BUILD_NUMBER 不一致。" >&2
  exit 3
fi
if [[ ! -f "$APP_PATH/$MAIN_EXECUTABLE" ]]; then
  echo "错误：主应用可执行文件不存在。" >&2
  exit 3
fi
if [[ ! -f "$WIDGET_PATH/$WIDGET_EXECUTABLE" ]]; then
  echo "错误：小组件可执行文件不存在。" >&2
  exit 3
fi

xcrun lipo "$APP_PATH/$MAIN_EXECUTABLE" -verify_arch arm64
xcrun lipo "$WIDGET_PATH/$WIDGET_EXECUTABLE" -verify_arch arm64

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudechat-ipa.XXXXXX")"
cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/claudechat-ipa.*) rm -rf -- "$TEMP_ROOT" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$TEMP_ROOT/Payload"
ditto "$APP_PATH" "$TEMP_ROOT/Payload/Runner.app"

# 全能签等工具需要自行签主应用、Framework 和 appex。这里移除任何可能
# 被 Xcode 缓存带入的旧签名与描述文件，保证产物是干净的未签名 IPA。
find "$TEMP_ROOT/Payload" -depth -type d -name _CodeSignature -exec rm -rf -- {} +
find "$TEMP_ROOT/Payload" -type f -name embedded.mobileprovision -delete
xattr -cr "$TEMP_ROOT/Payload"

OUTPUT_DIR="$PROJECT_ROOT/build/ios/ipa"
OUTPUT_NAME="ClaudeChat-${APP_VERSION}+${BUILD_NUMBER}-unsigned.ipa"
OUTPUT_PATH="$OUTPUT_DIR/$OUTPUT_NAME"
PORTABLE_PATH="$PROJECT_ROOT/ClaudeChat-ios-unsigned.ipa"
mkdir -p "$OUTPUT_DIR"
rm -f -- "$OUTPUT_PATH" "$PORTABLE_PATH"
ditto -c -k --keepParent "$TEMP_ROOT/Payload" "$OUTPUT_PATH"
unzip -tq "$OUTPUT_PATH"
cp -f -- "$OUTPUT_PATH" "$PORTABLE_PATH"

SHA256="$(shasum -a 256 "$OUTPUT_PATH" | awk '{print $1}')"
MANIFEST_PATH="$OUTPUT_DIR/unsigned-ipa-manifest.txt"
cat >"$MANIFEST_PATH" <<EOF
artifact=$OUTPUT_NAME
sha256=$SHA256
version=$APP_VERSION
build=$BUILD_NUMBER
main_bundle_id=$MAIN_BUNDLE_ID
widget_bundle_id=$WIDGET_BUNDLE_ID
architecture=arm64
signed=false
EOF

echo "==> 未签名 IPA 已生成"
echo "IPA: $PORTABLE_PATH"
echo "SHA-256: $SHA256"
echo "注意：必须用全能签同时重签 Runner.app、内嵌 Framework 与 ClaudeChatWidget.appex 后才能安装。"
