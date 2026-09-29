#!/usr/bin/env bash

# supports bash 3.2.57 on macos-26 runner.

set -euo pipefail

fail() {
  printf '❌ error: %s\n' "$*" >&2
  exit 1
}

assert_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

[[ "${LITERT_VERSION:-}" == '2.1.6' ]] || fail 'LITERT_VERSION must be 2.1.6'
LITERT_SOURCE_DIR="${LITERT_SOURCE_DIR:?LITERT_SOURCE_DIR is required}"
[[ -d "$LITERT_SOURCE_DIR/.git" ]] || fail "LiteRT checkout not found: $LITERT_SOURCE_DIR"

for required_command in bazel du file git git-lfs ls; do
  assert_command "$required_command"
done

[[ "$(git -C "$LITERT_SOURCE_DIR" describe --tags --exact-match HEAD)" == 'v2.1.6' ]] || \
  fail 'LiteRT checkout must be at tag v2.1.6'

cd "$LITERT_SOURCE_DIR"

git lfs install --local
git lfs pull \
  --include='litert/prebuilt/ios_arm64/libLiteRtMetalAccelerator.dylib,litert/prebuilt/ios_sim_arm64/libLiteRtMetalAccelerator.dylib'

DEVICE_METAL_LIBRARY='litert/prebuilt/ios_arm64/libLiteRtMetalAccelerator.dylib'
SIMULATOR_METAL_LIBRARY='litert/prebuilt/ios_sim_arm64/libLiteRtMetalAccelerator.dylib'
[[ -f "$DEVICE_METAL_LIBRARY" ]] || fail "missing file: $DEVICE_METAL_LIBRARY"
[[ -f "$SIMULATOR_METAL_LIBRARY" ]] || fail "missing file: $SIMULATOR_METAL_LIBRARY"
ls -lh "$DEVICE_METAL_LIBRARY" "$SIMULATOR_METAL_LIBRARY"
file "$DEVICE_METAL_LIBRARY" "$SIMULATOR_METAL_LIBRARY"

bazel version
BAZEL_VERSION="$(bazel --version)"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'BAZEL_VERSION=%s\n' "$BAZEL_VERSION" >> "$GITHUB_ENV"
fi

du -sh "$(bazel info output_base)" || true
bazel build -c opt //litert/swift:CLiteRT
du -sh "$(bazel info output_base)"

CLITERT_XCFRAMEWORK_ZIP="$LITERT_SOURCE_DIR/bazel-bin/litert/swift/CLiteRT.xcframework.zip"
[[ -f "$CLITERT_XCFRAMEWORK_ZIP" ]] || fail "missing file: $CLITERT_XCFRAMEWORK_ZIP"
