# 通用动作识别：视频分类与训练指南

这份文档说明如何使用当前项目中的离线脚本，把一段本地视频处理成：

1. 姿态关键点 `pose.json`
2. 动作特征 `features.csv`
3. 候选动作片段
4. 浏览器人工标注结果
5. 一个可复用的桌面端分类模型

这套流程目前适合做第一阶段验证，尤其适合：

- 棒球挥棒
- 篮球投篮
- 舞蹈动作分类
- 跑步步态片段分类
- 其他以“人体关键点时序变化”为核心的动作识别任务

注意：当前训练脚本输出的是桌面端 `joblib` 模型，适合先验证你的特征和标签是否有效；它还不是最终直接放进 Flutter App 的移动端模型格式。后续如果效果稳定，再导出为 `TFLite` 更合适。

---

## 一、当前脚本在做什么

当前目录下已有这些关键脚本：

- `extract_pose_from_video.py`
  - 从视频中提取姿态关键点
  - 输出 `pose.json`、`features.csv`
  - 可选输出骨架叠加视频

- `prepare_swing_review.py`
  - 读取 `pose.json` 和 `features.csv`
  - 自动找出候选动作峰值
  - 截出候选片段视频、片段 CSV、片段 JSON
  - 生成本地 HTML 标注页

- `train_swing_csv_classifier.py`
  - 读取人工标注结果
  - 对每个候选窗口做特征聚合
  - 训练一个简单的 `RandomForest` 分类器

- `detect_swings_from_pose_json.py`
  - 这是一个基于启发式规则的快速检测脚本
  - 更适合做候选事件粗筛，不是最终训练模型

虽然部分脚本文件名里还保留了 `swing` 字样，但目前链路已经支持通用标签，例如：

- `baseball_swing`
- `basketball_shot`
- `dance_spin`
- `running_stride`
- `other`

---

## 二、推荐目录结构

建议你把数据按下面方式组织：

```text
dataset/
  raw_videos/
    clip_001.mp4
    clip_002.mp4
    clip_003.mp4
  artifacts/
    pose/
    review/
    models/
```

例如：

```text
dataset/raw_videos/baseball_001.mp4
dataset/artifacts/pose/
dataset/artifacts/review/
dataset/artifacts/models/
```

---

## 三、环境准备

### 1. 创建 Python 虚拟环境（默认）

```bash
python3 -m venv .venv-pose
source .venv-pose/bin/activate
```

### 1b. 创建 TFLite 训练环境（本地推荐，避免和 mediapipe 冲突）

```bash
python3 -m venv .venv-tf
.venv-tf/bin/pip install --upgrade pip
.venv-tf/bin/pip install tensorflow scikit-learn joblib numpy
```

### 2. 安装姿态提取依赖

```bash
pip install -r scripts/requirements-pose.txt
```

### 3. 安装训练依赖

```bash
pip install -r scripts/requirements-train.txt
```

如果你想一步装完，也可以直接两个都装：

```bash
pip install -r scripts/requirements-pose.txt
pip install -r scripts/requirements-train.txt
```

---

## 四、第一步：从视频提取姿态与特征

先对原始视频运行姿态提取脚本。

默认最少内容：

```bash
python3 scripts/extract_pose_from_video.py /path/to/video.mp4 --save-overlay
```

本地路径版：

```bash
python3 scripts/extract_pose_from_video.py /Volumes/SSD/swing/SwingCapture/swing_1776535958458270.mp4 --save-overlay
```

默认输出目录是：

```text
artifacts/pose/
```

通常会得到这几类文件：

- `xxx.pose.json`
  - 每一帧的关键点信息
  - 包括时间戳、关节点坐标、可见度等

- `xxx.features.csv`
  - 每一帧的动作特征
  - 例如上身旋转、手腕速度、双手到躯干距离等

- `xxx.overlay.mp4`
  - 可选
  - 带骨架渲染的调试视频

### `pose.json` 的用途

它适合：

- 后续重算特征
- 画骨架
- 做时序模型训练
- 调试某个关节是否跟踪稳定

### `features.csv` 的用途

它适合：

- 快速做候选动作检测
- 快速做传统机器学习分类
- 先验证哪些特征对某个动作最有效

---

## 五、第二步：自动生成候选动作片段

