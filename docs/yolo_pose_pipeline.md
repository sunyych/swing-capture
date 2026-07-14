# YOLO Pose Pipeline

The first YOLO pose layer is source-agnostic:

1. A YOLO pose model produces one or more person candidates.
2. `YoloPoseDecoder` converts model output into `PoseCandidate[]`.
3. `TargetPoseSelector` chooses the hitter candidate.
4. The selected candidate becomes the existing single-person `PoseFrame`.
5. `PoseClipJsonService` writes the same `swingcapture.pose_skeleton_clip.v1`
   JSON, with optional source/selection metadata.

## Model

`YoloPoseDetectionService` looks for a TFLite model at:

```text
<app-documents>/models/yolo_pose.tflite
```

It can also materialize a bundled asset from:

```text
assets/models/yolo_pose.tflite
```

If the bundled asset path is used, add it to `pubspec.yaml` under `flutter.assets`.

## Output Format

The decoder supports common Ultralytics pose output layouts:

- candidate-first: `[1, N, 56]` or `[N, 56]`
- channel-first: `[1, 56, N]` or `[56, N]`

The default row format is:

```text
center_x, center_y, width, height, confidence, 17 * (x, y, confidence)
```

Coordinates may be normalized `[0, 1]` or pixel coordinates for a `640x640`
input. `YoloPoseDecoderConfig` can be adjusted for other input sizes,
thresholds, NMS, and `xyxy` box output.

## Landmark Mapping

The decoder maps COCO-17 keypoints into the existing `swingcapture_13` landmark
set:

```text
nose, shoulders, elbows, wrists, hips, knees, ankles
```

Eye and ear keypoints are intentionally ignored so downstream swing detectors
and pose JSON remain compatible.
