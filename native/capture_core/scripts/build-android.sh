#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: build-android.sh <android-ndk> <jni-output-dir> [debug|release]" >&2
  exit 64
fi

ndk_root="$1"
output_root="$2"
profile="${3:-release}"
crate_root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  Darwin) host_tag="darwin-x86_64" ;;
  Linux) host_tag="linux-x86_64" ;;
  *)
    echo "Unsupported Android NDK host: $(uname -s)" >&2
    exit 72
    ;;
esac
toolchain="$ndk_root/toolchains/llvm/prebuilt/$host_tag/bin"

if [[ -n "${CARGO:-}" ]]; then
  cargo_bin="$CARGO"
elif command -v cargo >/dev/null 2>&1; then
  cargo_bin="$(command -v cargo)"
elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  cargo_bin="$HOME/.cargo/bin/cargo"
else
  echo "Rust cargo was not found. Install rustup and the Android Rust targets first." >&2
  exit 69
fi

if [[ ! -d "$toolchain" ]]; then
  echo "Android NDK toolchain not found at $toolchain" >&2
  exit 72
fi

case "$profile" in
  debug)
    cargo_profile_args=()
    cargo_profile_dir="debug"
    ;;
  release)
    cargo_profile_args=(--release)
    cargo_profile_dir="release"
    ;;
  *)
    echo "profile must be debug or release" >&2
    exit 64
    ;;
esac

targets=(
  "arm64-v8a:aarch64-linux-android:aarch64-linux-android24-clang:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"
  "armeabi-v7a:armv7-linux-androideabi:armv7a-linux-androideabi24-clang:CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER"
  "x86_64:x86_64-linux-android:x86_64-linux-android24-clang:CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER"
)

for entry in "${targets[@]}"; do
  IFS=: read -r abi rust_target clang_name linker_env <<<"$entry"
  linker="$toolchain/$clang_name"
  if [[ ! -x "$linker" ]]; then
    echo "Android linker not found: $linker" >&2
    exit 72
  fi
  env "$linker_env=$linker" \
    "$cargo_bin" build \
      --manifest-path "$crate_root/Cargo.toml" \
      --target "$rust_target" \
      "${cargo_profile_args[@]}"
  mkdir -p "$output_root/$abi"
  cp "$crate_root/target/$rust_target/$cargo_profile_dir/libcapture_core.so" \
    "$output_root/$abi/libcapture_core.so"
done
