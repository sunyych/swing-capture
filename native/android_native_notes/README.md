# SwingCapture Android Native Notes

## Planned stack
- `CameraX` preview + analysis pipeline for device compatibility
- `MediaCodec` or rolling file segment strategy for clip buffering
- `ML Kit`, `MediaPipe`, or TFLite pose runtime behind a detector adapter
- `MediaStore` for gallery export and album categorization
- `FusedLocationProviderClient` for optional GPS metadata

## Flutter bridge responsibilities
- Host preview with `PlatformView` or texture-based surface
- Mirror the `swingcapture/capture` method contract from iOS
- Add `EventChannel` once detector telemetry is streamed back to Flutter

## MVP implementation notes
- Separate camera, inference, and export executors
- Downsample analysis frames for inference to reduce thermals
- Keep ring buffer memory bounded for long tripod sessions
- Prefer graceful degradation on mid-tier Android hardware
