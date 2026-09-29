#!/usr/bin/env bash

# supports bash 3.2.57 on macos-26 runner.

set -euo pipefail

usage() {
  printf 'usage: %s <artifact-directory>\n' "${0##*/}" >&2
  exit 2
}

fail() {
  printf '❌ error: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local value="$1"
  local expected="$2"
  local description="$3"

  if [[ "$value" != "$expected" ]]; then
    fail "invalid $description: expected <$expected>, got <$value>"
  fi
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_directory() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}

normalize_words() {
  tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd ' ' -
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print $2" "$1"
}

plist_array_values() {
  local plist="$1"
  local key="$2"
  local index=0
  local value

  while value="$(plist_value "$plist" "$key:$index" 2>/dev/null)"; do
    printf '%s\n' "$value"
    index=$((index + 1))
  done
}

manifest_indexes() {
  local plist="$1"
  local expected_identifier="$2"
  local index=0
  local identifier

  while identifier="$(plist_value "$plist" ":AvailableLibraries:$index:LibraryIdentifier" 2>/dev/null)"; do
    if [[ "$identifier" == "$expected_identifier" ]]; then
      printf '%s\n' "$index"
    fi
    index=$((index + 1))
  done
}

validate_manifest_entry() {
  local xcframework="$1"
  local module="$2"
  local identifier="$3"
  local expected_variant="$4"
  local plist="$xcframework/Info.plist"
  local indexes
  local index
  local key
  local binary_path

  indexes="$(manifest_indexes "$plist" "$identifier")"
  [[ "$indexes" =~ ^[0-9]+$ ]] || fail "expected one manifest entry for $identifier, got indexes <$indexes>"
  index="$indexes"
  key=":AvailableLibraries:$index"

  assert_equal "$(plist_value "$plist" "$key:LibraryPath")" "$module.framework" "$identifier LibraryPath"
  assert_equal "$(plist_value "$plist" "$key:SupportedPlatform")" ios "$identifier SupportedPlatform"
  assert_equal "$(plist_array_values "$plist" "$key:SupportedArchitectures" | normalize_words)" arm64 "$identifier architectures"

  if [[ -n "$expected_variant" ]]; then
    assert_equal "$(plist_value "$plist" "$key:SupportedPlatformVariant")" "$expected_variant" "$identifier platform variant"
  elif plist_value "$plist" "$key:SupportedPlatformVariant" >/dev/null 2>&1; then
    fail "unexpected SupportedPlatformVariant in $identifier manifest entry"
  fi

  if plist_value "$plist" "$key:BinaryPath" >/dev/null 2>&1; then
    binary_path="$(plist_value "$plist" "$key:BinaryPath")"
    assert_equal "$binary_path" "$module.framework/$module" "$identifier BinaryPath"
  fi
}

validate_xcframework_manifest() {
  local xcframework="$1"
  local module="$2"
  local plist="$xcframework/Info.plist"

  assert_file "$plist"
  plutil -lint "$plist" >/dev/null
  assert_equal "$(plist_value "$plist" :CFBundlePackageType)" XFWK "$module XCFramework package type"
  assert_equal "$(plist_value "$plist" :XCFrameworkFormatVersion)" 1.0 "$module XCFramework format version"
  validate_manifest_entry "$xcframework" "$module" ios-arm64 ''
  validate_manifest_entry "$xcframework" "$module" ios-arm64-simulator simulator

  plist_value "$plist" :AvailableLibraries:0:LibraryIdentifier >/dev/null 2>&1 || fail "$module manifest has no libraries"
  plist_value "$plist" :AvailableLibraries:1:LibraryIdentifier >/dev/null 2>&1 || fail "$module manifest has only one library"
  if plist_value "$plist" :AvailableLibraries:2:LibraryIdentifier >/dev/null 2>&1; then
    fail "$module manifest contains unexpected additional libraries"
  fi
}