有了 `pose.json` 和 `features.csv` 后，运行候选片段生成脚本。

现在这一步已经支持：

- 一次处理多个 `pose.json + features.csv`
- 所有候选片段输出到一个 review 根目录
- 只生成一个 `index.html`
- 后续通过 Flask 统一提供给桌面和手机访问

### 单视频示例

默认最少内容：

```bash
python3 scripts/prepare_swing_review.py \
  --pose-json artifacts/pose/video.pose.json \
  --features-csv artifacts/pose/video.features.csv \
  --out-dir artifacts/review/video_review \
  --task-name "Baseball Swing Review" \
  --positive-label baseball_swing \
  --negative-label other
```

本地路径版：

```bash
python3 scripts/prepare_swing_review.py \
  --pose-json /Volumes/SSD/swing/artifacts/pose/swing_1776535958458270.pose.json \
  --features-csv /Volumes/SSD/swing/artifacts/pose/swing_1776535958458270.features.csv \
  --out-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --task-name "Baseball Swing Review" \
  --positive-label baseball_swing \
  --negative-label other
```

### 多视频示例

例如你有 3 个视频，希望统一在一个标注任务里处理：

```bash
python3 scripts/prepare_swing_review.py \
  --pose-json artifacts/pose/baseball_001.pose.json \
  --features-csv artifacts/pose/baseball_001.features.csv \
  --pose-json artifacts/pose/baseball_002.pose.json \
  --features-csv artifacts/pose/baseball_002.features.csv \
  --pose-json artifacts/pose/baseball_003.pose.json \
  --features-csv artifacts/pose/baseball_003.features.csv \
  --out-dir artifacts/review/baseball_batch_review \
  --task-name "棒球挥棒标注" \
  --positive-label baseball_swing \
  --negative-label other
```

本地路径版建议直接用一条命令入口（自动扫目录 + 生成标注页）：

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "**/*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --task-name "Baseball Swing Review" \
  --positive-label baseball_swing \
  --negative-label other \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --skip-existing \
  --open-browser
```

这个脚本会做几件事：

1. 从 `features.csv` 中计算当前动作分数
2. 自动找峰值
3. 每个峰值切成一个候选窗口
4. 生成：
   - 候选片段视频
   - 对应的片段 CSV
   - 对应的片段 JSON
   - 一个浏览器可打开的 `index.html`

输出目录通常像这样：

```text
artifacts/review/baseball_batch_review/
  index.html
  manifest.json
  review_data.js
  candidates/
    baseball_001/
      baseball_001_candidate_001/
        baseball_001_candidate_001.mp4
        baseball_001_candidate_001.csv
        baseball_001_candidate_001.json
    baseball_002/
      ...
```

### 这一步为什么重要

它把“一整段长视频”拆成了“若干小动作窗口”，这样你不用手动拖时间轴逐段找动作，标注效率会高很多。

---

## 六、第三步：启动 Flask 服务并在浏览器里标注

不要再直接 `open index.html`。

现在推荐通过 Flask 启动一个本地服务，这样：

- 手机可以直接访问
- 标签可以自动保存到服务端 `labels.json`
- 不依赖浏览器本地缓存
- 同一个根目录可以连续处理多个来源视频

### 启动服务

默认最少内容：

```bash
python3 scripts/serve_action_review.py \
  --review-dir artifacts/review/baseball_batch_review
```

本地路径版：

```bash
python3 scripts/serve_action_review.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --host 127.0.0.1 \
  --port 8765
