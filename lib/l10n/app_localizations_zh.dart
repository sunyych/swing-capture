// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'MotionCapture';

  @override
  String get navCapture => '拍摄';

  @override
  String get navHistory => '历史';

  @override
  String get navSettings => '设置';

  @override
  String get dontShowTestContent => '不再显示测试内容';

  @override
  String get performanceTests => '性能测试';

  @override
  String get recordingProfile => '录制配置';

  @override
  String get poseDetection => '姿态检测';

  @override
  String get poseProcessing => '姿态处理';

  @override
  String get checking => '检查中...';

  @override
  String get running => '运行中...';

  @override
  String get close => '关闭';

  @override
  String framesCandidates(int frames, int candidates) {
    return '$frames 帧，$candidates 个候选';
  }

  @override
  String framesElapsedMs(int frames, int ms) {
    return '$frames 帧，$ms 毫秒';
  }

  @override
  String fpsValue(String fps) {
    return '$fps 帧/秒';
  }

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsSubtitle => '选择实时拍摄模型，并调整叠加层行为。';

  @override
  String failedWithError(String error) {
    return '失败：$error';
  }

  @override
  String get showDebugSkeleton => '显示调试骨架';

  @override
  String get showDebugSkeletonSubtitle => '显示检测关键点和未来的边界框。';

  @override
  String get autoDetection => '自动检测';

  @override
  String get autoDetectionSubtitle =>
      '开启后，MotionCapture 会使用所选模型自动拍摄。关闭后保持手动模式，仅在拍摄页触发时保存。';

  @override
  String get autoSaveToGallery => '自动保存到相册';

  @override
  String get autoSaveToGallerySubtitle => '原生导出就绪后，片段会保存到 MotionCapture 相册。';

  @override
  String get settingsFooterNote =>
      '模型名称包含 YYYYMMDD 格式的发布日期。在 Android 上，停留在拍摄页时仍可用音量键触发拍摄。';

  @override
  String get captureTfModel => '拍摄 TF 模型';

  @override
  String get captureTfModelSubtitle => '选择拍摄时使用的实时触发模型版本。';

  @override
  String get modelDrivesAutoCapture => '所选模型将驱动自动挥击拍摄。';

  @override
  String get autoDetectionOffWaiting => '自动检测已关闭，所选模型将等待你重新开启后再工作。';

  @override
  String get tfModelVersion => 'TF 模型版本';

  @override
  String get historyTitle => '历史';

  @override
  String get historyHelpNormal => '你录制的片段会保存在这里。长按磁贴可选中，或点选「选择」。导出可将副本保存到相册。';

  @override
  String get historyHelpSelection => '点按片段切换选中。准备好后使用「导出」或「删除」。';

  @override
  String get export => '导出';

  @override
  String get select => '选择';

  @override
  String get cancel => '取消';

  @override
  String get selectAll => '全选';

  @override
  String get clear => '清除';

  @override
  String get noneSelected => '未选择';

  @override
  String nSelected(int count) {
    return '已选 $count 项';
  }

  @override
  String get delete => '删除';

  @override
  String get deleteClipsTitle => '删除片段';

  @override
  String deleteClipsConfirm(int count) {
    return '确定从此设备永久删除 $count 个片段？视频文件和缩略图将被移除。';
  }

  @override
  String get exportToPhotos => '导出到相册';

  @override
  String exportClipsConfirm(int count, String album) {
    return '将 $count 个片段保存到 $album 相册？';
  }

  @override
  String get selectClipsToExportHint => '请先选择要导出的片段，或取消选择以导出全部。';

  @override
  String savedClipsToPhotos(int count) {
    return '已将 $count 个片段保存到相册。';
  }

  @override
  String savedClipsPartial(int saved, int skipped) {
    return '已保存 $saved 个片段；$skipped 个无法保存。';
  }

  @override
  String get noCapturedSwingsYet => '暂无拍摄片段';

  @override
  String get emptyHistoryHint => '在拍摄页录制一段视频后，会以磁贴显示在这里。';

  @override
  String get captureDetailTitle => '拍摄详情';

  @override
  String captureDetailIndexTitle(int index, int total) {
    return '拍摄 $index / $total';
  }

  @override
  String get previousVideo => '上一段视频';

  @override
  String get nextVideo => '下一段视频';

  @override
  String get addTagTitle => '添加标签';

  @override
  String get tagNameLabel => '标签名称';

  @override
  String get tagNameHint => '例如：正手、反手、热身';

  @override
  String get save => '保存';

  @override
  String exportSingleClipConfirm(String album) {
    return '将此片段保存到 $album 相册？';
  }

  @override
  String get noTaggingActionToUndo => '没有可撤销的标注操作。';

  @override
  String get savedToPhotos => '已保存到相册。';

  @override
  String get couldNotSaveToPhotos => '无法保存到相册。';

  @override
  String get videoUnavailable => '视频不可用';

  @override
  String get unavailable => '不可用';

  @override
  String get quickTaggingHint => '快捷标注：右滑=有效动作，左滑=无效，上滑=自定义标签，下滑=撤销。';

  @override
  String durationLabel(String duration) {
    return '时长：$duration';
  }

  @override
  String frameRateLabel(String fps) {
    return '帧率：$fps';
  }

  @override
  String albumLabel(String album) {
    return '相册：$album';
  }

  @override
  String locationLabel(String location) {
    return '位置：$location';
  }

  @override
  String videoLabel(String fileName) {
    return '视频：$fileName';
  }

  @override
  String reviewLabel(String review) {
    return '审核：$review';
  }

  @override
  String datasetLabel(String dataset) {
    return '数据集：$dataset';
  }

  @override
  String tagLabel(String tag) {
    return '标签：$tag';
  }

  @override
  String get none => '无';

  @override
  String get onDeviceSwingClassifierTitle => '端侧挥击分类器（TFLite）';

  @override
  String get runOnDeviceInference => '运行端侧推理';

  @override
  String get modelPathOnDevice =>
      '设备上模型路径：<app-documents>/models/swing_classifier.tflite';

  @override
  String predictedLabel(String label, String confidence) {
    return '预测标签：$label（$confidence%）';
  }

  @override
  String classProbability(String className, String probability) {
    return '$className：$probability%';
  }

  @override
  String get noPoseJsonAvailable => '此片段没有可用的姿态 JSON。';

  @override
  String poseJsonFileNotFound(String path) {
    return '未找到姿态 JSON 文件：$path';
  }

  @override
  String get onDeviceInferenceCompleted => '端侧推理已完成。';

  @override
  String inferenceFailed(String error) {
    return '推理失败：$error';
  }

  @override
  String get cameraPermissionRequiredTitle => '需要相机权限';

  @override
  String get cameraPermissionRequiredBody => '请授予相机权限以打开实时预览并开始录制。';

  @override
  String get cameraPermissionRequiredMessage => '预览和录制需要相机权限。';

  @override
  String get cameraReady => '相机已就绪。';

  @override
  String get cameraLoading => '相机加载中';

  @override
  String get cameraNotInitialized => '相机尚未初始化。';

  @override
  String get couldNotRestoreCameraPreview => '无法恢复相机预览。';

  @override
  String get frontCamera => '前置摄像头';

  @override
  String get backCamera => '后置摄像头';

  @override
  String get externalCamera => '外接摄像头';

  @override
  String get captureSettingsTitle => '拍摄设置';

  @override
  String get resolutionSectionTitle => '分辨率';

  @override
  String get flashSectionTitle => '闪光灯';

  @override
  String get openFullSettingsTitle => '打开完整设置';

  @override
  String get openFullSettingsSubtitle => '调整模型版本、检测与调试叠加层。';

  @override
  String get resolutionLow => '低';

  @override
  String get resolutionMedium => '中';

  @override
  String get resolutionHigh => '高';

  @override
  String get resolutionVeryHigh => '很高';

  @override
  String get resolutionUltraHigh => '超高';

  @override
  String get resolutionMax => '最大';

  @override
  String get flashOff => '关闭';

  @override
  String get flashAuto => '自动';

  @override
  String get flashAlways => '常开';

  @override
  String get flashTorch => '手电筒';

  @override
  String get tooltipSwitchCamera => '切换摄像头';

  @override
  String get tooltipLinkPhones => '连接手机';

  @override
  String get tooltipCaptureSettings => '拍摄设置';

  @override
  String get tooltipStopBuffer => '停止缓冲';

  @override
  String get tooltipStartBuffer => '开始缓冲';

  @override
  String get tooltipCaptureSwing => '拍摄挥击';

  @override
  String get tooltipFinishDatasetSession => '结束数据集会话';

  @override
  String get tooltipStartDatasetSession => '开始数据集会话';

  @override
  String get recordingIndicatorBuffer => '缓冲';

  @override
  String get done => '完成';

  @override
  String get statusIdle => '空闲';

  @override
  String get statusSaving => '保存中';

  @override
  String get statusHitterDetected => '已检测到击球手';

  @override
  String get statusReady => '就绪';

  @override
  String get statusSwingDetected => '已检测到挥击';

  @override
  String get statusManualRollingBuffer => '手动滚动缓冲';

  @override
  String statusTrackingModel(String modelName) {
    return '跟踪 $modelName';
  }

  @override
  String get previewStartedMonitoring => '预览已开始。正在监测击球手。';

  @override
  String get captureStopped => '拍摄已停止。';

  @override
  String get preRollBufferRunning => '前置缓冲运行中。';

  @override
  String get preRollBufferStopped => '前置缓冲已停止。';

  @override
  String get monitoringForHitter => '正在监测击球手。';

  @override
  String get hitterDetectedStabilizing => '已检测到击球手。等待姿态稳定。';

  @override
  String poseStableModelDescription(String modelDescription) {
    return '姿态已稳定。$modelDescription';
  }

  @override
  String get autoDetectionOffUseCaptureControl => '自动检测已关闭。请使用拍摄控件从滚动缓冲保存。';

  @override
  String get hitterLeftFrameIdle => '击球手离开画面。已回到空闲监测。';

  @override
  String swingLockedWithScore(String label, String score) {
    return '$label 已锁定。分数 $score。';
  }

  @override
  String ignoredLowConfidenceTrigger(String score, String threshold) {
    return '已忽略低置信度触发（$score < $threshold）。';
  }

  @override
  String get duplicateClipIgnored => '已忽略重复片段（已保存过）。';

  @override
  String get recordingSavedGalleryAndHistory => '录像已保存到相册和本地历史。';

  @override
  String get recordingSavedLocalHistory => '录像已保存到本地历史。';

  @override
  String get savedToHistoryAndPhotos => '已保存到本地历史和相册。';

  @override
  String get datasetSessionStarted => '数据集会话已开始。可拍摄多段片段。';

  @override
  String datasetSessionFinished(int count) {
    return '数据集会话已结束（$count 个片段）。';
  }

  @override
  String get swingCooldownActive => '挥击冷却中。';

  @override
  String swingCooldownActiveForSeconds(String seconds) {
    return '挥击冷却中，剩余 $seconds 秒。';
  }

  @override
  String get highSpeedRollingBufferUnavailable => '当前镜头不支持高速滚动缓冲。';

  @override
  String get nativeRollingBufferStarted => '原生滚动缓冲已启动。';

  @override
  String get startingNativeRollingBuffer => '正在启动原生滚动缓冲...';

  @override
  String get rollingBufferWaitingForSegment => '滚动缓冲正在等待相机片段。';

  @override
  String get nativeHighSpeedCaptureStarted => '原生高速拍摄已启动。';

  @override
  String get swingClipSaved => '挥击片段已保存。';

  @override
  String get nativeRollingBufferStillStarting => '原生滚动缓冲仍在启动中。';

  @override
  String get nativeRollingBufferFailed => '原生滚动缓冲失败。';

  @override
  String get nativeRollingBufferNoSegmentYet => '原生滚动缓冲尚未启动相机片段。';

  @override
  String get rollingBufferStopped => '滚动缓冲已停止。';

  @override
  String get savingBufferedClipNative => '正在从原生滚动缓冲保存片段。';

  @override
  String get savingPreRollClipLiveBuffer => '正在从实时缓冲保存前置片段。';

  @override
  String get clipSavedBufferStillArmed => '片段已保存。滚动缓冲仍处于待命状态。';

  @override
  String get nativeRollingBufferNotAvailable => '此版本不支持原生滚动缓冲。';

  @override
  String get savingBufferedClipFailed => '保存缓冲片段失败。';

  @override
  String get crossBodyMoveCapturing => '检测到跨体动作。正在保存缓冲片段。';

  @override
  String get manualCaptureArmedSaving => '手动拍摄已就绪。正在保存当前缓冲挥击。';

  @override
  String get manualCaptureArmedPostRoll => '已从滚动缓冲武装手动拍摄。正在采集后置段。';

  @override
  String get manualPreRollBufferStarted => '手动前置缓冲已启动。';

  @override
  String recordingProfileChecked(String summary) {
    return '录制配置已检查：$summary。';
  }

  @override
  String recordingSetToFastestSupported(String summary) {
    return '录制已设为最快支持模式：$summary。';
  }

  @override
  String get linkPhonesTitle => '连接手机';

  @override
  String get linkPhonesWifiInstructions => '请将两部手机连到同一 Wi-Fi。一部设为检测，另一部设为录制。';

  @override
  String get linkPhonesBluetoothInstructions =>
      '无 Wi-Fi 时可用蓝牙控制拍摄。两部手机重新连上 Wi-Fi 后会合并视频。';

  @override
  String get roleDetect => '检测';

  @override
  String get roleRecord => '录制';

  @override
  String get transportWifi => 'Wi-Fi';

  @override
  String get transportBluetooth => '蓝牙';

  @override
  String get linkLabelConnection => '连接';

  @override
  String get linkLabelThisPhone => '本机';

  @override
  String get linkLabelSync => '同步';

  @override
  String get linkLabelFrameRate => '帧率';

  @override
  String get paired => '已配对';

  @override
  String get pairedDeviceSection => '已配对设备';

  @override
  String get waitingForSecondPhone => '正在等待第二部手机。';

  @override
  String get dualCameraRoleSinglePhone => '单机';

  @override
  String get dualCameraRoleDetectorPhone => '检测手机';

  @override
  String get dualCameraRoleRecorderPhone => '录制手机';

  @override
  String get locationUnavailable => '位置不可用';

  @override
  String get grantCameraAccess => '授予相机权限';
}
