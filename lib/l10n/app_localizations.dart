import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'MotionCapture'**
  String get appTitle;

  /// No description provided for @navCapture.
  ///
  /// In en, this message translates to:
  /// **'Capture'**
  String get navCapture;

  /// No description provided for @navHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get navHistory;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @dontShowTestContent.
  ///
  /// In en, this message translates to:
  /// **'Don\'t show test content'**
  String get dontShowTestContent;

  /// No description provided for @performanceTests.
  ///
  /// In en, this message translates to:
  /// **'Performance tests'**
  String get performanceTests;

  /// No description provided for @recordingProfile.
  ///
  /// In en, this message translates to:
  /// **'Recording profile'**
  String get recordingProfile;

  /// No description provided for @poseDetection.
  ///
  /// In en, this message translates to:
  /// **'Pose detection'**
  String get poseDetection;

  /// No description provided for @poseProcessing.
  ///
  /// In en, this message translates to:
  /// **'Pose processing'**
  String get poseProcessing;

  /// No description provided for @checking.
  ///
  /// In en, this message translates to:
  /// **'Checking...'**
  String get checking;

  /// No description provided for @running.
  ///
  /// In en, this message translates to:
  /// **'Running...'**
  String get running;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @framesCandidates.
  ///
  /// In en, this message translates to:
  /// **'{frames} frames, {candidates} candidates'**
  String framesCandidates(int frames, int candidates);

  /// No description provided for @framesElapsedMs.
  ///
  /// In en, this message translates to:
  /// **'{frames} frames, {ms} ms'**
  String framesElapsedMs(int frames, int ms);

  /// No description provided for @fpsValue.
  ///
  /// In en, this message translates to:
  /// **'{fps} fps'**
  String fpsValue(String fps);

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose the live capture model and overlay behavior.'**
  String get settingsSubtitle;

  /// No description provided for @failedWithError.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String failedWithError(String error);

  /// No description provided for @showDebugSkeleton.
  ///
  /// In en, this message translates to:
  /// **'Show debug skeleton'**
  String get showDebugSkeleton;

  /// No description provided for @showDebugSkeletonSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Displays detector landmarks and future bounding boxes.'**
  String get showDebugSkeletonSubtitle;

  /// No description provided for @autoDetection.
  ///
  /// In en, this message translates to:
  /// **'Auto detection'**
  String get autoDetection;

  /// No description provided for @autoDetectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When on, MotionCapture uses the selected model to capture automatically. When off, capture stays manual and only saves when you trigger it on the Capture screen.'**
  String get autoDetectionSubtitle;

  /// No description provided for @autoSaveToGallery.
  ///
  /// In en, this message translates to:
  /// **'Auto-save to gallery'**
  String get autoSaveToGallery;

  /// No description provided for @autoSaveToGallerySubtitle.
  ///
  /// In en, this message translates to:
  /// **'When the native export pipeline is ready, clips go to the MotionCapture album.'**
  String get autoSaveToGallerySubtitle;

  /// No description provided for @settingsFooterNote.
  ///
  /// In en, this message translates to:
  /// **'Model names include the release date in YYYYMMDD format. On Android, volume keys can still fire capture while you are on Capture.'**
  String get settingsFooterNote;

  /// No description provided for @captureTfModel.
  ///
  /// In en, this message translates to:
  /// **'Capture TF model'**
  String get captureTfModel;

  /// No description provided for @captureTfModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick the live trigger model version used during capture.'**
  String get captureTfModelSubtitle;

  /// No description provided for @modelDrivesAutoCapture.
  ///
  /// In en, this message translates to:
  /// **'The selected model drives automatic swing capture.'**
  String get modelDrivesAutoCapture;

  /// No description provided for @autoDetectionOffWaiting.
  ///
  /// In en, this message translates to:
  /// **'Auto detection is off, so the selected model will wait until you turn it back on.'**
  String get autoDetectionOffWaiting;

  /// No description provided for @tfModelVersion.
  ///
  /// In en, this message translates to:
  /// **'TF model version'**
  String get tfModelVersion;

  /// No description provided for @historyTitle.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historyTitle;

  /// No description provided for @historyHelpNormal.
  ///
  /// In en, this message translates to:
  /// **'Clips you record are saved here. Long-press a tile to select, or tap Select. Export saves copies to your photo library.'**
  String get historyHelpNormal;

  /// No description provided for @historyHelpSelection.
  ///
  /// In en, this message translates to:
  /// **'Tap a clip to toggle selection. Use Export or Delete when ready.'**
  String get historyHelpSelection;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @select.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get select;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @selectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAll;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @noneSelected.
  ///
  /// In en, this message translates to:
  /// **'None selected'**
  String get noneSelected;

  /// No description provided for @nSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String nSelected(int count);

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteClipsTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete clips'**
  String get deleteClipsTitle;

  /// No description provided for @deleteClipsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Permanently delete {count} clip(s) from this device? Video files and thumbnails will be removed.'**
  String deleteClipsConfirm(int count);

  /// No description provided for @exportToPhotos.
  ///
  /// In en, this message translates to:
  /// **'Export to Photos'**
  String get exportToPhotos;

  /// No description provided for @exportClipsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Save {count} clip(s) to the {album} album?'**
  String exportClipsConfirm(int count, String album);

  /// No description provided for @selectClipsToExportHint.
  ///
  /// In en, this message translates to:
  /// **'Select clips to export, or cancel selection to export all.'**
  String get selectClipsToExportHint;

  /// No description provided for @savedClipsToPhotos.
  ///
  /// In en, this message translates to:
  /// **'Saved {count} clip(s) to Photos.'**
  String savedClipsToPhotos(int count);

  /// No description provided for @savedClipsPartial.
  ///
  /// In en, this message translates to:
  /// **'Saved {saved} clip(s); could not save {skipped}.'**
  String savedClipsPartial(int saved, int skipped);

  /// No description provided for @noCapturedSwingsYet.
  ///
  /// In en, this message translates to:
  /// **'No captured swings yet'**
  String get noCapturedSwingsYet;

  /// No description provided for @emptyHistoryHint.
  ///
  /// In en, this message translates to:
  /// **'Record a clip from Capture — it will show up here as a tile.'**
  String get emptyHistoryHint;

  /// No description provided for @captureDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Capture Detail'**
  String get captureDetailTitle;

  /// No description provided for @captureDetailIndexTitle.
  ///
  /// In en, this message translates to:
  /// **'Capture {index} / {total}'**
  String captureDetailIndexTitle(int index, int total);

  /// No description provided for @previousVideo.
  ///
  /// In en, this message translates to:
  /// **'Previous video'**
  String get previousVideo;

  /// No description provided for @nextVideo.
  ///
  /// In en, this message translates to:
  /// **'Next video'**
  String get nextVideo;

  /// No description provided for @addTagTitle.
  ///
  /// In en, this message translates to:
  /// **'Add tag'**
  String get addTagTitle;

  /// No description provided for @tagNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Tag name'**
  String get tagNameLabel;

  /// No description provided for @tagNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. forehand, backhand, warmup'**
  String get tagNameHint;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @exportSingleClipConfirm.
  ///
  /// In en, this message translates to:
  /// **'Save this clip to the {album} album?'**
  String exportSingleClipConfirm(String album);

  /// No description provided for @noTaggingActionToUndo.
  ///
  /// In en, this message translates to:
  /// **'No tagging action to undo.'**
  String get noTaggingActionToUndo;

  /// No description provided for @savedToPhotos.
  ///
  /// In en, this message translates to:
  /// **'Saved to Photos.'**
  String get savedToPhotos;

  /// No description provided for @couldNotSaveToPhotos.
  ///
  /// In en, this message translates to:
  /// **'Could not save to Photos.'**
  String get couldNotSaveToPhotos;

  /// No description provided for @videoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Video unavailable'**
  String get videoUnavailable;

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get unavailable;

  /// No description provided for @quickTaggingHint.
  ///
  /// In en, this message translates to:
  /// **'Quick tagging: swipe right=action, left=not action, up=custom tag, down=undo.'**
  String get quickTaggingHint;

  /// No description provided for @durationLabel.
  ///
  /// In en, this message translates to:
  /// **'Duration: {duration}'**
  String durationLabel(String duration);

  /// No description provided for @frameRateLabel.
  ///
  /// In en, this message translates to:
  /// **'Frame rate: {fps}'**
  String frameRateLabel(String fps);

  /// No description provided for @albumLabel.
  ///
  /// In en, this message translates to:
  /// **'Album: {album}'**
  String albumLabel(String album);

  /// No description provided for @locationLabel.
  ///
  /// In en, this message translates to:
  /// **'Location: {location}'**
  String locationLabel(String location);

  /// No description provided for @videoLabel.
  ///
  /// In en, this message translates to:
  /// **'Video: {fileName}'**
  String videoLabel(String fileName);

  /// No description provided for @reviewLabel.
  ///
  /// In en, this message translates to:
  /// **'Review: {review}'**
  String reviewLabel(String review);

  /// No description provided for @datasetLabel.
  ///
  /// In en, this message translates to:
  /// **'Dataset: {dataset}'**
  String datasetLabel(String dataset);

  /// No description provided for @tagLabel.
  ///
  /// In en, this message translates to:
  /// **'Tag: {tag}'**
  String tagLabel(String tag);

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'none'**
  String get none;

  /// No description provided for @onDeviceSwingClassifierTitle.
  ///
  /// In en, this message translates to:
  /// **'On-device Swing Classifier (TFLite)'**
  String get onDeviceSwingClassifierTitle;

  /// No description provided for @runOnDeviceInference.
  ///
  /// In en, this message translates to:
  /// **'Run On-device Inference'**
  String get runOnDeviceInference;

  /// No description provided for @modelPathOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Model path on device: <app-documents>/models/swing_classifier.tflite'**
  String get modelPathOnDevice;

  /// No description provided for @predictedLabel.
  ///
  /// In en, this message translates to:
  /// **'Predicted label: {label} ({confidence}%)'**
  String predictedLabel(String label, String confidence);

  /// No description provided for @classProbability.
  ///
  /// In en, this message translates to:
  /// **'{className}: {probability}%'**
  String classProbability(String className, String probability);

  /// No description provided for @noPoseJsonAvailable.
  ///
  /// In en, this message translates to:
  /// **'No pose JSON available for this clip.'**
  String get noPoseJsonAvailable;

  /// No description provided for @poseJsonFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'Pose JSON file not found: {path}'**
  String poseJsonFileNotFound(String path);

  /// No description provided for @onDeviceInferenceCompleted.
  ///
  /// In en, this message translates to:
  /// **'On-device inference completed.'**
  String get onDeviceInferenceCompleted;

  /// No description provided for @inferenceFailed.
  ///
  /// In en, this message translates to:
  /// **'Inference failed: {error}'**
  String inferenceFailed(String error);

  /// No description provided for @cameraPermissionRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Camera permission is required'**
  String get cameraPermissionRequiredTitle;

  /// No description provided for @cameraPermissionRequiredBody.
  ///
  /// In en, this message translates to:
  /// **'Grant camera access to open live preview and start recording.'**
  String get cameraPermissionRequiredBody;

  /// No description provided for @cameraPermissionRequiredMessage.
  ///
  /// In en, this message translates to:
  /// **'Camera permission is required to preview and record.'**
  String get cameraPermissionRequiredMessage;

  /// No description provided for @cameraReady.
  ///
  /// In en, this message translates to:
  /// **'Camera ready.'**
  String get cameraReady;

  /// No description provided for @cameraLoading.
  ///
  /// In en, this message translates to:
  /// **'Camera loading'**
  String get cameraLoading;

  /// No description provided for @cameraNotInitialized.
  ///
  /// In en, this message translates to:
  /// **'Camera is not initialized yet.'**
  String get cameraNotInitialized;

  /// No description provided for @couldNotRestoreCameraPreview.
  ///
  /// In en, this message translates to:
  /// **'Could not restore camera preview.'**
  String get couldNotRestoreCameraPreview;

  /// No description provided for @frontCamera.
  ///
  /// In en, this message translates to:
  /// **'Front Camera'**
  String get frontCamera;

  /// No description provided for @backCamera.
  ///
  /// In en, this message translates to:
  /// **'Back Camera'**
  String get backCamera;

  /// No description provided for @externalCamera.
  ///
  /// In en, this message translates to:
  /// **'External Camera'**
  String get externalCamera;

  /// No description provided for @captureSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Capture Settings'**
  String get captureSettingsTitle;

  /// No description provided for @resolutionSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get resolutionSectionTitle;

  /// No description provided for @flashSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Flash'**
  String get flashSectionTitle;

  /// No description provided for @openFullSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Open full settings'**
  String get openFullSettingsTitle;

  /// No description provided for @openFullSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Adjust model version, detection, and debug overlay.'**
  String get openFullSettingsSubtitle;

  /// No description provided for @resolutionLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get resolutionLow;

  /// No description provided for @resolutionMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get resolutionMedium;

  /// No description provided for @resolutionHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get resolutionHigh;

  /// No description provided for @resolutionVeryHigh.
  ///
  /// In en, this message translates to:
  /// **'Very High'**
  String get resolutionVeryHigh;

  /// No description provided for @resolutionUltraHigh.
  ///
  /// In en, this message translates to:
  /// **'Ultra High'**
  String get resolutionUltraHigh;

  /// No description provided for @resolutionMax.
  ///
  /// In en, this message translates to:
  /// **'Max'**
  String get resolutionMax;

  /// No description provided for @flashOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get flashOff;

  /// No description provided for @flashAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get flashAuto;

  /// No description provided for @flashAlways.
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get flashAlways;

  /// No description provided for @flashTorch.
  ///
  /// In en, this message translates to:
  /// **'Torch'**
  String get flashTorch;

  /// No description provided for @tooltipSwitchCamera.
  ///
  /// In en, this message translates to:
  /// **'Switch camera'**
  String get tooltipSwitchCamera;

  /// No description provided for @tooltipLinkPhones.
  ///
  /// In en, this message translates to:
  /// **'Link phones'**
  String get tooltipLinkPhones;

  /// No description provided for @tooltipCaptureSettings.
  ///
  /// In en, this message translates to:
  /// **'Capture settings'**
  String get tooltipCaptureSettings;

  /// No description provided for @tooltipStopBuffer.
  ///
  /// In en, this message translates to:
  /// **'Stop buffer'**
  String get tooltipStopBuffer;

  /// No description provided for @tooltipStartBuffer.
  ///
  /// In en, this message translates to:
  /// **'Start buffer'**
  String get tooltipStartBuffer;

  /// No description provided for @tooltipCaptureSwing.
  ///
  /// In en, this message translates to:
  /// **'Capture swing'**
  String get tooltipCaptureSwing;

  /// No description provided for @tooltipFinishDatasetSession.
  ///
  /// In en, this message translates to:
  /// **'Finish dataset session'**
  String get tooltipFinishDatasetSession;

  /// No description provided for @tooltipStartDatasetSession.
  ///
  /// In en, this message translates to:
  /// **'Start dataset session'**
  String get tooltipStartDatasetSession;

  /// No description provided for @recordingIndicatorBuffer.
  ///
  /// In en, this message translates to:
  /// **'BUFFER'**
  String get recordingIndicatorBuffer;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @statusIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get statusIdle;

  /// No description provided for @statusSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving'**
  String get statusSaving;

  /// No description provided for @statusHitterDetected.
  ///
  /// In en, this message translates to:
  /// **'Hitter detected'**
  String get statusHitterDetected;

  /// No description provided for @statusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get statusReady;

  /// No description provided for @statusSwingDetected.
  ///
  /// In en, this message translates to:
  /// **'Swing detected'**
  String get statusSwingDetected;

  /// No description provided for @statusManualRollingBuffer.
  ///
  /// In en, this message translates to:
  /// **'Manual rolling buffer'**
  String get statusManualRollingBuffer;

  /// No description provided for @statusTrackingModel.
  ///
  /// In en, this message translates to:
  /// **'Tracking {modelName}'**
  String statusTrackingModel(String modelName);

  /// No description provided for @previewStartedMonitoring.
  ///
  /// In en, this message translates to:
  /// **'Preview started. Monitoring for a hitter.'**
  String get previewStartedMonitoring;

  /// No description provided for @captureStopped.
  ///
  /// In en, this message translates to:
  /// **'Capture stopped.'**
  String get captureStopped;

  /// No description provided for @preRollBufferRunning.
  ///
  /// In en, this message translates to:
  /// **'Pre-roll buffer is running.'**
  String get preRollBufferRunning;

  /// No description provided for @preRollBufferStopped.
  ///
  /// In en, this message translates to:
  /// **'Pre-roll buffer stopped.'**
  String get preRollBufferStopped;

  /// No description provided for @monitoringForHitter.
  ///
  /// In en, this message translates to:
  /// **'Monitoring for a hitter.'**
  String get monitoringForHitter;

  /// No description provided for @hitterDetectedStabilizing.
  ///
  /// In en, this message translates to:
  /// **'Hitter detected. Holding until pose stabilizes.'**
  String get hitterDetectedStabilizing;

  /// No description provided for @poseStableModelDescription.
  ///
  /// In en, this message translates to:
  /// **'Pose is stable. {modelDescription}'**
  String poseStableModelDescription(String modelDescription);

  /// No description provided for @autoDetectionOffUseCaptureControl.
  ///
  /// In en, this message translates to:
  /// **'Auto detection is off. Use the capture control to save from the rolling buffer.'**
  String get autoDetectionOffUseCaptureControl;

  /// No description provided for @hitterLeftFrameIdle.
  ///
  /// In en, this message translates to:
  /// **'Hitter left frame. Returned to idle monitoring.'**
  String get hitterLeftFrameIdle;

  /// No description provided for @swingLockedWithScore.
  ///
  /// In en, this message translates to:
  /// **'{label} locked. Score {score}.'**
  String swingLockedWithScore(String label, String score);

  /// No description provided for @ignoredLowConfidenceTrigger.
  ///
  /// In en, this message translates to:
  /// **'Ignored low-confidence trigger ({score} < {threshold}).'**
  String ignoredLowConfidenceTrigger(String score, String threshold);

  /// No description provided for @duplicateClipIgnored.
  ///
  /// In en, this message translates to:
  /// **'Duplicate clip ignored (already saved).'**
  String get duplicateClipIgnored;

  /// No description provided for @recordingSavedGalleryAndHistory.
  ///
  /// In en, this message translates to:
  /// **'Recording saved to gallery and local history.'**
  String get recordingSavedGalleryAndHistory;

  /// No description provided for @recordingSavedLocalHistory.
  ///
  /// In en, this message translates to:
  /// **'Recording saved to local history.'**
  String get recordingSavedLocalHistory;

  /// No description provided for @savedToHistoryAndPhotos.
  ///
  /// In en, this message translates to:
  /// **'Saved to local history and Photos.'**
  String get savedToHistoryAndPhotos;

  /// No description provided for @datasetSessionStarted.
  ///
  /// In en, this message translates to:
  /// **'Dataset session started. Capture multiple clips.'**
  String get datasetSessionStarted;

  /// No description provided for @datasetSessionFinished.
  ///
  /// In en, this message translates to:
  /// **'Dataset session finished ({count} clips).'**
  String datasetSessionFinished(int count);

  /// No description provided for @swingCooldownActive.
  ///
  /// In en, this message translates to:
  /// **'Swing cooldown is active.'**
  String get swingCooldownActive;

  /// No description provided for @swingCooldownActiveForSeconds.
  ///
  /// In en, this message translates to:
  /// **'Swing cooldown active for {seconds}s.'**
  String swingCooldownActiveForSeconds(String seconds);

  /// No description provided for @highSpeedRollingBufferUnavailable.
  ///
  /// In en, this message translates to:
  /// **'High-speed rolling buffer is unavailable on this lens.'**
  String get highSpeedRollingBufferUnavailable;

  /// No description provided for @nativeRollingBufferStarted.
  ///
  /// In en, this message translates to:
  /// **'Native rolling buffer started.'**
  String get nativeRollingBufferStarted;

  /// No description provided for @startingNativeRollingBuffer.
  ///
  /// In en, this message translates to:
  /// **'Starting native rolling buffer...'**
  String get startingNativeRollingBuffer;

  /// No description provided for @rollingBufferWaitingForSegment.
  ///
  /// In en, this message translates to:
  /// **'Rolling buffer is waiting for a camera segment.'**
  String get rollingBufferWaitingForSegment;

  /// No description provided for @nativeHighSpeedCaptureStarted.
  ///
  /// In en, this message translates to:
  /// **'Native high-speed capture started.'**
  String get nativeHighSpeedCaptureStarted;

  /// No description provided for @swingClipSaved.
  ///
  /// In en, this message translates to:
  /// **'Swing clip saved.'**
  String get swingClipSaved;

  /// No description provided for @nativeRollingBufferStillStarting.
  ///
  /// In en, this message translates to:
  /// **'Native rolling buffer is still starting.'**
  String get nativeRollingBufferStillStarting;

  /// No description provided for @nativeRollingBufferFailed.
  ///
  /// In en, this message translates to:
  /// **'Native rolling buffer failed.'**
  String get nativeRollingBufferFailed;

  /// No description provided for @nativeRollingBufferNoSegmentYet.
  ///
  /// In en, this message translates to:
  /// **'Native rolling buffer did not start a camera segment yet.'**
  String get nativeRollingBufferNoSegmentYet;

  /// No description provided for @rollingBufferStopped.
  ///
  /// In en, this message translates to:
  /// **'Rolling buffer stopped.'**
  String get rollingBufferStopped;

  /// No description provided for @savingBufferedClipNative.
  ///
  /// In en, this message translates to:
  /// **'Saving buffered clip from native rolling buffer.'**
  String get savingBufferedClipNative;

  /// No description provided for @savingPreRollClipLiveBuffer.
  ///
  /// In en, this message translates to:
  /// **'Saving pre-roll clip from the live buffer.'**
  String get savingPreRollClipLiveBuffer;

  /// No description provided for @clipSavedBufferStillArmed.
  ///
  /// In en, this message translates to:
  /// **'Clip saved. Rolling buffer is still armed.'**
  String get clipSavedBufferStillArmed;

  /// No description provided for @nativeRollingBufferNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Native rolling buffer is not available in this build.'**
  String get nativeRollingBufferNotAvailable;

  /// No description provided for @savingBufferedClipFailed.
  ///
  /// In en, this message translates to:
  /// **'Saving buffered clip failed.'**
  String get savingBufferedClipFailed;

  /// No description provided for @crossBodyMoveCapturing.
  ///
  /// In en, this message translates to:
  /// **'Cross-body move detected. Capturing buffered clip now.'**
  String get crossBodyMoveCapturing;

  /// No description provided for @manualCaptureArmedSaving.
  ///
  /// In en, this message translates to:
  /// **'Manual capture armed. Saving the current buffered swing.'**
  String get manualCaptureArmedSaving;

  /// No description provided for @manualCaptureArmedPostRoll.
  ///
  /// In en, this message translates to:
  /// **'Manual capture armed from rolling buffer. Collecting post-roll.'**
  String get manualCaptureArmedPostRoll;

  /// No description provided for @manualPreRollBufferStarted.
  ///
  /// In en, this message translates to:
  /// **'Manual pre-roll buffer started.'**
  String get manualPreRollBufferStarted;

  /// No description provided for @recordingProfileChecked.
  ///
  /// In en, this message translates to:
  /// **'Recording profile checked: {summary}.'**
  String recordingProfileChecked(String summary);

  /// No description provided for @recordingSetToFastestSupported.
  ///
  /// In en, this message translates to:
  /// **'Recording set to fastest supported mode: {summary}.'**
  String recordingSetToFastestSupported(String summary);

  /// No description provided for @linkPhonesTitle.
  ///
  /// In en, this message translates to:
  /// **'Link phones'**
  String get linkPhonesTitle;

  /// No description provided for @linkPhonesWifiInstructions.
  ///
  /// In en, this message translates to:
  /// **'Put both phones on the same Wi-Fi. Set one phone to Detect and the other to Record.'**
  String get linkPhonesWifiInstructions;

  /// No description provided for @linkPhonesBluetoothInstructions.
  ///
  /// In en, this message translates to:
  /// **'Use Bluetooth for capture control when Wi-Fi is unavailable. Videos will merge after both phones reconnect on Wi-Fi.'**
  String get linkPhonesBluetoothInstructions;

  /// No description provided for @roleDetect.
  ///
  /// In en, this message translates to:
  /// **'Detect'**
  String get roleDetect;

  /// No description provided for @roleRecord.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get roleRecord;

  /// No description provided for @transportWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi'**
  String get transportWifi;

  /// No description provided for @transportBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get transportBluetooth;

  /// No description provided for @linkLabelConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get linkLabelConnection;

  /// No description provided for @linkLabelThisPhone.
  ///
  /// In en, this message translates to:
  /// **'This phone'**
  String get linkLabelThisPhone;

  /// No description provided for @linkLabelSync.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get linkLabelSync;

  /// No description provided for @linkLabelFrameRate.
  ///
  /// In en, this message translates to:
  /// **'Frame rate'**
  String get linkLabelFrameRate;

  /// No description provided for @paired.
  ///
  /// In en, this message translates to:
  /// **'Paired'**
  String get paired;

  /// No description provided for @pairedDeviceSection.
  ///
  /// In en, this message translates to:
  /// **'Paired device'**
  String get pairedDeviceSection;

  /// No description provided for @waitingForSecondPhone.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the second phone.'**
  String get waitingForSecondPhone;

  /// No description provided for @dualCameraRoleSinglePhone.
  ///
  /// In en, this message translates to:
  /// **'Single phone'**
  String get dualCameraRoleSinglePhone;

  /// No description provided for @dualCameraRoleDetectorPhone.
  ///
  /// In en, this message translates to:
  /// **'Detector phone'**
  String get dualCameraRoleDetectorPhone;

  /// No description provided for @dualCameraRoleRecorderPhone.
  ///
  /// In en, this message translates to:
  /// **'Recorder phone'**
  String get dualCameraRoleRecorderPhone;

  /// No description provided for @locationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Location unavailable'**
  String get locationUnavailable;

  /// No description provided for @grantCameraAccess.
  ///
  /// In en, this message translates to:
  /// **'Grant camera access'**
  String get grantCameraAccess;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
