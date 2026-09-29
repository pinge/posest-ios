#!/usr/bin/env bash

# supports bash 3.2.57 on macos-26 runner.

set -euo pipefail

fail() {
  printf '❌ error: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

symbol_file_offset() {
  local binary="$1"
  local symbol="$2"
  local relative_offset="$3"
  local symbol_record
  local symbol_address
  local symbol_location
  local segment
  local section
  local section_record
  local section_address
  local section_offset

  symbol_record="$(xcrun nm -nm "$binary" | awk -v symbol="$symbol" '
    $NF == symbol {
      address = $1
      location = $2
      matches++
    }
    END {
      if (matches == 1) {
        print address, location
      } else {
        exit 1
      }
    }
  ')" || fail "expected one defined $symbol in $binary"
  read -r symbol_address symbol_location <<< "$symbol_record"
  segment="${symbol_location#(}"
  segment="${segment%%,*}"
  section="${symbol_location#*,}"
  section="${section%)}"

  section_record="$(xcrun otool -l "$binary" | awk -v expected_segment="$segment" -v expected_section="$section" '
    $1 == "Load" && $2 == "command" {
      in_section = 0
      next
    }
    $1 == "Section" {
      in_section = 1
      section = ""
      segment = ""
      address = ""
      next
    }
    in_section && $1 == "sectname" { section = $2 }
    in_section && $1 == "segname" { segment = $2 }
    in_section && $1 == "addr" { address = $2 }
    in_section && $1 == "offset" && section == expected_section && segment == expected_segment {
      print address, $2
      found++
    }
    END {
      if (found != 1) {
        exit 1
      }
    }
  ')" || fail "unable to locate $segment,$section in $binary"
  read -r section_address section_offset <<< "$section_record"

  symbol_address="${symbol_address#0x}"
  section_address="${section_address#0x}"
  printf '%d\n' "$((16#$symbol_address - 16#$section_address + section_offset + relative_offset))"
}

read_symbol_bytes() {
  local binary="$1"
  local relative_offset="$2"
  local byte_count="$3"
  local file_offset

  file_offset="$(symbol_file_offset "$binary" _LiteRtAcceleratorImpl "$relative_offset")"
  od -An -v -t x1 -j "$file_offset" -N "$byte_count" "$binary" | tr -d ' \n'
}

correct_metal_abi_header() {
  local binary="$1"
  local file_offset
  local outer_header
  local buffer_handlers_header

  outer_header="$(read_symbol_bytes "$binary" 0 8)"
  buffer_handlers_header="$(read_symbol_bytes "$binary" 64 8)"
  [[ "$outer_header" == c800010000000000 ]] || \
    fail "invalid LiteRtAcceleratorImpl ABI header in $binary: $outer_header"
  [[ "$buffer_handlers_header" == 0000000000000000 ]] || \
    fail "unexpected buffer-handlers ABI header in $binary: $buffer_handlers_header"

  file_offset="$(symbol_file_offset "$binary" _LiteRtAcceleratorImpl 64)"
  printf '\210\000\001\000\000\000\000\000' | \
    dd of="$binary" bs=1 seek="$file_offset" conv=notrunc 2>/dev/null
  buffer_handlers_header="$(read_symbol_bytes "$binary" 64 8)"
  [[ "$buffer_handlers_header" == 8800010000000000 ]] || \
    fail "failed to correct buffer-handlers ABI header in $binary"
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
  plutil -replace CFBundleShortVersionString -string 2.2.0 "$framework/Info.plist"
  for key in BuildMachineOSBuild DTCompiler DTPlatformBuild DTPlatformName DTPlatformVersion DTSDKBuild DTSDKName DTXcode DTXcodeBuild; do
    plutil -remove "$key" "$framework/Info.plist"
  done
  chmod 0644 "$framework/Info.plist"
  /usr/bin/codesign --remove-signature "$binary" >/dev/null 2>&1 || true
  correct_metal_abi_header "$binary"
  xcrun install_name_tool -id '@rpath/LiteRTMetalAccelerator.framework/LiteRTMetalAccelerator' "$binary"
  printf '%s\n' '#pragma once' > "$framework/Headers/LiteRTMetalAccelerator.h"
  printf '%s\n' \
    'framework module LiteRTMetalAccelerator {' \
    '  umbrella header "LiteRTMetalAccelerator.h"' \
    '  export *' \
    '}' \
    > "$framework/Modules/module.modulemap"
}

[[ "${LITERT_VERSION:-}" == '2.2.0' ]] || fail 'LITERT_VERSION must be 2.2.0'

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/../../.." && pwd)"
BUILD_OUTPUT_DIR="$REPOSITORY_ROOT/.build/litert-2.2.0-build"
ARTIFACT_DIR="$REPOSITORY_ROOT/.build/litert-2.2.0-artifacts-$(date +%Y%m%dT%H%M%S)"
CLITERT_XCFRAMEWORK_ZIP="$BUILD_OUTPUT_DIR/CLiteRT.xcframework.zip"
DEVICE_METAL_LIBRARY="$BUILD_OUTPUT_DIR/ios_arm64/libLiteRtMetalAccelerator.dylib"
SIMULATOR_METAL_LIBRARY="$BUILD_OUTPUT_DIR/ios_sim_arm64/libLiteRtMetalAccelerator.dylib"

assert_file "$CLITERT_XCFRAMEWORK_ZIP"
assert_file "$DEVICE_METAL_LIBRARY"
assert_file "$SIMULATOR_METAL_LIBRARY"

mkdir -p "$ARTIFACT_DIR"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'ARTIFACT_DIR=%s\n' "$ARTIFACT_DIR" >> "$GITHUB_ENV"
fi

unzip -q "$CLITERT_XCFRAMEWORK_ZIP" -d "$ARTIFACT_DIR"
DEVICE_CLITERT_PLIST="$ARTIFACT_DIR/CLiteRT.xcframework/ios-arm64/CLiteRT.framework/Info.plist"
SIMULATOR_CLITERT_PLIST="$ARTIFACT_DIR/CLiteRT.xcframework/ios-arm64-simulator/CLiteRT.framework/Info.plist"
assert_file "$DEVICE_CLITERT_PLIST"
assert_file "$SIMULATOR_CLITERT_PLIST"
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

# Google does not publish matching dSYMs for these prebuilt binaries.
xcodebuild -create-xcframework \
  -framework "$DEVICE_METAL_FRAMEWORK" \
  -framework "$SIMULATOR_METAL_FRAMEWORK" \
  -output "$ARTIFACT_DIR/LiteRTMetalAccelerator.xcframework"
ditto -c -k --sequesterRsrc --keepParent \
  "$ARTIFACT_DIR/LiteRTMetalAccelerator.xcframework" \
  "$ARTIFACT_DIR/LiteRTMetalAccelerator.xcframework.zip"

printf 'LiteRT 2.2.0 artifacts: %s\n' "$ARTIFACT_DIR"
