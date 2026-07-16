// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'MotionCapture';

  @override
  String get navCapture => 'Capture';

  @override
  String get navHistory => 'History';

  @override
  String get navSettings => 'Settings';

  @override
  String get dontShowTestContent => 'Don\'t show test content';

  @override
  String get performanceTests => 'Performance tests';

  @override
  String get recordingProfile => 'Recording profile';

  @override
  String get poseDetection => 'Pose detection';

  @override
  String get poseProcessing => 'Pose processing';

  @override
  String get checking => 'Checking...';

  @override
  String get running => 'Running...';

  @override
  String get close => 'Close';

  @override
  String framesCandidates(int frames, int candidates) {
    return '$frames frames, $candidates candidates';
  }

  @override
  String framesElapsedMs(int frames, int ms) {
    return '$frames frames, $ms ms';
  }

  @override
  String fpsValue(String fps) {
    return '$fps fps';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSubtitle =>
      'Choose the live capture model and overlay behavior.';

  @override
  String failedWithError(String error) {
    return 'Failed: $error';
  }

  @override
  String get showDebugSkeleton => 'Show debug skeleton';

  @override
  String get showDebugSkeletonSubtitle =>
      'Displays detector landmarks and future bounding boxes.';

  @override
  String get autoDetection => 'Auto detection';

  @override
  String get autoDetectionSubtitle =>
      'When on, MotionCapture uses the selected model to capture automatically. When off, capture stays manual and only saves when you trigger it on the Capture screen.';

  @override
  String get autoSaveToGallery => 'Auto-save to gallery';

  @override
  String get autoSaveToGallerySubtitle =>
      'When the native export pipeline is ready, clips go to the MotionCapture album.';

  @override
  String get settingsFooterNote =>
      'Model names include the release date in YYYYMMDD format. On Android, volume keys can still fire capture while you are on Capture.';

  @override
  String get captureTfModel => 'Capture TF model';

  @override
  String get captureTfModelSubtitle =>
      'Pick the live trigger model version used during capture.';

  @override
  String get modelDrivesAutoCapture =>
      'The selected model drives automatic swing capture.';

  @override
  String get autoDetectionOffWaiting =>
      'Auto detection is off, so the selected model will wait until you turn it back on.';

  @override
  String get tfModelVersion => 'TF model version';

  @override
  String get historyTitle => 'History';

  @override
  String get historyHelpNormal =>
      'Clips you record are saved here. Long-press a tile to select, or tap Select. Export saves copies to your photo library.';

  @override
  String get historyHelpSelection =>
      'Tap a clip to toggle selection. Use Export or Delete when ready.';

  @override
  String get export => 'Export';

  @override
  String get select => 'Select';

  @override
  String get cancel => 'Cancel';

  @override
  String get selectAll => 'Select all';

  @override
  String get clear => 'Clear';

  @override
  String get noneSelected => 'None selected';

  @override
  String nSelected(int count) {
    return '$count selected';
  }

  @override
  String get delete => 'Delete';

  @override
  String get deleteClipsTitle => 'Delete clips';

  @override
  String deleteClipsConfirm(int count) {
    return 'Permanently delete $count clip(s) from this device? Video files and thumbnails will be removed.';
  }

  @override
  String get exportToPhotos => 'Export to Photos';

  @override
  String exportClipsConfirm(int count, String album) {
    return 'Save $count clip(s) to the $album album?';
  }

  @override
  String get selectClipsToExportHint =>
      'Select clips to export, or cancel selection to export all.';

  @override
  String savedClipsToPhotos(int count) {
    return 'Saved $count clip(s) to Photos.';
  }

  @override
  String savedClipsPartial(int saved, int skipped) {
    return 'Saved $saved clip(s); could not save $skipped.';
  }

  @override
  String get noCapturedSwingsYet => 'No captured swings yet';

  @override
  String get emptyHistoryHint =>
      'Record a clip from Capture — it will show up here as a tile.';

  @override
  String get captureDetailTitle => 'Capture Detail';

  @override
  String captureDetailIndexTitle(int index, int total) {
    return 'Capture $index / $total';
  }

  @override
  String get previousVideo => 'Previous video';

  @override
  String get nextVideo => 'Next video';

  @override
  String get addTagTitle => 'Add tag';

  @override
  String get tagNameLabel => 'Tag name';

  @override
  String get tagNameHint => 'e.g. forehand, backhand, warmup';

  @override
  String get save => 'Save';

  @override
  String exportSingleClipConfirm(String album) {
    return 'Save this clip to the $album album?';
  }

  @override
  String get noTaggingActionToUndo => 'No tagging action to undo.';

  @override
  String get savedToPhotos => 'Saved to Photos.';

  @override
  String get couldNotSaveToPhotos => 'Could not save to Photos.';

  @override
  String get videoUnavailable => 'Video unavailable';

  @override
  String get unavailable => 'Unavailable';

  @override
  String get quickTaggingHint =>
      'Quick tagging: swipe right=action, left=not action, up=custom tag, down=undo.';

  @override
  String durationLabel(String duration) {
    return 'Duration: $duration';
  }

  @override
  String frameRateLabel(String fps) {
    return 'Frame rate: $fps';
  }

  @override
  String albumLabel(String album) {
    return 'Album: $album';
  }

  @override
  String locationLabel(String location) {
    return 'Location: $location';
  }

  @override
  String videoLabel(String fileName) {
    return 'Video: $fileName';
  }

  @override
  String reviewLabel(String review) {
    return 'Review: $review';
  }

  @override
  String datasetLabel(String dataset) {
    return 'Dataset: $dataset';
  }

  @override
  String tagLabel(String tag) {
    return 'Tag: $tag';
  }

  @override
  String get none => 'none';

  @override
  String get onDeviceSwingClassifierTitle =>
      'On-device Swing Classifier (TFLite)';

  @override
  String get runOnDeviceInference => 'Run On-device Inference';

  @override
  String get modelPathOnDevice =>
      'Model path on device: <app-documents>/models/swing_classifier.tflite';

  @override
  String predictedLabel(String label, String confidence) {
    return 'Predicted label: $label ($confidence%)';
  }

  @override
  String classProbability(String className, String probability) {
    return '$className: $probability%';
  }

  @override
  String get noPoseJsonAvailable => 'No pose JSON available for this clip.';

  @override
  String poseJsonFileNotFound(String path) {
    return 'Pose JSON file not found: $path';
  }

  @override
  String get onDeviceInferenceCompleted => 'On-device inference completed.';

  @override
  String inferenceFailed(String error) {
    return 'Inference failed: $error';
  }

  @override
  String get cameraPermissionRequiredTitle => 'Camera permission is required';

  @override
  String get cameraPermissionRequiredBody =>
      'Grant camera access to open live preview and start recording.';

  @override
  String get cameraPermissionRequiredMessage =>
      'Camera permission is required to preview and record.';

  @override
  String get cameraReady => 'Camera ready.';

  @override
  String get cameraLoading => 'Camera loading';

  @override
  String get cameraNotInitialized => 'Camera is not initialized yet.';

  @override
  String get couldNotRestoreCameraPreview =>
      'Could not restore camera preview.';

  @override
  String get frontCamera => 'Front Camera';

  @override
  String get backCamera => 'Back Camera';

  @override
  String get externalCamera => 'External Camera';

  @override
  String get captureSettingsTitle => 'Capture Settings';

  @override
  String get resolutionSectionTitle => 'Resolution';

  @override
  String get flashSectionTitle => 'Flash';

  @override
  String get openFullSettingsTitle => 'Open full settings';

  @override
  String get openFullSettingsSubtitle =>
      'Adjust model version, detection, and debug overlay.';

  @override
  String get resolutionLow => 'Low';

  @override
  String get resolutionMedium => 'Medium';

  @override
  String get resolutionHigh => 'High';

  @override
  String get resolutionVeryHigh => 'Very High';

  @override
  String get resolutionUltraHigh => 'Ultra High';

  @override
  String get resolutionMax => 'Max';

  @override
  String get flashOff => 'Off';

  @override
  String get flashAuto => 'Auto';

  @override
  String get flashAlways => 'Always';

  @override
  String get flashTorch => 'Torch';

  @override
  String get tooltipSwitchCamera => 'Switch camera';

  @override
  String get tooltipLinkPhones => 'Link phones';

  @override
  String get tooltipCaptureSettings => 'Capture settings';

  @override
  String get tooltipStopBuffer => 'Stop buffer';

  @override
  String get tooltipStartBuffer => 'Start buffer';

  @override
  String get tooltipCaptureSwing => 'Capture swing';

  @override
  String get tooltipFinishDatasetSession => 'Finish dataset session';

  @override
  String get tooltipStartDatasetSession => 'Start dataset session';

  @override
  String get recordingIndicatorBuffer => 'BUFFER';

  @override
  String get done => 'Done';

  @override
  String get statusIdle => 'Idle';

  @override
  String get statusSaving => 'Saving';

  @override
  String get statusHitterDetected => 'Hitter detected';

  @override
  String get statusReady => 'Ready';

  @override
  String get statusSwingDetected => 'Swing detected';

  @override
  String get statusManualRollingBuffer => 'Manual rolling buffer';

  @override
  String statusTrackingModel(String modelName) {
    return 'Tracking $modelName';
  }

  @override
  String get previewStartedMonitoring =>
      'Preview started. Monitoring for a hitter.';

  @override
  String get captureStopped => 'Capture stopped.';

  @override
  String get preRollBufferRunning => 'Pre-roll buffer is running.';

  @override
  String get preRollBufferStopped => 'Pre-roll buffer stopped.';

  @override
  String get monitoringForHitter => 'Monitoring for a hitter.';

  @override
  String get hitterDetectedStabilizing =>
      'Hitter detected. Holding until pose stabilizes.';

  @override
  String poseStableModelDescription(String modelDescription) {
    return 'Pose is stable. $modelDescription';
  }

  @override
  String get autoDetectionOffUseCaptureControl =>
      'Auto detection is off. Use the capture control to save from the rolling buffer.';

  @override
  String get hitterLeftFrameIdle =>
      'Hitter left frame. Returned to idle monitoring.';

  @override
  String swingLockedWithScore(String label, String score) {
    return '$label locked. Score $score.';
  }

  @override
  String ignoredLowConfidenceTrigger(String score, String threshold) {
    return 'Ignored low-confidence trigger ($score < $threshold).';
  }

  @override
  String get duplicateClipIgnored => 'Duplicate clip ignored (already saved).';

  @override
  String get recordingSavedGalleryAndHistory =>
      'Recording saved to gallery and local history.';

  @override
  String get recordingSavedLocalHistory => 'Recording saved to local history.';

  @override
  String get savedToHistoryAndPhotos => 'Saved to local history and Photos.';

  @override
  String get datasetSessionStarted =>
      'Dataset session started. Capture multiple clips.';

  @override
  String datasetSessionFinished(int count) {
    return 'Dataset session finished ($count clips).';
  }

  @override
  String get swingCooldownActive => 'Swing cooldown is active.';

  @override
  String swingCooldownActiveForSeconds(String seconds) {
    return 'Swing cooldown active for ${seconds}s.';
  }

  @override
  String get highSpeedRollingBufferUnavailable =>
      'High-speed rolling buffer is unavailable on this lens.';

  @override
  String get nativeRollingBufferStarted => 'Native rolling buffer started.';

  @override
  String get startingNativeRollingBuffer => 'Starting native rolling buffer...';

  @override
  String get rollingBufferWaitingForSegment =>
      'Rolling buffer is waiting for a camera segment.';

  @override
  String get nativeHighSpeedCaptureStarted =>
      'Native high-speed capture started.';

  @override
  String get swingClipSaved => 'Swing clip saved.';

  @override
  String get nativeRollingBufferStillStarting =>
      'Native rolling buffer is still starting.';

  @override
  String get nativeRollingBufferFailed => 'Native rolling buffer failed.';

  @override
  String get nativeRollingBufferNoSegmentYet =>
      'Native rolling buffer did not start a camera segment yet.';

  @override
  String get rollingBufferStopped => 'Rolling buffer stopped.';

  @override
  String get savingBufferedClipNative =>
      'Saving buffered clip from native rolling buffer.';

  @override
  String get savingPreRollClipLiveBuffer =>
      'Saving pre-roll clip from the live buffer.';

  @override
  String get clipSavedBufferStillArmed =>
      'Clip saved. Rolling buffer is still armed.';

  @override
  String get nativeRollingBufferNotAvailable =>
      'Native rolling buffer is not available in this build.';

  @override
  String get savingBufferedClipFailed => 'Saving buffered clip failed.';

  @override
  String get crossBodyMoveCapturing =>
      'Cross-body move detected. Capturing buffered clip now.';

  @override
  String get manualCaptureArmedSaving =>
      'Manual capture armed. Saving the current buffered swing.';

  @override
  String get manualCaptureArmedPostRoll =>
      'Manual capture armed from rolling buffer. Collecting post-roll.';

  @override
  String get manualPreRollBufferStarted => 'Manual pre-roll buffer started.';

  @override
  String recordingProfileChecked(String summary) {
    return 'Recording profile checked: $summary.';
  }

  @override
  String recordingSetToFastestSupported(String summary) {
    return 'Recording set to fastest supported mode: $summary.';
  }

  @override
  String get linkPhonesTitle => 'Link phones';

  @override
  String get linkPhonesWifiInstructions =>
      'Put both phones on the same Wi-Fi. Set one phone to Detect and the other to Record.';

  @override
  String get linkPhonesBluetoothInstructions =>
      'Use Bluetooth for capture control when Wi-Fi is unavailable. Videos will merge after both phones reconnect on Wi-Fi.';

  @override
  String get roleDetect => 'Detect';

  @override
  String get roleRecord => 'Record';

  @override
  String get transportWifi => 'Wi-Fi';

  @override
  String get transportBluetooth => 'Bluetooth';

  @override
  String get linkLabelConnection => 'Connection';

  @override
  String get linkLabelThisPhone => 'This phone';

  @override
  String get linkLabelSync => 'Sync';

  @override
  String get linkLabelFrameRate => 'Frame rate';

  @override
  String get paired => 'Paired';

  @override
  String get pairedDeviceSection => 'Paired device';

  @override
  String get waitingForSecondPhone => 'Waiting for the second phone.';

  @override
  String get dualCameraRoleSinglePhone => 'Single phone';

  @override
  String get dualCameraRoleDetectorPhone => 'Detector phone';

  @override
  String get dualCameraRoleRecorderPhone => 'Recorder phone';

  @override
  String get locationUnavailable => 'Location unavailable';

  @override
  String get grantCameraAccess => 'Grant camera access';
}
