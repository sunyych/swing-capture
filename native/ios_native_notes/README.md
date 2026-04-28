# SwingCapture iOS Native Notes

## Planned stack
- `AVFoundation` for preview + recording pipeline
- `AVAssetWriter` or segmented file strategy for ring buffer implementation
- `Vision` / `Core ML` bridge for pose inference if using an iOS-native runtime
- `Photos` framework for album creation and save/export
- `CoreLocation` for optional GPS metadata

## Flutter bridge responsibilities
- Host the preview in a `FlutterPlatformView`
- Expose `MethodChannel("swingcapture/capture")`
- Emit detection state and debug landmarks later via `EventChannel`

## MVP implementation notes
- Keep preview, encode, and inference on separate queues
- Sample inference at ~10-15 FPS instead of every frame
- Lock long lens when available, otherwise degrade to wide lens cleanly
- Preserve pre-roll by maintaining a rolling compressed segment buffer