```

默认会启动在：

```text
http://0.0.0.0:8765
```

如果你在同一局域网里，可以把电脑 IP 发给手机，例如：

```text
http://192.168.1.20:8765
```

### 标注界面现在的行为

你会看到一个统一的标注页面，而不是“一段视频一个 HTML”。页面会：

- 从多个来源视频中按顺序展示候选片段
- 你点一次标签后自动跳到下一条
- 支持上一条、下一条、下一个未标注
- 支持手机端大按钮点选
- 自动保存标签到 `labels.json`

然后你可以把当前候选片段标成：

- 正样本：例如 `baseball_swing`
- 负样本：例如 `other`
- 跳过：`skip`

### 推荐标注规则

为了让模型更稳，建议你先定义好什么算正样本：

#### 棒球挥棒

标成 `baseball_swing`：

- 明确出现完整挥棒动作
- 有明显上身旋转与双手快速摆动
- 是你想让 App 触发保存的那种动作

标成 `other`：

- 只是准备动作
- 假挥、不完整挥棒
- 教练/家长走过画面
- 人体抖动但不是你想要的动作
- 候选切片截偏了

#### 篮球投篮

标成 `basketball_shot`：

- 明确有投篮或出手动作

标成 `other`：

- 运球
- 持球准备
- 转身但未出手

### 标注建议

- 不要只标正样本，也要保留大量负样本
- 保证不同机位、不同人、不同距离都有样本
- 左右手、正面、背面、侧面都尽量覆盖

标注完成后：

- 服务端会自动保存到 `artifacts/review/.../labels.json`
- 你也可以手动点击“导出”

---

## 七、第四步：训练一个简单分类器

有了 `labels.json` 后，运行训练脚本。

默认最少内容：

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json /path/to/exported_labels.json \
  --out-dir artifacts/models/baseball_v1
```

本地路径版：

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --out-dir /Volumes/SSD/swing/artifacts/models/swing_csv
```

输出文件包括：

- `action_csv_classifier.joblib`
- `training_report.json`

### `action_csv_classifier.joblib` 是什么

它是一个桌面端模型包，里面包括：

- 训练好的 `RandomForest` 模型
- 训练时使用的特征名
- 类别名称列表
- 类别到索引的映射

### `training_report.json` 是什么

它记录：

- 样本数量
- 类别列表
- 特征名
- 分类报告
- 每个训练样本的来源信息

你可以先看这个报告判断：

- 数据够不够
- 某类样本是不是太少
- 正负样本是否失衡
- 模型是否已经初步可用

---

## 八、第五步：如何用现有模型去分类一个新视频

当前项目里还没有一个“直接拿 `joblib` 去扫完整新视频并输出最终标签”的完整脚本，但现有代码已经足够拼出这条流程。

推荐步骤如下：

### 方案 A：先走现有链路，最稳

对一个新视频：

1. 提取姿态与特征

```bash
python3 scripts/extract_pose_from_video.py /path/to/new_video.mp4 --save-overlay
```

2. 生成候选片段

```bash
python3 scripts/prepare_swing_review.py \
  --pose-json artifacts/pose/new_video.pose.json \
  --features-csv artifacts/pose/new_video.features.csv \
  --out-dir artifacts/review/new_video_review \
  --task-name "棒球挥棒复核" \
  --positive-label baseball_swing \
  --negative-label other
```

3. 用训练好的模型对每个候选片段的 CSV 做预测，并写入复核建议

默认最少内容：

```bash
python3 scripts/predict_action_csv_classifier.py \
  --model-path artifacts/models/baseball_v1/action_csv_classifier.joblib \
  --review-dir artifacts/review/new_video_review \
  --labels-json artifacts/review/new_video_review/labels.json \
  --only-unlabeled \
  --min-confidence 0.65 \
  --apply
```

本地路径版：

```bash
.venv-pose/bin/python scripts/predict_action_csv_classifier.py \
  --model-path /Volumes/SSD/swing/artifacts/models/swing_csv/action_csv_classifier.joblib \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --only-unlabeled \
  --min-confidence 0.50 \
  --apply
