# SwingCapture

SwingCapture 是一个围绕挥棒采集、姿态提取、网页标注和模型训练的项目。

当前仓库里已经包含：

- Flutter 采集端
- 离线姿态提取脚本
- 网页版 swing 标注工具
- 按 SwingCapture 可信度排序的复核工具
- detector 训练脚本
- 小型教练模型训练脚本

## 训练文档

如果你现在要从一批短视频开始，完整训练 swing detector 和教练模型，直接看这份文档：

- [模型训练 README](docs/README_%E6%A8%A1%E5%9E%8B%E8%AE%AD%E7%BB%83.md)
- [Swing Review And Training](scripts/README_swing_review_and_train.md)

当前训练闭环支持先用已有 detector 对候选片段写入预测建议，再打开 `review_recheck.html` 按 `baseball_swing` 可信度从高到低人工复核。复核完成后，可以在前端点击按钮触发后端异步再训练，并通过 `train_status.html` 查看进度和日志；训练脚本也可使用 `--require-human-review` 只读取人工确认过的标签。

手机上可以打开 `mobile_label.html` 进行快速标注：底部只有 swing / other 两个按钮，上下滑切候选片段，左右滑切视频分组。

## Flutter 开发

如果你主要在看 Flutter App，本项目仍然是一个 Flutter 工程。通用 Flutter 入门资料：

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)
- [Flutter documentation](https://docs.flutter.dev/)
