# Swing Review And Training

更完整的训练说明见：

- [docs/README_模型训练.md](/Users/ssun/Projects/SwingCapture/docs/README_模型训练.md)

这条链路现在支持三件事：

1. 一次多选多个 swing 视频并批量提取 pose JSON
2. 启动一个网页版标注台，按视频分组快速切换和标注
3. 把标注结果转成 detector / quality / reward / 小型教练模型训练数据

## 1. 安装依赖

```bash
python3 -m venv .venv-pose
source .venv-pose/bin/activate
pip install -r scripts/requirements-pose.txt
pip install -r scripts/requirements-train.txt
```

如果要训练小型文本模型，再额外安装：

```bash
pip install -r scripts/requirements-llm-train.txt
```

## 2. 批量读取多个短视频到 pose JSON

保留现有 `extract_pose_from_video.py` 的 JSON / CSV 输出格式不变，只是新增了批量入口：

```bash
python3 scripts/batch_extract_pose_from_videos.py \
  --select \
  --out-dir artifacts/pose \
  --skip-existing
```

也可以直接传多个文件：

```bash
python3 scripts/batch_extract_pose_from_videos.py \
  /path/to/swing_01.mp4 \
  /path/to/swing_02.mp4 \
  /path/to/swing_03.mp4 \
  --out-dir artifacts/pose
```

输出：

- `*.pose.json`
- `*.features.csv`
- `batch_extract_manifest.json`

## 3. 启动网页版 swing 标注工具

仓库里本来就有网页标注工具，这次已经升级成：

- 支持一次选多个视频
- 自动提取 pose 并生成一个共享 review workspace
- 支持上一条 / 下一条
- 支持上一组视频 / 下一组视频
- 支持只看当前视频候选，或者看全部候选
- 支持保存视角、质量分、问题标签、教练总结

### 一条命令启动

```bash
python3 scripts/launch_swing_review.py \
  --select \
  --task-name "Baseball Swing Review" \
  --positive-label baseball_swing \
  --negative-label other \
  --review-dir artifacts/review/baseball_batch_review \
  --skip-existing
```

如果这台机器暂时跑不了 MediaPipe pose，但 `artifacts/pose/` 里已经有一部分 `*.pose.json` 和 `*.features.csv`，可以只复用已有结果、跳过缺失项：

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --reuse-existing-pose-only
```

现在 review workspace 会在每个 source 完成后立即保存；如果中途 `Ctrl+C`，下次重跑会自动复用已经完成的 source，不会从头全部重算。

如果你希望缺少 pose 的新视频也先出现在 review 里，方便直接人工二分类，可以再加上：

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --reuse-existing-pose-only \
  --include-missing-pose-videos
```

这会把没有 `*.pose.json` / `*.features.csv` 的视频作为 `raw review` 候选加入标注页。它们可以人工标注，但预测、训练和学习集导出会自动跳过这类无特征样本。

前端里现在可以直接筛选这类候选：

- 桌面标注页：侧栏点击 `只看 raw review`
- 复核页：筛选框选择 `仅 raw review`
- 移动页：打开 `http://127.0.0.1:8765/mobile_label.html?mode=raw`

然后打开：

```text
http://127.0.0.1:8765
```

手机快速标注可以打开：

```text
http://127.0.0.1:8765/mobile_label.html
```

移动标注页只保留底部两个按钮：`baseball_swing` 和 `other`。在视频区域上下滑切换上一条 / 下一条候选片段，左右滑切换上一组 / 下一组来源视频。

### 快捷键

- `A`: 标成负样本 / other
- `S`: 标成 skip
- `D`: 标成正样本 / swing
- `← / →`: 上一条 / 下一条
- `[` / `]`: 上一组视频 / 下一组视频

## 4. 用现有模型生成可信度复核列表

如果已经有一个训练好的 `action_csv_classifier.joblib`，可以先让模型给所有候选片段写入预测建议和 `baseball_swing` 概率，再由你人工决定哪些是 swing、哪些不是。

