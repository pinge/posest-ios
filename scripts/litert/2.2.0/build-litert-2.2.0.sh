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

download_metal_library() {
  local platform="$1"
  local expected_sha256="$2"
  local destination="$BUILD_OUTPUT_DIR/$platform/libLiteRtMetalAccelerator.dylib"
  local url="https://media.githubusercontent.com/media/google-ai-edge/LiteRT/$METAL_COMMIT/litert/prebuilt/$platform/libLiteRtMetalAccelerator.dylib"
  local sha256

  mkdir -p "${destination%/*}"
  curl --fail --location --retry 3 --output "$destination" "$url"
  sha256="$(shasum -a 256 "$destination" | awk '{ print $1 }')"
  [[ "$sha256" == "$expected_sha256" ]] || \
    fail "invalid SHA-256 for $destination: expected $expected_sha256, got $sha256"
}

[[ "${LITERT_VERSION:-}" == '2.2.0' ]] || fail 'LITERT_VERSION must be 2.2.0'
LITERT_SOURCE_DIR="${LITERT_SOURCE_DIR:?LITERT_SOURCE_DIR is required}"
[[ -d "$LITERT_SOURCE_DIR/.git" ]] || fail "LiteRT checkout not found: $LITERT_SOURCE_DIR"

for required_command in awk bazel curl git shasum; do
  assert_command "$required_command"
done

source_tag="$(git -C "$LITERT_SOURCE_DIR" describe --tags --exact-match HEAD)"
[[ "$source_tag" == 'v2.2.0' ]] || fail "expected LiteRT tag v2.2.0, got $source_tag"

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/../../.." && pwd)"
BUILD_OUTPUT_DIR="$REPOSITORY_ROOT/.build/litert-2.2.0-build"
# The v2.2.0 tag predates Google's Metal refresh with the v2.2.0 outer accelerator ABI.
METAL_COMMIT='c967bb4cd3253ae3e9e62f43ee66006e26966b25'
DEVICE_METAL_SHA256='d869c4677ce15001281989845e11164e223622ce63c05dfd9a9f159e5201b490'
SIMULATOR_METAL_SHA256='2c18c6a375918ea6ab8b396593bc0e2103875b26b8a8e821ed8f147bd9ecda72'
[[ ! -e "$BUILD_OUTPUT_DIR" ]] || fail "build output already exists: $BUILD_OUTPUT_DIR"
mkdir -p "$BUILD_OUTPUT_DIR"

download_metal_library ios_arm64 "$DEVICE_METAL_SHA256"
download_metal_library ios_sim_arm64 "$SIMULATOR_METAL_SHA256"

cd "$LITERT_SOURCE_DIR"
bazel version
BAZEL_VERSION="$(bazel --version)"
du -sh "$(bazel info output_base)" || true

bazel build -c opt //litert/swift:CLiteRT
CLITERT_XCFRAMEWORK_ZIP="$BUILD_OUTPUT_DIR/CLiteRT.xcframework.zip"
cp "$LITERT_SOURCE_DIR/bazel-bin/litert/swift/CLiteRT.xcframework.zip" "$CLITERT_XCFRAMEWORK_ZIP"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'BAZEL_VERSION=%s\n' "$BAZEL_VERSION" >> "$GITHUB_ENV"
  printf 'LITERT_METAL_COMMIT=%s\n' "$METAL_COMMIT" >> "$GITHUB_ENV"
fi

du -sh "$(bazel info output_base)" "$BUILD_OUTPUT_DIR"
printf 'CLiteRT XCFramework: %s\n' "$CLITERT_XCFRAMEWORK_ZIP"
printf 'Metal device dylib: %s\n' "$BUILD_OUTPUT_DIR/ios_arm64/libLiteRtMetalAccelerator.dylib"
printf 'Metal Simulator dylib: %s\n' "$BUILD_OUTPUT_DIR/ios_sim_arm64/libLiteRtMetalAccelerator.dylib"
