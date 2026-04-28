# Pose Skeleton JSON Standard

`schema`: `swingcapture.pose_skeleton_clip.v1`

这个标准用于把每一次保存下来的 swing clip，和同时间窗的骨架序列一起落盘。它的目标是同时服务四件事：

1. 人工标注
2. swing detection 训练
3. swing quality / reward 学习
4. 小型 LLM 的教练建议输出

## 顶层结构

```json
{
  "schema": "swingcapture.pose_skeleton_clip.v1",
  "schemaVersion": 1,
  "createdAt": "2026-04-20T06:30:00.000Z",
  "capture": {},
  "event": {},
  "frames": []
}
```

## `capture`

描述这段数据是如何采集到的。

```json
{
  "clipId": "1745130000000000",
  "videoPath": "/.../swing_1745130000000000.mp4",
  "capturePipeline": "flutter_camera_buffer",
  "cameraFacing": "back",
  "normalization": "preview_normalized_xy",
  "landmarkSet": "swingcapture_13",
  "landmarkOrder": [
    "nose",
    "leftShoulder",
    "rightShoulder",
    "leftElbow",
    "rightElbow",
    "leftWrist",
    "rightWrist",
    "leftHip",
    "rightHip",
    "leftKnee",
    "rightKnee",
    "leftAnkle",
    "rightAnkle"
  ],
  "bones": [
    { "from": "leftShoulder", "to": "rightShoulder" }
  ]
}
```

说明：

- `capturePipeline`
  - `flutter_camera_buffer`
  - `native_android_buffer`
- `cameraFacing`
  - `front`
  - `back`
  - `external`
  - `unknown`
- `normalization`
  - 当前是预览坐标归一化，`x/y` 范围通常在 `[0, 1]`

## `event`

描述触发这段 clip 的动作事件和时间窗。

```json
{
  "label": "baseball_swing",
  "category": "sports",
  "triggeredAt": "2026-04-20T06:30:02.340Z",
  "score": 0.8123,
  "reason": "cross_body: ...",
  "preRollMs": 2000,
  "postRollMs": 2000,
  "requestedWindowStartAt": "2026-04-20T06:30:00.340Z",
  "requestedWindowEndAt": "2026-04-20T06:30:04.340Z",
  "clipStartAt": "2026-04-20T06:30:00.500Z",
  "clipEndAt": "2026-04-20T06:30:04.180Z",
  "durationMs": 3680
}
```

说明：

- `requestedWindow*` 是 detector 想要的窗口
- `clipStartAt` / `clipEndAt` 是实际保存下来的窗口
- 后续训练要用实际窗口

## `frames`

`frames` 是按时间排序的骨架序列。

```json
{
  "index": 0,
  "timestamp": "2026-04-20T06:30:00.500Z",
  "offsetMs": 0,
  "complete": 0.8333,
  "hasPose": true,
  "lmCount": 13,
  "lm": {
    "leftShoulder": {
      "x": 0.5231,
      "y": 0.4188,
      "confidence": 0.9921
    }
  }
}
```

字段含义：

- `index`: clip 内帧序号
- `timestamp`: 绝对 UTC 时间
- `offsetMs`: 相对 `clipStartAt` 的毫秒偏移
- `complete`: 这个 frame 的骨架完整度
- `hasPose`: 当前帧是否存在有效骨架
- `lmCount`: 当前帧 landmark 数
- `lm`: landmark 明细

## 建议的人工标注维度

至少标这几类：

1. `detectionLabel`
   - `baseball_swing`
   - `other`
2. `view`
   - `front`
   - `back`
3. `qualityScores`
   - `setup`
   - `load`
   - `rotation`
   - `contact`
   - `finish`
4. `issues`
   - 例如 `early_hip_open`
   - `hands_cast`
   - `head_drift`
   - `finish_off_balance`
5. `coachSummary`
   - 人工写的一小段教练反馈

## 为什么这个标准适合后续学习

- 做 detection：直接把 `frames` 当时间序列输入
- 做 reward / ranking：配合人工质量分和 pairwise preference
- 做 LLM：把 `event + frames summary + issues` 组成结构化 prompt
- 做多视角分析：`cameraFacing + view` 可以显式建模正面/背面差异