```bash
python3 scripts/predict_action_csv_classifier.py \
  --model-path artifacts/models/swing_csv/action_csv_classifier.joblib \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json artifacts/review/baseball_batch_review/labels.json \
  --apply \
  --suggestions-only
```

然后打开复核页：

```text
http://127.0.0.1:8765/review_recheck.html
```

复核页会按 SwingCapture 对 `baseball_swing` 的可信度从高到低排序。你可以逐条标成 `baseball_swing`、`other` 或 `skip`，结果会写回同一个 `labels.json`。

复核完成后，也可以直接在复核页点击“复核完成，开始再次训练”。后端会启动一个异步训练进程，并跳转到：

```text
http://127.0.0.1:8765/train_status.html
```

这个进度页会轮询后端 background task，显示训练进度、输出目录和训练脚本日志。默认训练输出会写到 `artifacts/models/<review-dir-name>_rechecked/<job-id>/`；如果直接用 `serve_action_review.py` 启动服务，可以通过 `--train-out-root` 改输出根目录。

如果你仍然想让高置信度样本自动预标注，可以去掉 `--suggestions-only` 并加上：

```bash
--min-confidence 0.65
```

现在 `--min-confidence` 只控制是否自动写入 `label`，不会再丢掉低置信度样本的预测信息；低置信度样本仍会出现在复核页里，方便你人工选择。

## 5. 训练第一个传统 detector

如果你只想先验证 swing / other 分类是否可行，可以继续用现有 CSV 分类器：

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json artifacts/review/baseball_batch_review/labels.json \
  --out-dir artifacts/models/swing_csv
```

如果你刚刚用 `review_recheck.html` 完成了可信度复核，建议重新训练时只使用人工复核过的标签：

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json artifacts/review/baseball_batch_review/labels.json \
  --out-dir artifacts/models/swing_csv_rechecked \
  --require-human-review
```

## 6. 生成给质量模型和小型教练模型的训练集

把 review workspace 的标注结果转成更适合学习的 JSONL：

```bash
python3 scripts/build_review_learning_manifest.py \
  --review-dir artifacts/review/baseball_batch_review \
  --out-dir artifacts/learning/baseball_batch
```

如果这批标签来自复核页，也可以加上 `--require-human-review`，只导出人工确认过的样本。

输出：

- `detection_train.jsonl`
- `quality_train.jsonl`
- `reward_train.jsonl`
- `llm_sft_train.jsonl`
- `manifest_summary.json`

其中：

- `detection_train.jsonl` 给 swing / other 检测模型
- `quality_train.jsonl` 给质量评分和 issue tag 模型
- `reward_train.jsonl` 给后续偏好学习或 ranking
- `llm_sft_train.jsonl` 给小型教练模型做 SFT

## 7. 开始训练小型 LLM 教练模型

建议先用一个小型本地指令模型，例如 0.5B 到 3B 量级。训练脚本当前走的是最直接的监督微调路线：

```bash
python3 scripts/train_small_swing_llm.py \
  --train-jsonl artifacts/learning/baseball_batch/llm_sft_train.jsonl \
  --model-path /path/to/your-small-instruct-model \
  --out-dir artifacts/models/swing_coach_llm \
  --max-length 1024 \
  --num-train-epochs 3
```

这个模型的职责建议限定为：

- 读取结构化 swing pose summary
- 结合人工质量分和 issue tags
- 输出简短、可执行的纠正建议

不要让小模型直接从原始 pose 序列“自己猜全部结论”。更稳的方式是：

1. detector / quality 模型先把结构化结果算出来
2. 小型 LLM 负责把结构化结果组织成教练话术

## 推荐顺序

最稳的落地顺序是：

1. 先用 `launch_swing_review.py` 快速批量标注
2. 用 `train_swing_csv_classifier.py` 确认 detector 标签有效
3. 用 `build_review_learning_manifest.py` 产出 `llm_sft_train.jsonl`
4. 再用 `train_small_swing_llm.py` 训练小型教练模型