```

然后打开：

```text
http://127.0.0.1:8765/review_recheck.html
```

复核页会按标签状态列出候选片段。你可以逐条确认哪些是 swing、哪些是 other，再重新训练。

也可以直接在复核页点击“复核完成，开始再次训练”。训练会在后端 background process 中异步运行，并跳转到 `train_status.html` 查看进度和后端日志。

也就是说，当前已有：

- 特征定义：`FEATURE_COLUMNS`
- 窗口聚合逻辑：`extract_window_features(rows)`
- 训练产物格式：`action_csv_classifier.joblib`

所以只差一个“推理脚本壳”。

### 方案 B：用规则脚本先粗筛

如果你只是想快速知道视频里哪里可能有挥棒，也可以先用：

```bash
python3 scripts/detect_swings_from_pose_json.py /path/to/video.pose.json
```

它会根据关键点速度和横向爆发式运动做启发式检测，更适合：

- 先找候选时间点
- 做粗略预览
- 加速后续复核

但它不是训练模型，不适合拿来当最终分类器。

---

## 九、什么情况下要重新训练

建议在下面这些情况下重新训练：

- 更换了运动项目
- 更换了拍摄机位
- 新增了正面/背面/侧面视角
- 新增了儿童/成人、左打/右打等不同人群
- 当前模型对某类误触发很多

一个简单经验是：

- 如果目标动作变了，最好重新训练
- 如果只是同一动作但数据更多，可以在原有标签体系上继续补样本再训练

---

## 十、如何让训练结果以后进入 Flutter App

当前的 `joblib` 模型是桌面验证版，不建议直接塞进 Flutter。

推荐路径是：

### 第一步：先用当前流程验证数据与标签

先确认：

- 你的候选窗口切得准不准
- 标注规则清不清晰
- `features.csv` 是否真的能区分动作

### 第二步：导出可在 Flutter 本地推理的 TFLite 模型

后续建议改成：

默认最少内容：

```bash
.venv-tf/bin/python scripts/train_swing_tflite_classifier.py \
  --review-dir artifacts/review/baseball_batch_review \
  --labels-json artifacts/review/baseball_batch_review/labels.json \
  --out-dir artifacts/models/swing_tflite
```

本地路径版：

```bash
.venv-tf/bin/python scripts/train_swing_tflite_classifier.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --out-dir /Volumes/SSD/swing/artifacts/models/swing_tflite
```

### 第三步：在 Flutter 里接入

当前代码已经接入了历史详情页离线推理按钮（读取 `pose.json` + `tflite` 预测）。
模型默认读取路径：

```text
<app-documents>/models/swing_classifier.tflite
<app-documents>/models/swing_classifier_labels.json
```

---

## 十一、建议的数据积累方式

如果你想把这个框架长期做大，建议每个样本都保存：

- 原视频片段
- 候选片段视频
- `pose.json`
- `features.csv`
- `labels.json`

标签不要只写“是不是挥棒”，最好写成通用格式，例如：

```json
{
  "sport": "baseball",
  "action": "baseball_swing",
  "quality": "good",
  "camera_view": "rear",
  "notes": ["full_body_visible", "bat_visible"]
}
```

这样以后可以支持：

- 二分类
- 多分类
- 动作评分
- 动作指导建议

---

## 十二、当前这套方案的局限

当前方案适合做第一阶段验证，但要知道它的边界：

- `features.csv` 主要还是人工特征，不是端到端模型
- 当前训练器是 `RandomForest`，不是时序深度模型
- 已有批量预测脚本，但默认模型仍偏向“先验证可用性”，不是最终线上方案
- 当前更适合验证“能否分类”，而不是做到最终比赛级准确率

换句话说：

这套流程现在最适合做：

- 数据整理
- 标签定义
- 初步分类验证
- 快速迭代特征

等你把数据积累起来，再升级到 `TFLite` 时序模型会更稳。

---

## 十三、推荐的实际工作顺序

如果你现在要真正开始做，建议按这个顺序执行：

1. 先挑 20 到 50 段代表性视频
2. 跑 `extract_pose_from_video.py`
3. 跑 `prepare_swing_review.py`
4. 在 HTML 页面里标注
5. 跑 `train_swing_csv_classifier.py`
6. 看 `training_report.json`
7. 跑 `predict_action_csv_classifier.py --apply`
8. 打开 `review_recheck.html`，按可信度从高到低复核
9. 用复核后的 `labels.json` 再训练第二版模型
10. 找出误判多的样本继续补数据

如果你希望更进一步，下一步最值得补的是：

1. 更完整的移动端训练评估脚本
   - 把当前桌面验证版训练链路升级成可导出移动端模型的版本

---

## 十四、最短命令清单（双版本）

### 安装依赖（默认最少内容）

```bash
python3 -m venv .venv-pose
source .venv-pose/bin/activate
pip install -r scripts/requirements-pose.txt
pip install -r scripts/requirements-train.txt
```

### 安装 TFLite 训练环境（本地路径版）

```bash
python3 -m venv .venv-tf
.venv-tf/bin/pip install --upgrade pip
.venv-tf/bin/pip install tensorflow scikit-learn joblib numpy
```

### 提取姿态（默认最少内容）

```bash
python3 scripts/extract_pose_from_video.py /path/to/video.mp4 --save-overlay
```

### 提取姿态（本地路径版）

```bash
python3 scripts/extract_pose_from_video.py /Volumes/SSD/swing/SwingCapture/swing_1776535958458270.mp4 --save-overlay
```

### 生成候选片段与标注页（默认最少内容）

```bash
python3 scripts/prepare_swing_review.py \
  --pose-json artifacts/pose/video.pose.json \
  --features-csv artifacts/pose/video.features.csv \
  --out-dir artifacts/review/video_review \
  --task-name "棒球挥棒标注" \
  --positive-label baseball_swing \
  --negative-label other
