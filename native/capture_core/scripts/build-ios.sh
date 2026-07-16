#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: build-ios.sh <sdk-name> <archs> <configuration> <output-dir>" >&2
  exit 64
fi

sdk_name="$1"
archs="$2"
configuration="$3"
output_dir="$4"
crate_root="$(cd "$(dirname "$0")/.." && pwd)"
target_dir="${CARGO_TARGET_DIR:-$crate_root/target}"

if command -v cargo >/dev/null 2>&1; then
  cargo_bin="$(command -v cargo)"
elif [[ -x "${HOME:-}/.cargo/bin/cargo" ]]; then
  cargo_bin="${HOME}/.cargo/bin/cargo"
else
  echo "Rust cargo was not found." >&2
  exit 69
fi

case "$configuration" in
  Release|Profile)
    release_build=1
    profile_dir="release"
    ;;
  *)
    release_build=0
    profile_dir="debug"
    ;;
esac

libraries=()
for arch in $archs; do
  case "$sdk_name:$arch" in
    iphoneos*:arm64) rust_target="aarch64-apple-ios" ;;
    iphonesimulator*:arm64) rust_target="aarch64-apple-ios-sim" ;;
    iphonesimulator*:x86_64) rust_target="x86_64-apple-ios" ;;
    *)
      echo "Unsupported iOS Rust target: sdk=$sdk_name arch=$arch" >&2
      exit 72
      ;;
  esac

  if [[ "$release_build" -eq 1 ]]; then
    "$cargo_bin" build \
      --manifest-path "$crate_root/Cargo.toml" \
      --target "$rust_target" \
      --release
  else
    "$cargo_bin" build \
      --manifest-path "$crate_root/Cargo.toml" \
      --target "$rust_target"
  fi
  libraries+=("$target_dir/$rust_target/$profile_dir/libcapture_core.a")
done

mkdir -p "$output_dir"
if [[ ${#libraries[@]} -eq 1 ]]; then
  cp "${libraries[0]}" "$output_dir/libcapture_core.a"
else
  xcrun lipo -create "${libraries[@]}" -output "$output_dir/libcapture_core.a"
fi
