# Swing 模型训练 README

这份文档专门说明：如何把一批挥棒短视频，训练成两类模型：

1. `swing detector`
   负责判断一段候选动作是不是挥棒
2. `swing coach model`
   负责根据结构化姿态摘要、质量分和问题标签，输出纠正建议

这条训练链路不是一步到位训练一个“万能模型”，而是拆成两层：

1. 先把视频变成稳定的 `pose.json + features.csv`
2. 再做人类标注
3. 先训练结构化识别模型
4. 最后训练小型 LLM 负责生成教练反馈

这样做会比“直接让 LLM 从原始骨架序列里猜建议”稳定很多。

## 一、先理解训练目标

当前仓库对应的是一个分层方案：

- 第 1 层：动作检测
  输入候选 swing 片段，输出 `baseball_swing` 或 `other`
- 第 2 层：质量与问题标签
  输出 `setup/load/rotation/contact/finish` 质量分，以及问题标签
- 第 3 层：教练语言生成
  小模型把结构化结果整理成一句到几句明确建议

建议你按这个顺序推进，不要一上来就只训练语言模型。

## 二、需要准备什么数据

每个原始视频最终会被加工成下面几层数据：

- 原始视频：`*.mp4`
- 姿态文件：`*.pose.json`
- 特征文件：`*.features.csv`
- 候选动作片段：review workspace 里的 `candidate_XXX.mp4/.json/.csv`
- 标注结果：`labels.json`
- 训练集：`detection_train.jsonl`、`quality_train.jsonl`、`reward_train.jsonl`、`llm_sft_train.jsonl`

建议目录结构：

```text
artifacts/
  pose/
  review/
  learning/
  models/
```

## 三、安装环境

### 1. 创建 Python 环境

```bash
python3 -m venv .venv-pose
source .venv-pose/bin/activate
```

### 2. 安装姿态提取和传统训练依赖

```bash
pip install -r scripts/requirements-pose.txt
pip install -r scripts/requirements-train.txt
```

### 3. 如果要训练小型 LLM，再安装文本训练依赖

```bash
pip install -r scripts/requirements-llm-train.txt
```

说明：

- `requirements-pose.txt` 里包含 `mediapipe` 和 `opencv-python`
- `requirements-train.txt` 里包含 `Flask`、`numpy`、`scikit-learn`
- `requirements-llm-train.txt` 里包含 `torch`、`transformers`、`datasets`

## 四、第一步：把多个短视频读成 pose JSON

如果你已经有很多挥棒短视频，推荐直接用批量入口：

```bash
python3 scripts/batch_extract_pose_from_videos.py \
  --input-dir /path/to/swing_videos \
  --glob "**/*.mp4" \
  --out-dir artifacts/pose \
  --skip-existing
```

也可以通过文件选择器手动选视频：

```bash
python3 scripts/batch_extract_pose_from_videos.py \
  --select \
  --out-dir artifacts/pose \
  --skip-existing
```

也可以直接传路径：

```bash
python3 scripts/batch_extract_pose_from_videos.py \
  /path/to/swing_01.mp4 \
  /path/to/swing_02.mp4 \
  /path/to/swing_03.mp4 \
  --out-dir artifacts/pose
```

输出内容：

- `artifacts/pose/xxx.pose.json`
- `artifacts/pose/xxx.features.csv`
- `artifacts/pose/batch_extract_manifest.json`

### 这些文件各自做什么

`*.pose.json`

- 保存逐帧关键点
- 后面可以做时序摘要
- 是训练质量模型和教练模型的重要输入来源

`*.features.csv`

- 保存逐帧手腕速度、躯干分离、速度变化等特征
- 更适合做第一阶段传统 detector

## 五、第二步：启动网页标注台

推荐直接用一条命令完成：

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "**/*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --task-name "Baseball Swing Review" \
  --positive-label baseball_swing \
  --negative-label other \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --skip-existing
```

如果当前机器跑 MediaPipe pose 会失败，但 `artifacts/pose/` 已经存在旧的 `*.pose.json` / `*.features.csv`，可以改用只复用已有 pose 的模式：

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --reuse-existing-pose-only
```

这个 review 准备流程现在支持断点恢复：每处理完一个 source 就会更新 `manifest.json` 和 `review_data.js`，如果你中途 `Ctrl+C`，下次重跑会直接复用已完成部分。

如果你还希望“缺 pose 的新视频也先出现在 review 里”，可以再加：

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --reuse-existing-pose-only \
  --include-missing-pose-videos
```

这样没有 pose 的视频会被加入为 `raw review` 候选，先供人工筛选；后续预测、训练和学习集导出会自动跳过这类无 CSV 特征样本。

前端支持直接筛选这类候选：

- 桌面标注页：`只看 raw review`
- 复核页：`仅 raw review`
- 移动页：`/mobile_label.html?mode=raw`

如果已经准备过 review workspace，想直接再次打开网页，用同一个命令入口即可：

```bash
python3 scripts/launch_swing_review.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --host 127.0.0.1 \
  --port 8765