```

### 生成候选片段与标注页（本地路径版，推荐一条命令）

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "**/*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --task-name "Baseball Swing Review" \
  --positive-label baseball_swing \
  --negative-label other \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --skip-existing \
  --open-browser
```

### 启动标注服务（默认最少内容）

```bash
python3 scripts/serve_action_review.py \
  --review-dir artifacts/review/video_review
```

### 启动标注服务（本地路径版）

```bash
python3 scripts/serve_action_review.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --host 127.0.0.1 \
  --port 8765
```

### 训练分类器（默认最少内容）

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir artifacts/review/video_review \
  --labels-json /path/to/exported_labels.json \
  --out-dir artifacts/models/action_v1
```

### 训练分类器（本地路径版）

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --out-dir /Volumes/SSD/swing/artifacts/models/swing_csv
```

### 写入模型建议并打开复核页（默认最少内容）

```bash
python3 scripts/predict_action_csv_classifier.py \
  --model-path artifacts/models/action_v1/action_csv_classifier.joblib \
  --review-dir artifacts/review/video_review \
  --labels-json artifacts/review/video_review/labels.json \
  --apply \
  --only-unlabeled \
  --min-confidence 0.65
```

### 写入模型建议并打开复核页（本地路径版）

```bash
.venv-pose/bin/python scripts/predict_action_csv_classifier.py \
  --model-path /Volumes/SSD/swing/artifacts/models/swing_csv/action_csv_classifier.joblib \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --apply \
  --only-unlabeled \
  --min-confidence 0.50
```

### 一键预测所有新视频（本地路径版）

下面这条命令会一次完成：

1. 扫描输入目录下全部视频（对已有 pose 结果自动复用）
2. 更新/生成 review workspace
3. 用当前模型只给“未标注候选”写入自动预测标签

```bash
python3 scripts/launch_swing_review.py \
  --video-dir /Volumes/SSD/swing/SwingCapture \
  --glob "**/*.mp4" \
  --pose-out-dir /Volumes/SSD/swing/artifacts/pose \
  --task-name "Baseball Swing Review" \
  --positive-label baseball_swing \
  --negative-label other \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --skip-existing \
  --no-serve \
&& .venv-pose/bin/python scripts/predict_action_csv_classifier.py \
  --model-path /Volumes/SSD/swing/artifacts/models/swing_csv/action_csv_classifier.joblib \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --only-unlabeled \
  --min-confidence 0.50 \
  --apply
```

```text
http://127.0.0.1:8765/review_recheck.html
```

### 只用复核标签重新训练（默认最少内容）

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir artifacts/review/video_review \
  --labels-json artifacts/review/video_review/labels.json \
  --out-dir artifacts/models/action_v2_rechecked
```

### 只用复核标签重新训练（本地路径版）

```bash
python3 scripts/train_swing_csv_classifier.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --out-dir /Volumes/SSD/swing/artifacts/models/swing_csv_rechecked
```

### 导出 TFLite（默认最少内容）

```bash
.venv-tf/bin/python scripts/train_swing_tflite_classifier.py \
  --review-dir artifacts/review/video_review \
  --labels-json artifacts/review/video_review/labels.json \
  --out-dir artifacts/models/swing_tflite
```

### 导出 TFLite（本地路径版）

```bash
.venv-tf/bin/python scripts/train_swing_tflite_classifier.py \
  --review-dir /Volumes/SSD/swing/artifacts/review/baseball_batch_review \
  --labels-json /Volumes/SSD/swing/artifacts/review/baseball_batch_review/labels.json \
  --out-dir /Volumes/SSD/swing/artifacts/models/swing_tflite
```

---
