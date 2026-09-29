#!/usr/bin/env bash

# supports bash 3.2.57 on macos-26 runner.

set -euo pipefail

fail() {
  printf '❌ error: %s\n' "$*" >&2
  exit 1
}

make_metal_framework() {
  local source_library="$1"
  local source_plist="$2"
  local framework="$3"
  local binary="$framework/LiteRTMetalAccelerator"
  local key

  mkdir -p "$framework/Headers" "$framework/Modules"
  install -m 0755 "$source_library" "$binary"
  cp "$source_plist" "$framework/Info.plist"
  plutil -replace CFBundleExecutable -string LiteRTMetalAccelerator "$framework/Info.plist"
  plutil -replace CFBundleIdentifier -string com.google.odml.litert.LiteRTMetalAccelerator "$framework/Info.plist"
  plutil -replace CFBundleName -string LiteRTMetalAccelerator "$framework/Info.plist"
  plutil -replace CFBundleShortVersionString -string 2.1.6 "$framework/Info.plist"
  for key in BuildMachineOSBuild DTCompiler DTPlatformBuild DTPlatformName DTPlatformVersion DTSDKBuild DTSDKName DTXcode DTXcodeBuild; do
    plutil -remove "$key" "$framework/Info.plist"
  done
  chmod 0644 "$framework/Info.plist"
  /usr/bin/codesign --remove-signature "$binary" >/dev/null 2>&1 || true
  xcrun install_name_tool -id '@rpath/LiteRTMetalAccelerator.framework/LiteRTMetalAccelerator' "$binary"
  printf '%s\n' '#pragma once' > "$framework/Headers/LiteRTMetalAccelerator.h"
  printf '%s\n' \
    'framework module LiteRTMetalAccelerator {' \
    '  umbrella header "LiteRTMetalAccelerator.h"' \
    '  export *' \
    '}' \
    > "$framework/Modules/module.modulemap"
}

[[ "${LITERT_VERSION:-}" == '2.1.6' ]] || fail 'LITERT_VERSION must be 2.1.6'
LITERT_SOURCE_DIR="${LITERT_SOURCE_DIR:?LITERT_SOURCE_DIR is required}"
[[ -d "$LITERT_SOURCE_DIR/.git" ]] || fail "LiteRT checkout not found: $LITERT_SOURCE_DIR"

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/../../.." && pwd)"
ARTIFACT_DIR="$REPOSITORY_ROOT/.build/litert-2.1.6-artifacts-$(date +%Y%m%dT%H%M%S)"
CLITERT_XCFRAMEWORK_ZIP="$LITERT_SOURCE_DIR/bazel-bin/litert/swift/CLiteRT.xcframework.zip"
DEVICE_METAL_LIBRARY="$LITERT_SOURCE_DIR/litert/prebuilt/ios_arm64/libLiteRtMetalAccelerator.dylib"
SIMULATOR_METAL_LIBRARY="$LITERT_SOURCE_DIR/litert/prebuilt/ios_sim_arm64/libLiteRtMetalAccelerator.dylib"

[[ -f "$CLITERT_XCFRAMEWORK_ZIP" ]] || fail "missing file: $CLITERT_XCFRAMEWORK_ZIP"
[[ -f "$DEVICE_METAL_LIBRARY" ]] || fail "missing file: $DEVICE_METAL_LIBRARY"
[[ -f "$SIMULATOR_METAL_LIBRARY" ]] || fail "missing file: $SIMULATOR_METAL_LIBRARY"

mkdir -p "$ARTIFACT_DIR"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'ARTIFACT_DIR=%s\n' "$ARTIFACT_DIR" >> "$GITHUB_ENV"
fi

unzip -q "$CLITERT_XCFRAMEWORK_ZIP" -d "$ARTIFACT_DIR"
DEVICE_CLITERT_PLIST="$ARTIFACT_DIR/CLiteRT.xcframework/ios-arm64/CLiteRT.framework/Info.plist"
SIMULATOR_CLITERT_PLIST="$ARTIFACT_DIR/CLiteRT.xcframework/ios-arm64-simulator/CLiteRT.framework/Info.plist"
IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$DEVICE_CLITERT_PLIST"
plutil -replace DTPlatformName -string iphoneos "$DEVICE_CLITERT_PLIST"
plutil -replace DTSDKName -string "iphoneos${IOS_SDK_VERSION}" "$DEVICE_CLITERT_PLIST"
ditto -c -k --sequesterRsrc --keepParent \
  "$ARTIFACT_DIR/CLiteRT.xcframework" \
  "$ARTIFACT_DIR/CLiteRT.xcframework.zip"

DEVICE_METAL_FRAMEWORK="$ARTIFACT_DIR/ios-arm64/LiteRTMetalAccelerator.framework"
SIMULATOR_METAL_FRAMEWORK="$ARTIFACT_DIR/ios-arm64-simulator/LiteRTMetalAccelerator.framework"
make_metal_framework "$DEVICE_METAL_LIBRARY" "$DEVICE_CLITERT_PLIST" "$DEVICE_METAL_FRAMEWORK"
make_metal_framework "$SIMULATOR_METAL_LIBRARY" "$SIMULATOR_CLITERT_PLIST" "$SIMULATOR_METAL_FRAMEWORK"

xcodebuild -create-xcframework \
  -framework "$DEVICE_METAL_FRAMEWORK" \
  -framework "$SIMULATOR_METAL_FRAMEWORK" \
  -output "$ARTIFACT_DIR/LiteRTMetalAccelerator.xcframework"
ditto -c -k --sequesterRsrc --keepParent \
  "$ARTIFACT_DIR/LiteRTMetalAccelerator.xcframework" \
  "$ARTIFACT_DIR/LiteRTMetalAccelerator.xcframework.zip"

printf 'LiteRT 2.1.6 artifacts: %s\n' "$ARTIFACT_DIR"