```

默认打开地址：

```text
http://127.0.0.1:8765
```

### 这个网页现在能做什么

- 一次处理多个视频
- 候选 swing 片段按视频分组
- `← / →` 切换当前组内的上一条和下一条
- `[` / `]` 切换上一组和下一组视频
- `A / S / D` 快速打标签
- 手机快速标注页 `/mobile_label.html`：底部只有 swing / other 两个按钮，上下滑切候选，左右滑切视频分组
- 自动保存：
  - `label`
  - `view`
  - `qualityScores`
  - `issues`
  - `coachSummary`

### 标注建议

对于每个候选片段，至少尽量补这些信息：

- `label`
  - `baseball_swing`
  - `other`
  - `skip`
- `view`
  - `front`
  - `back`
  - `side`
  - `unknown`
- `qualityScores`
  - `setup`
  - `load`
  - `rotation`
  - `contact`
  - `finish`
- `issues`
  - 例如 `hands_cast`
  - `early_hip_open`
  - `head_drift`
  - `finish_off_balance`
- `coachSummary`
  - 一句到几句非常具体的建议

### 标注质量建议

- `label` 比 `coachSummary` 更基础，先保证标签准
- 如果这条 swing 根本不完整，就标 `skip`，不要勉强写建议
- `coachSummary` 尽量写成“问题 + 调整动作”，不要只写“不错”“不好”
- 同一类问题尽量用同一套 issue tag，不要同义词太散

## 六、第三步：训练第一个 swing detector

这是当前最容易先跑通的模型，也是最适合先验证标签质量的模型。

命令：

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json artifacts/review/baseball_batch_review/labels.json \
  --out-dir artifacts/models/swing_csv
```

输出：

- `artifacts/models/swing_csv/action_csv_classifier.joblib`
- `artifacts/models/swing_csv/training_report.json`

### 这个 detector 在学什么

它不是直接吃整段原始视频，而是吃每个候选窗口的统计特征，比如：

- `smoothed_wrist_speed`
- `torso_separation_deg`
- `hands_to_torso_distance`
- `torso_velocity`
- `hands_velocity`
- `swing_score`

训练脚本会把每个窗口进一步聚合成：

- 最小值
- 最大值
- 均值
- 最后一帧值
- 窗口时长
- 峰值速度等

### 什么时候说明 detector 可以继续

你至少要检查 `training_report.json` 里的这些结果：

- 样本数量是否够
- 正负样本是否严重失衡
- `baseball_swing` 的 precision / recall 是否都在往上走

如果 detector 连 swing / other 都分不稳，不要急着训练后面的教练模型。先回去补数据和标签。

## 七、第四步：按可信度复核模型建议

有了第一版 detector 后，可以让它先给 review workspace 里的候选片段写入预测建议：

```bash
python3 scripts/predict_action_csv_classifier.py \
  --model-path artifacts/models/swing_csv/action_csv_classifier.joblib \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json artifacts/review/baseball_batch_review/labels.json \
  --apply \
  --suggestions-only
```

然后打开：

```text
http://127.0.0.1:8765/review_recheck.html
```

复核页会按照 `baseball_swing` 可信度从高到低排序。你确认哪些是 swing、哪些是 other 后，可以重新训练，并只使用人工复核过的标签：

最方便的方式是在复核页点击“复核完成，开始再次训练”。服务端会用 background process 异步运行训练脚本，并跳转到 `train_status.html` 显示进度、输出目录和后端日志。

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json artifacts/review/baseball_batch_review/labels.json \
  --out-dir artifacts/models/swing_csv_rechecked \
  --require-human-review
```

如果使用 `--min-confidence 0.65`，它现在只控制是否自动写入 `label`，不会丢掉低可信度样本的预测信息；低可信度样本仍会进入复核列表。

## 八、第五步：生成后续模型训练集

当你标注得比较完整后，就把 review workspace 转成 JSONL：

```bash
python3 scripts/build_review_learning_manifest.py \
  --review-dir artifacts/review/baseball_batch_review \
  --out-dir artifacts/learning/baseball_batch
```

输出文件：

- `detection_train.jsonl`
- `quality_train.jsonl`
- `reward_train.jsonl`
- `llm_sft_train.jsonl`
- `manifest_summary.json`

### 每个文件怎么用

`detection_train.jsonl`

- 给 swing / other 检测模型
- 适合后面替换成更好的时序模型

`quality_train.jsonl`

- 给挥棒质量评分模型
- 适合学 `setup/load/rotation/contact/finish`

`reward_train.jsonl`

- 给偏好学习或排序模型
- 当前脚本会根据质量分差自动生成基础偏好对

`llm_sft_train.jsonl`

- 给小型教练模型做监督微调
- 每一条样本都包含：
  - `system`
  - `user`
  - `assistant`

## 九、第六步：训练小型教练模型

当前仓库里已经有一个基础版训练脚本：

```bash
python3 scripts/train_small_swing_llm.py \
  --train-jsonl artifacts/learning/baseball_batch/llm_sft_train.jsonl \
  --model-path /path/to/your-small-instruct-model \
  --out-dir artifacts/models/swing_coach_llm \
  --max-length 1024 \
  --num-train-epochs 3 \
  --learning-rate 2e-5
