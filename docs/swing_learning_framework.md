# Swing Learning Framework

这套框架不是“先上一个大而全的 RL 系统”，而是先把数据链和训练接口做稳，然后逐步演进到：

1. swing detection
2. swing quality 评估
3. swing 改进建议
4. 小型 LLM 教练输出

## 总体路线

### Phase 1: 采集

App 在保存视频时，同时保存：

- `*.mp4`
- `*.pose.json`

这一步已经足够支持你后面的所有监督学习和偏好学习。

### Phase 2: 人工标注

建议维护一个标注文件：

- 模板：`scripts/templates/swing_learning_annotations.template.json`

你需要先给每个 clip 标：

- 是否是 swing
- 视角是正面还是背面
- 质量分
- 关键问题标签
- 一段人工教练总结

### Phase 3: Detection 模型

任务定义：

- 输入：`frames`
- 输出：`baseball_swing` / `other`

推荐先做监督学习，不要一开始就直接 RL：

- 时序特征工程
- 1D CNN / GRU / Transformer Encoder
- 目标是先把“触发正确率”拉起来

输出文件：

- `detection_train.jsonl`

生成方式：

```bash
python3 scripts/build_swing_learning_manifest.py \
  --clips-dir /path/to/clips \
  --annotations-json /path/to/annotations.json \
  --out-dir artifacts/learning
```

### Phase 4: Reward / Preference 学习

等 detection 稳定后，再做 swing quality：

- 单条评分：回归 `setup/load/rotation/contact/finish`
- 成对偏好：`A 比 B 更好`

输出文件：

- `reward_train.jsonl`

这一步适合后续接：

- reward model
- ranking model
- DPO / IPO / pairwise preference tuning

注意：

- 对“动作改进建议”来说，reward 比硬分类更重要
- 因为建议系统要知道“哪里更好、哪里更差”，不是只有 swing / non-swing

### Phase 5: 小型 LLM 教练输出

任务定义：

- 输入：
  - clip summary
  - 检测结果
  - 质量评分
  - issue tags
- 输出：
  - 一小段人类可读建议

输出文件：

- `llm_sft_train.jsonl`

训练方式建议：

1. 先做 SFT
2. 再加 reward / preference
3. 最后在推理时把结构化模型结果喂给小模型

## 推荐的在线推理架构

### 1. Detector

输入 `pose_skeleton_clip.v1`

输出：

- 是否 swing
- swing 阶段分数
- view / confidence

### 2. Quality Head

输出：

- `setup/load/rotation/contact/finish`
- issue tags

### 3. Coaching Prompt Builder

把 detector 和 quality head 输出整理成结构化 prompt：

```json
{
  "view": "back",
  "detection": {
    "label": "baseball_swing",
    "confidence": 0.92
  },
  "scores": {
    "load": 2,
    "rotation": 4,
    "finish": 1
  },
  "issues": [
    "finish_off_balance",
    "hands_cast"
  ]
}
```

### 4. Small LLM

小模型只做语言层：

- 总结问题
- 组织建议顺序
- 控制语气和长度

不要让小模型自己从原始 pose 序列里“猜动作”。那样会不稳定。更好的做法是：

- 结构化模型负责识别和评分
- 小模型负责转成自然语言

## 目录建议

```text
artifacts/
  clips/
    swing_xxx.mp4
    swing_xxx.pose.json
  learning/
    detection_train.jsonl
    reward_train.jsonl
    llm_sft_train.jsonl
    manifest_summary.json
```

## 这套框架现在已经给你的部分

仓库里现在有：

- pose clip 标准：`docs/pose_skeleton_json_standard.md`
- 标注模板：`scripts/templates/swing_learning_annotations.template.json`
- manifest 生成器：`scripts/build_swing_learning_manifest.py`

你下一步只需要做两件事：

1. 持续录数据并手工标注
2. 用这些标注产出 detection / reward / llm 三类训练样本

之后如果你愿意，我下一步可以继续把这套框架往前推进两层：

- 先给你补一个 `pose clip -> detection features` 的训练脚本
- 再给你补一个 `quality scores + issues -> coaching prompt` 的小模型推理脚手架