validate_module() {
  local framework="$1"
  local module="$2"
  local module_map="$framework/Modules/module.modulemap"
  local umbrella_header="$module.h"

  assert_file "$framework/Headers/$umbrella_header"
  assert_file "$module_map"
  awk -v module="$module" '
    $1 == "framework" && $2 == "module" && $3 == module { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$module_map" || fail "$module_map does not declare framework module $module"
  awk -v header="\"$umbrella_header\"" '
    $1 == "umbrella" && $2 == "header" && $3 == header { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$module_map" || fail "$module_map does not use umbrella header $umbrella_header"
}

validate_framework_plist() {
  local plist="$1"
  local module="$2"
  local bundle_identifier="$3"
  local short_version="$4"
  local supported_platform="$5"
  local expected_minimum_os="$6"
  local supported_platforms

  assert_file "$plist"
  plutil -lint "$plist" >/dev/null
  assert_equal "$(plist_value "$plist" :CFBundleExecutable)" "$module" "$plist executable"
  assert_equal "$(plist_value "$plist" :CFBundleIdentifier)" "$bundle_identifier" "$plist bundle identifier"
  assert_equal "$(plist_value "$plist" :CFBundlePackageType)" FMWK "$plist package type"
  assert_equal "$(plist_value "$plist" :CFBundleShortVersionString)" "$short_version" "$plist release version"
  assert_equal "$(plist_value "$plist" :CFBundleVersion)" 1 "$plist build version"
  assert_equal "$(plist_value "$plist" :MinimumOSVersion)" "$expected_minimum_os" "$plist minimum OS"
  supported_platforms="$(plist_array_values "$plist" :CFBundleSupportedPlatforms | paste -sd ' ' -)"
  assert_equal "$supported_platforms" "$supported_platform" "$plist supported platforms"
}

validate_clitert_build_metadata() {
  local plist="$1"
  local expected_platform="$2"
  local expected_sdk_prefix="$3"
  local sdk_name

  assert_equal "$(plist_value "$plist" :DTPlatformName)" "$expected_platform" "$plist DTPlatformName"
  sdk_name="$(plist_value "$plist" :DTSDKName)"
  [[ "$sdk_name" == "$expected_sdk_prefix"* ]] || fail "invalid $plist DTSDKName: expected prefix <$expected_sdk_prefix>, got <$sdk_name>"
}

validate_metal_build_metadata_removed() {
  local plist="$1"
  local key

  for key in BuildMachineOSBuild DTCompiler DTPlatformBuild DTPlatformName DTPlatformVersion DTSDKBuild DTSDKName DTXcode DTXcodeBuild; do
    if plist_value "$plist" ":$key" >/dev/null 2>&1; then
      fail "$plist contains copied build metadata key $key"
    fi
  done
}

validate_binary() {
  local binary="$1"
  local module="$2"
  local expected_platform="$3"
  local expected_minimum_os="$4"
  local required_symbol="$5"
  local binary_platform
  local minimum_os
  local install_name
  local dependencies
  local symbols

  assert_file "$binary"
  assert_equal "$(xcrun lipo -archs "$binary" | normalize_words)" arm64 "$binary architectures"
  binary_platform="$(xcrun vtool -show-build "$binary" | awk '$1 == "platform" { print tolower($2) }' | sort -u | paste -sd ' ' -)"
  assert_equal "$binary_platform" "$expected_platform" "$binary platform"
  minimum_os="$(xcrun vtool -show-build "$binary" | awk '$1 == "minos" { print $2 }' | sort -u | paste -sd ' ' -)"
  assert_equal "$minimum_os" "$expected_minimum_os" "$binary minimum OS"

  install_name="$(xcrun otool -D "$binary" | awk '
    /^[^[:space:]].*:$/ { next }
    NF {
      install_name = $0
      sub(/^[[:space:]]+/, "", install_name)
      print install_name
    }
  ' | sort -u | paste -sd ' ' -)"
  assert_equal "$install_name" "@rpath/$module.framework/$module" "$binary install name"

  dependencies="$(xcrun otool -L "$binary" | awk -v install_name="@rpath/$module.framework/$module" '
    /^[[:space:]]/ {
      dependency = $1
      if (dependency != install_name &&
          dependency !~ "^/System/Library/" &&
          dependency !~ "^/usr/lib/" &&
          dependency !~ "^@rpath/libswift.*\\.dylib$") print dependency
    }
  ' | sort -u)"
  [[ -z "$dependencies" ]] || fail "$binary has unexpected non-system dependencies: $dependencies"

  symbols="$(xcrun nm -gjU "$binary")"
  awk -v required="$required_symbol" '
    $0 == required { found = 1 }
    END { exit found ? 0 : 1 }
  ' <<< "$symbols" || fail "$binary does not export $required_symbol"
}

validate_artifact() {
  local xcframework="$1"
  local module="$2"
  local bundle_identifier="$3"
  local short_version="$4"
  local required_symbol="$5"
  local device_framework="$xcframework/ios-arm64/$module.framework"
  local simulator_framework="$xcframework/ios-arm64-simulator/$module.framework"
  local loose_dylibs

  assert_directory "$xcframework"
  validate_xcframework_manifest "$xcframework" "$module"

  assert_directory "$device_framework"
  assert_directory "$simulator_framework"
  validate_module "$device_framework" "$module"
  validate_module "$simulator_framework" "$module"
  validate_framework_plist "$device_framework/Info.plist" "$module" "$bundle_identifier" "$short_version" iPhoneOS 15.0
  validate_framework_plist "$simulator_framework/Info.plist" "$module" "$bundle_identifier" "$short_version" iPhoneSimulator 15.0
  validate_binary "$device_framework/$module" "$module" ios 15.0 "$required_symbol"
  validate_binary "$simulator_framework/$module" "$module" iossimulator 15.0 "$required_symbol"

  cmp -s "$device_framework/Info.plist" "$simulator_framework/Info.plist" && fail "$module device and Simulator plists are identical"
  loose_dylibs="$(find "$xcframework" -type f -name '*.dylib' -print)"
  [[ -z "$loose_dylibs" ]] || fail "$xcframework contains standalone dylibs: $loose_dylibs"
}

validate_zip() {
  local zip="$1"
  local module="$2"
  local contents
  local roots
  local expected_root="$module.xcframework"
  local relative_path
  local local_file
  local local_hash
  local zip_hash

  assert_file "$zip"
  contents="$(zipinfo -1 "$zip")"
  roots="$(awk -F/ 'NF && $1 != "__MACOSX" { print $1 }' <<< "$contents" | sort -u)"
  assert_equal "$roots" "$expected_root" "$zip top-level payload"
  awk -v expected="$expected_root/Info.plist" '
    $0 == expected { found = 1 }
    END { exit found ? 0 : 1 }
  ' <<< "$contents" || fail "$zip does not contain $expected_root/Info.plist"
  awk '
    /\.dylib$/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' <<< "$contents" && fail "$zip contains a standalone dylib"

  for relative_path in \
    "$expected_root/Info.plist" \
    "$expected_root/ios-arm64/$module.framework/$module" \
    "$expected_root/ios-arm64/$module.framework/Info.plist" \
    "$expected_root/ios-arm64/$module.framework/Headers/$module.h" \
    "$expected_root/ios-arm64/$module.framework/Modules/module.modulemap" \
    "$expected_root/ios-arm64-simulator/$module.framework/$module" \
    "$expected_root/ios-arm64-simulator/$module.framework/Info.plist" \
    "$expected_root/ios-arm64-simulator/$module.framework/Headers/$module.h" \
    "$expected_root/ios-arm64-simulator/$module.framework/Modules/module.modulemap"; do
    local_file="$artifact_directory/$relative_path"
    local_hash="$(shasum -a 256 "$local_file" | awk '{ print $1 }')"
    zip_hash="$(unzip -p "$zip" "$relative_path" | shasum -a 256 | awk '{ print $1 }')"
    assert_equal "$zip_hash" "$local_hash" "$zip packaged $relative_path"
  done
}

[[ $# -eq 1 ]] || usage

artifact_directory="${1%/}"
litert_version='2.1.6'
[[ -n "$artifact_directory" ]] || usage
assert_directory "$artifact_directory"

clitert="$artifact_directory/CLiteRT.xcframework"
metal="$artifact_directory/LiteRTMetalAccelerator.xcframework"

validate_artifact "$clitert" CLiteRT com.google.odml.litert.CLiteRT 1.0 _LiteRtStaticLinkedAcceleratorGpuDef
validate_clitert_build_metadata "$clitert/ios-arm64/CLiteRT.framework/Info.plist" iphoneos iphoneos
validate_clitert_build_metadata "$clitert/ios-arm64-simulator/CLiteRT.framework/Info.plist" iphonesimulator iphonesimulator

validate_artifact "$metal" LiteRTMetalAccelerator com.google.odml.litert.LiteRTMetalAccelerator "$litert_version" _LiteRtAcceleratorImpl
validate_metal_build_metadata_removed "$metal/ios-arm64/LiteRTMetalAccelerator.framework/Info.plist"
validate_metal_build_metadata_removed "$metal/ios-arm64-simulator/LiteRTMetalAccelerator.framework/Info.plist"

validate_zip "$artifact_directory/CLiteRT.xcframework.zip" CLiteRT
validate_zip "$artifact_directory/LiteRTMetalAccelerator.xcframework.zip" LiteRTMetalAccelerator

printf '✅ LiteRT %s XCFrameworks in %s\n' "$litert_version" "$artifact_directory"