```

### `--model-path` 应该填什么

这里填你本地可用的小型指令模型，或者 Hugging Face 模型名。建议先从小模型开始：

- 0.5B 到 3B 参数量更适合快速迭代
- 优先选 instruction / chat 类型模型
- 先验证数据格式和输出风格，再考虑更大模型

### 这个训练脚本具体在做什么

它会：

1. 读取 `llm_sft_train.jsonl`
2. 把每条样本里的 `messages` 转成训练文本
3. 用 `transformers.Trainer` 进行监督微调
4. 把模型和 tokenizer 保存到 `--out-dir`

输出目录通常会包含：

- 训练后的模型权重
- tokenizer 文件
- `training_config.json`

### 训练时推荐的思路

第一轮先求“能跑通”，不要先追最优：

- `max_length=1024`
- `num_train_epochs=3`
- `per_device_train_batch_size=1`
- `gradient_accumulation_steps=8`

如果数据还少，先控制模型规模，不要过拟合得太快。

## 十、推荐的训练顺序

一套比较稳的顺序是：

1. 先收集 30 到 100 个短视频
2. 先把 pose 和候选片段跑通
3. 先认真标 `label`
4. 再补 `view / qualityScores / issues / coachSummary`
5. 先训练 detector
6. detector 有基础效果后，再生成 `llm_sft_train.jsonl`
7. 最后训练小型教练模型

## 十一、怎么判断当前该补数据还是该调模型

更常见的问题通常不是“模型不够强”，而是“数据还不够稳”。

优先补数据的信号：

- `labels.json` 里很多片段没有 `coachSummary`
- 同类问题被写成很多不同 issue 名称
- 正负样本差距太大
- detector 结果起伏很大
- 不同视角混在一起但没标 `view`

优先调模型的信号：

- 标签比较稳定
- 正负样本已经够多
- detector 的错误开始集中在少数边界样本
- LLM 输出已经接近可用，只是冗长或不够聚焦

## 十二、训练后的推荐推理架构

线上最好不要让小型 LLM 直接从原始 pose 序列端到端猜所有东西。

更稳的方式是：

1. `detector`
   判断是不是 swing
2. `quality model`
   给出质量分和 issues
3. `prompt builder`
   把结构化结果整理成 prompt
4. `small LLM`
   输出自然语言建议

这样做的好处：

- 更稳
- 更容易调试
- 更容易解释错误来源

## 十三、常见问题

### 1. `mediapipe` 导入失败

先确认环境已经激活，然后重新安装：

```bash
source .venv-pose/bin/activate
pip install -r scripts/requirements-pose.txt
```

### 2. `launch_swing_review.py` 跑不起来

通常是 `Flask` 没装：

```bash
pip install -r scripts/requirements-train.txt
```

### 3. `llm_sft_train.jsonl` 很少

这是因为：

- 很多正样本没有写 `coachSummary`
- 只有正样本才会进当前 LLM 训练集

解决方法：

- 多写高质量 `coachSummary`
- 保持 issue tags 和质量分更完整

### 4. 模型输出很空泛

通常不是训练脚本的问题，而是训练语料太泛：

- 不要只写“注意重心”“挥棒更流畅”
- 尽量写“哪里有问题 + 应该怎么改”

## 十四、把新 TFLite 接入 App（SwingCapture）

`scripts/train_swing_tflite_classifier.py` 跑完后，会得到这 3 个文件：

- `swing_classifier.tflite`
- `swing_classifier_labels.json`
- `swing_classifier_report.json`

### 1. 复制到 Flutter assets

以你当前训练输出路径为例：

```bash
mkdir -p assets/models
cp /Volumes/SSD/swing/artifacts/models/swing_tflite/swing_classifier.tflite assets/models/
cp /Volumes/SSD/swing/artifacts/models/swing_tflite/swing_classifier_labels.json assets/models/
cp /Volumes/SSD/swing/artifacts/models/swing_tflite/swing_classifier_report.json assets/models/
```

### 2. 重新构建并安装 App

```bash
flutter pub get
flutter run
```

### 3. App 内加载行为（新流程）

- App 会优先从内置 `assets/models/` 读取模型与标签
- 首次推理时会自动写入 `<app-documents>/models/`
- 如果文档目录里已有同名文件，会继续使用该文件（可用于热替换）

### 和旧流程的区别

旧流程通常需要手动把模型 push 到设备 `<app-documents>/models/`。  
现在改为“随 App 一起打包”，重新 `flutter run` 后就会带上新模型，通常不再需要手动 push。

## 十五、建议先做到的里程碑

如果你想把这件事拆成一个靠谱的阶段目标，建议先做到：

1. 至少 200 条已标注候选片段
2. `baseball_swing` / `other` 标签稳定
3. 至少 80 条正样本写了 `coachSummary`
4. detector 能给出初步可用结果
5. 小型教练模型能输出短而具体的纠正建议

做到这一步，就已经不是“概念验证”，而是一个可以持续迭代的数据训练闭环了。
