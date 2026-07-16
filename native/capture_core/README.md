# capture_core

`capture_core` owns the encoded rolling-buffer hot path shared by the native
camera implementations. Android feeds direct `MediaCodec` output buffers through
JNI; iOS feeds VideoToolbox H.265/H.264 output through the C ABI.

The ring allocates its byte arena and metadata slots when capture starts. `push`
only copies into those fixed allocations. Clip snapshots are created off the hot
path, begin at a keyframe, and are muxed by the platform container writer.

Host tests:

```sh
cargo test --manifest-path native/capture_core/Cargo.toml
```

Android builds require the `aarch64-linux-android`, `armv7-linux-androideabi`,
and `x86_64-linux-android` Rust targets. Gradle invokes
`scripts/build-android.sh` before merging native libraries.

iOS builds require `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and
`x86_64-apple-ios`. Xcode invokes `scripts/build-ios.sh` and links the resulting
static library into the Runner target.
