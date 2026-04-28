import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../app/providers.dart';
import '../../../../core/config/app_constants.dart';
import '../../../../core/models/action_event.dart';
import '../../../../core/models/capture_location_metadata.dart';
import '../../../../core/models/capture_settings.dart';
import '../../../../core/models/detection_state.dart';
import '../../../../core/services/location_metadata_service.dart';
import '../../../../core/services/video_thumbnail_service.dart';
import '../../data/pose_clip_json_service.dart';
import '../../data/pose_detection_service.dart';
import '../../domain/models/pose_frame.dart';
import '../../domain/patterns/action_pattern_catalog.dart';
import '../../domain/patterns/capture_model_catalog.dart';
import '../../../../platform_channels/capture_platform_channel.dart';
import '../controllers/capture_controller.dart';
import '../widgets/android_native_camera_preview.dart';

class CapturePage extends ConsumerStatefulWidget {
  const CapturePage({super.key});

  @override
  ConsumerState<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends ConsumerState<CapturePage>
    with WidgetsBindingObserver {
  static const LocationMetadataService _locationMetadataService =
      LocationMetadataService();
  static const VideoThumbnailService _videoThumbnailService =
      VideoThumbnailService();
  static const PoseClipJsonService _poseClipJsonService = PoseClipJsonService();
  static const Duration _poseBufferLookback = Duration(seconds: 90);

  final CapturePlatformChannel _capturePlatformChannel =
      const CapturePlatformChannel();
  final List<CameraDescription> _cameras = [];
  final PoseDetectionService _poseDetectionService = PoseDetectionService();

  CameraController? _cameraController;
  StreamSubscription<NativeCaptureEvent>? _nativeCaptureSubscription;
  int _selectedCameraIndex = -1;
  ResolutionPreset _resolutionPreset = ResolutionPreset.high;
  FlashMode _flashMode = FlashMode.off;
  bool _enableAudio = false;
  bool _isOpeningCamera = false;
  DateTime? _recordingStartedAt;
  ActionEvent? _pendingSwingEvent;
  Timer? _autoStopTimer;
  Timer? _captureCooldownTimer;
  Timer? _recordingFrameWatchdog;
  bool _isFinalizingBufferedClip = false;
  bool _isStreamingImages = false;
  bool _autoStartedRecording = false;
  bool _rearmBufferAfterCooldown = false;
  DateTime? _lastRecordingFrameAt;
  int _recordingFrameCount = 0;
  DateTime? _captureLockedUntil;

  double? _minZoom;
  double? _maxZoom;
  double? _zoom;
  double? _scaleGestureStartZoom;
  String _nativeLensDirection = 'back';
  bool _nativePreviewReady = false;
  DateTime? _lastNativePoseHandledAt;
  final List<PoseFrame> _poseFrameBuffer = <PoseFrame>[];

  static const EventChannel _volumeKeyChannel = EventChannel(
    'swingcapture/volume_keys',
  );
  StreamSubscription<dynamic>? _volumeKeySubscription;
  DateTime? _lastHardwareTriggerActionAt;

  bool get _isCameraReady => _useNativeAndroidPipeline
      ? _nativePreviewReady
      : (_cameraController != null && _cameraController!.value.isInitialized);

  bool get _useNativeAndroidPipeline => Platform.isAndroid;
  static const double _nativePoseAspectRatio = 9 / 16;

  bool _autoDetectionEnabled(CaptureSettings settings) {
    return settings.autoRecordOnReady;
  }

  Future<void> _ensureNativeRollingBufferArmed() async {
    if (!_useNativeAndroidPipeline) {
      return;
    }
    if (_isCaptureLocked()) {
      return;
    }
    if (ref.read(captureControllerProvider).isRecording) {
      return;
    }
    await _startNativeRollingBuffer();
  }

  ActionEvent _fallbackSwingEvent([DateTime? triggeredAt]) {
    final settings =
        ref.read(settingsControllerProvider).valueOrNull ??
        CaptureSettings.defaults();
    final actionPatternId = CaptureModelCatalog.actionPatternIdFor(
      settings.captureModelId,
    );
    final pattern = ActionPatternCatalog.resolve(
      actionPatternId,
      preRollMs: (settings.preRollSeconds * 1000).round(),
      postRollMs: (settings.postRollSeconds * 1000).round(),
      cooldownMs: settings.swingCooldownMs,
    );
    final resolvedTriggeredAt = triggeredAt ?? DateTime.now();
    final preRollMs = (settings.preRollSeconds * 1000).round();
    final postRollMs = (settings.postRollSeconds * 1000).round();
    return ActionEvent(
      label: pattern.label,
      category: pattern.category,
      triggeredAt: resolvedTriggeredAt,
      score: 1,
      preRollMs: preRollMs,
      postRollMs: postRollMs,
      windowStartAt: resolvedTriggeredAt.subtract(
        Duration(milliseconds: preRollMs),
      ),
      windowEndAt: resolvedTriggeredAt.add(Duration(milliseconds: postRollMs)),
      reason: 'manual trigger',
    );
  }

  int _eventPreRollMs(ActionEvent event) {
    return event.triggeredAt
        .difference(event.resolvedWindowStartAt)
        .inMilliseconds
        .clamp(0, 60000);
  }

  int _eventPostRollMs(ActionEvent event) {
    return event.resolvedWindowEndAt
        .difference(event.triggeredAt)
        .inMilliseconds
        .clamp(0, 60000);
  }

  int _eventWindowDurationMs(ActionEvent event) {
    return event.resolvedWindowEndAt
        .difference(event.resolvedWindowStartAt)
        .inMilliseconds
        .clamp(0, 60000);
  }

  Duration _captureCooldownDuration() {
    final settings =
        ref.read(settingsControllerProvider).valueOrNull ??
        CaptureSettings.defaults();
    return Duration(milliseconds: settings.swingCooldownMs);
  }

  bool _isCaptureLocked([DateTime? now]) {
    final lockedUntil = _captureLockedUntil;
    if (lockedUntil == null) {
      return false;
    }
    return (now ?? DateTime.now()).isBefore(lockedUntil);
  }

  String _captureCooldownMessage() {
    final lockedUntil = _captureLockedUntil;
    if (lockedUntil == null) {
      return 'Swing cooldown is active.';
    }
    final remainingMs = lockedUntil.difference(DateTime.now()).inMilliseconds;
    final remainingSeconds = (remainingMs / 1000).clamp(0, double.infinity);
    return 'Swing cooldown active for ${remainingSeconds.toStringAsFixed(1)}s.';
  }

  void _armCaptureLock(
    ActionEvent event, {
    bool rearmBufferAfterCooldown = false,
  }) {
    final now = DateTime.now();
    final cooldown = _captureCooldownDuration();
    final eventLockUntil = event.triggeredAt.add(cooldown);
    final lockUntil = eventLockUntil.isAfter(now)
        ? eventLockUntil
        : now.add(cooldown);

    if (_captureLockedUntil == null ||
        lockUntil.isAfter(_captureLockedUntil!)) {
      _captureLockedUntil = lockUntil;
    }
    _rearmBufferAfterCooldown =
        _rearmBufferAfterCooldown || rearmBufferAfterCooldown;
    _captureCooldownTimer?.cancel();

    final wait = _captureLockedUntil!.difference(DateTime.now());
    _captureCooldownTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _captureLockedUntil = null;
      _captureCooldownTimer = null;
      final shouldRearm = _rearmBufferAfterCooldown;
      _rearmBufferAfterCooldown = false;
      if (!mounted || !shouldRearm) {
        return;
      }
      unawaited(_resumeBufferAfterCooldown());
    });
  }

  Future<void> _resumeBufferAfterCooldown() async {
    if (!mounted) {
      return;
    }
    final captureState = ref.read(captureControllerProvider);
    if (!captureState.isRunning) {
      return;
    }
    if (_useNativeAndroidPipeline) {
      await _ensureNativeRollingBufferArmed();
      return;
    }
    if (!_isCameraReady ||
        (_cameraController?.value.isRecordingVideo ?? false)) {
      return;
    }
    await _startManualPreRollBuffer();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_useNativeAndroidPipeline) {
      _nativeCaptureSubscription = _capturePlatformChannel
          .captureEvents()
          .listen(_onNativeCaptureEvent);
    }
    unawaited(_prepareCameraAccess());
    if (Platform.isAndroid) {
      final onCaptureTab = ref.read(appTabProvider) == 0;
      unawaited(_capturePlatformChannel.setVolumeKeysConsumed(onCaptureTab));
      _volumeKeySubscription = _volumeKeyChannel
          .receiveBroadcastStream()
          .listen((_) => _onHardwareTriggerAction());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoStopTimer?.cancel();
    _captureCooldownTimer?.cancel();
    _recordingFrameWatchdog?.cancel();
    _volumeKeySubscription?.cancel();
    _nativeCaptureSubscription?.cancel();
    _nativeCaptureSubscription = null;
    _volumeKeySubscription = null;
    if (Platform.isAndroid) {
      unawaited(_capturePlatformChannel.setVolumeKeysConsumed(false));
    }
    unawaited(WakelockPlus.disable());
    unawaited(_disposeCameraController());
    unawaited(_poseDetectionService.dispose());
    super.dispose();
  }

  void _onHardwareTriggerAction() {
    if (!mounted || !Platform.isAndroid) {
      return;
    }
    if (ref.read(appTabProvider) != 0) {
      return;
    }
    _debouncedHardwareTriggerAction();
  }

  void _debouncedHardwareTriggerAction() {
    final now = DateTime.now();
    if (_lastHardwareTriggerActionAt != null &&
        now.difference(_lastHardwareTriggerActionAt!) <
            const Duration(milliseconds: 450)) {
      return;
    }
    _lastHardwareTriggerActionAt = now;
    unawaited(_triggerSwingEvent());
  }

  void _onNativeCaptureEvent(NativeCaptureEvent event) {
    if (!mounted) {
      return;
    }

    switch (event) {
      case NativePoseEvent():
        final now = DateTime.now();
        if (_lastNativePoseHandledAt != null &&
            now.difference(_lastNativePoseHandledAt!) <
                const Duration(milliseconds: 80)) {
          break;
        }
        _lastNativePoseHandledAt = now;
        unawaited(_forwardPoseFrame(_poseFrameFromNativeEvent(event)));
      case NativeCameraStateEvent():
        setState(() {
          _nativeLensDirection = event.lensDirection;
          _minZoom = event.minZoom;
          _maxZoom = event.maxZoom;
          _zoom = event.zoom.clamp(event.minZoom, event.maxZoom);
          _nativePreviewReady = true;
        });
      case NativeBufferStateEvent():
        ref
            .read(captureControllerProvider.notifier)
            .setBufferingActive(event.isBuffering);
      case NativeCaptureErrorEvent():
        debugPrint(
          '[CapturePage] native capture error '
          'code=${event.code} message=${event.message}',
        );
        ref
            .read(captureControllerProvider.notifier)
            .setLastMessage(event.message);
      case NativeCaptureUnknownEvent():
        break;
    }
  }

  PoseFrame _poseFrameFromNativeEvent(NativePoseEvent event) {
    final landmarks = <PoseLandmark, PoseLandmarkPoint>{};
    for (final point in event.points) {
      final landmark = _poseLandmarkFromName(point.name);
      if (landmark == null) {
        continue;
      }
      landmarks[landmark] = PoseLandmarkPoint(
        x: point.x,
        y: point.y,
        confidence: point.confidence,
      );
    }
    return PoseFrame(timestamp: event.timestamp, landmarks: landmarks);
  }

  PoseLandmark? _poseLandmarkFromName(String name) {
    return switch (name) {
      'nose' => PoseLandmark.nose,
      'leftShoulder' => PoseLandmark.leftShoulder,
      'rightShoulder' => PoseLandmark.rightShoulder,
      'leftElbow' => PoseLandmark.leftElbow,
      'rightElbow' => PoseLandmark.rightElbow,
      'leftWrist' => PoseLandmark.leftWrist,
      'rightWrist' => PoseLandmark.rightWrist,
      'leftHip' => PoseLandmark.leftHip,
      'rightHip' => PoseLandmark.rightHip,
      'leftKnee' => PoseLandmark.leftKnee,
      'rightKnee' => PoseLandmark.rightKnee,
      'leftAnkle' => PoseLandmark.leftAnkle,
      'rightAnkle' => PoseLandmark.rightAnkle,
      _ => null,
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_useNativeAndroidPipeline) {
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused) {
        unawaited(WakelockPlus.disable());
        unawaited(_disposeNativeSession());
        return;
      }

      if (state == AppLifecycleState.resumed &&
          ref.read(captureControllerProvider).hasCameraPermission) {
        unawaited(_restoreNativeSession());
      }
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(WakelockPlus.disable());
    }

    final controller = _cameraController;
    if (controller == null) {
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _autoStopTimer?.cancel();
      unawaited(_disposeCameraController());
      return;
    }

    if (state == AppLifecycleState.resumed &&
        ref.read(captureControllerProvider).hasCameraPermission) {
      unawaited(_restoreCameraAndWakeLock());
    }
  }

  Future<void> _restoreCameraAndWakeLock() async {
    await _restoreCameraController();
    if (!mounted) {
      return;
    }
    if (ref.read(captureControllerProvider).isRunning) {
      await WakelockPlus.enable();
    }
  }

  Future<void> _restoreNativeSession() async {
    if (!ref.read(captureControllerProvider).hasCameraPermission ||
        ref.read(captureControllerProvider).isRunning) {
      return;
    }
    setState(() => _isOpeningCamera = true);
    try {
      await ref.read(captureControllerProvider.notifier).startSession();
      await _ensureNativeRollingBufferArmed();
    } catch (_) {
      if (mounted) {
        ref
            .read(captureControllerProvider.notifier)
            .setLastMessage('Could not restore camera preview.');
      }
    } finally {
      if (mounted) {
        setState(() => _isOpeningCamera = false);
      }
    }
    if (!mounted) {
      return;
    }
    if (ref.read(captureControllerProvider).isRunning) {
      await WakelockPlus.enable();
    }
  }

  Future<void> _disposeNativeSession() async {
    _autoStopTimer?.cancel();
    _nativePreviewReady = false;
    if (ref.read(captureControllerProvider).isRecording) {
      if (_pendingSwingEvent != null) {
        _isFinalizingBufferedClip = true;
        await _saveNativeBufferedSwing();
      } else {
        await _stopNativeRollingBuffer();
      }
    }
    try {
      await _capturePlatformChannel.stopDetection();
    } catch (_) {}
    try {
      await _capturePlatformChannel.stopPreview();
    } catch (_) {}
    if (ref.read(captureControllerProvider).isRunning) {
      await ref.read(captureControllerProvider.notifier).stopSession();
    }
    _poseFrameBuffer.clear();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _prepareCameraAccess() async {
    try {
      final cameraStatus = await Permission.camera.request();
      final microphoneStatus = await Permission.microphone.request();
      final hasCameraPermission = cameraStatus.isGranted;
      final hasMicrophonePermission = microphoneStatus.isGranted;

      ref
          .read(captureControllerProvider.notifier)
          .setPermissions(
            hasCameraPermission: hasCameraPermission,
            hasMicrophonePermission: hasMicrophonePermission,
          );

      if (!hasCameraPermission) {
        return;
      }

      _enableAudio = hasMicrophonePermission;
      if (_useNativeAndroidPipeline) {
        setState(() => _isOpeningCamera = true);
        try {
          await ref.read(captureControllerProvider.notifier).startSession();
          await _ensureNativeRollingBufferArmed();
        } finally {
          if (mounted) {
            setState(() => _isOpeningCamera = false);
          }
        }
        return;
      }

      final cameras = await availableCameras();
      if (!mounted) {
        return;
      }

      _cameras
        ..clear()
        ..addAll(cameras);

      if (_cameras.isEmpty) {
        return;
      }

      _selectedCameraIndex = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      if (_selectedCameraIndex < 0) {
        _selectedCameraIndex = 0;
      }

      // Native Android pipeline can keep preview, pose detection, and the
      // rolling buffer alive together, so arm it immediately when Capture opens.
      await _openSelectedCamera();
      await ref.read(captureControllerProvider.notifier).startSession();
      await _startPoseStreamIfNeeded();
      await _ensureNativeRollingBufferArmed();
    } catch (_) {
      ref
          .read(captureControllerProvider.notifier)
          .setPermissions(
            hasCameraPermission: false,
            hasMicrophonePermission: false,
          );
    }
  }

  Future<void> _startNativeRollingBuffer() async {
    if (_isCaptureLocked()) {
      ref
          .read(captureControllerProvider.notifier)
          .setLastMessage(_captureCooldownMessage());
      return;
    }
    final settings =
        ref.read(settingsControllerProvider).valueOrNull ??
        CaptureSettings.defaults();
    await _capturePlatformChannel.startBuffering(
      preRollMs: (settings.preRollSeconds * 1000).round(),
      postRollMs: (settings.postRollSeconds * 1000).round(),
    );
    _recordingStartedAt ??= DateTime.now();
    ref.read(captureControllerProvider.notifier).setRecording(true);
    ref
        .read(captureControllerProvider.notifier)
        .setBufferingActive(
          true,
          lastMessage: 'Native rolling buffer started.',
        );
  }

  Future<void> _stopNativeRollingBuffer() async {
    await _capturePlatformChannel.stopBuffering();
    _autoStopTimer?.cancel();
    _recordingStartedAt = null;
    _pendingSwingEvent = null;
    ref.read(captureControllerProvider.notifier).setRecording(false);
    ref
        .read(captureControllerProvider.notifier)
        .setBufferingActive(false, lastMessage: 'Rolling buffer stopped.');
  }

  Future<void> _saveNativeBufferedSwing() async {
    final event = _pendingSwingEvent;
    if (event == null) {
      _isFinalizingBufferedClip = false;
      return;
    }

    final clipId = DateTime.now().microsecondsSinceEpoch.toString();
    final outputPath = await _buildClipPath(clipId);
    final effectivePreRollMs = _eventPreRollMs(event);
    final effectivePostRollMs = _eventPostRollMs(event);

    ref
        .read(captureControllerProvider.notifier)
        .setSavingState('Saving buffered clip from native rolling buffer.');

    try {
      final savedPath = await _capturePlatformChannel.saveBufferedClip(
        outputPath: outputPath,
        triggerEpochMs: event.triggeredAt.millisecondsSinceEpoch,
        preRollMs: effectivePreRollMs,
        postRollMs: effectivePostRollMs,
      );
      final finalPath = savedPath != null && savedPath.isNotEmpty
          ? savedPath
          : outputPath;

      String thumbnailPath = '';
      try {
        thumbnailPath = await _videoThumbnailService.generateThumbnail(
          videoPath: finalPath,
          clipId: clipId,
        );
      } catch (_) {
        thumbnailPath = '';
      }

      CaptureLocationMetadata? location;
      try {
        location = await _locationMetadataService.getCurrentLocationMetadata();
      } catch (_) {
        location = null;
      }

      final durationMs = _eventWindowDurationMs(event);
      final poseJsonPath = await _savePoseJsonForClip(
        clipId: clipId,
        videoPath: finalPath,
        event: event,
        clipStartAt: event.resolvedWindowStartAt,
        clipEndAt: event.resolvedWindowEndAt,
      );
      await ref
          .read(captureControllerProvider.notifier)
          .saveManualCapture(
            videoPath: finalPath,
            durationMs: durationMs,
            thumbnailPath: thumbnailPath,
            poseJsonPath: poseJsonPath,
            latitude: location?.latitude,
            longitude: location?.longitude,
            locationLabel: location?.label,
            savedToGallery: false,
          );

      final savedToGallery = await _maybeSaveToGallery(finalPath);
      if (savedToGallery) {
        ref
            .read(captureControllerProvider.notifier)
            .setLastMessage('Saved to local history and Photos.');
      }
      if (_isCaptureLocked() &&
          ref.read(captureControllerProvider).isRecording) {
        _rearmBufferAfterCooldown = true;
        await _stopNativeRollingBuffer();
        ref
            .read(captureControllerProvider.notifier)
            .setLastMessage(_captureCooldownMessage());
      } else if (ref.read(captureControllerProvider).isRecording) {
        ref
            .read(captureControllerProvider.notifier)
            .setBufferingActive(
              true,
              lastMessage: 'Clip saved. Rolling buffer is still armed.',
            );
      }
    } on MissingPluginException {
      ref
          .read(captureControllerProvider.notifier)
          .setLastMessage(
            'Native rolling buffer is not available in this build.',
          );
    } on PlatformException catch (error) {
      ref
          .read(captureControllerProvider.notifier)
          .setLastMessage(error.message ?? 'Saving buffered clip failed.');
    } finally {
      _pendingSwingEvent = null;
      _isFinalizingBufferedClip = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _openSelectedCamera({
    bool forceStartCapturePipeline = false,
  }) async {
    if (_useNativeAndroidPipeline) {
      return;
    }
    if (_selectedCameraIndex < 0 || _selectedCameraIndex >= _cameras.length) {
      return;
    }

    final existing = _cameraController;
    if (existing != null) {
      if (existing.value.isRecordingVideo) {
        try {
          final file = await existing.stopVideoRecording();
          await _safeDeleteFile(file.path);
        } catch (_) {}
        if (mounted) {
          ref.read(captureControllerProvider.notifier).setRecording(false);
          ref
              .read(captureControllerProvider.notifier)
              .setBufferingActive(false);
        }
        _recordingStartedAt = null;
        _pendingSwingEvent = null;
      } else {
        await _stopPoseStreamIfNeeded();
      }
    }

    setState(() => _isOpeningCamera = true);

    final previous = _cameraController;
    final controller = CameraController(
      _cameras[_selectedCameraIndex],
      _resolutionPreset,
      enableAudio: _enableAudio,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.nv21,
    );

    try {
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      await previous?.dispose();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _cameraController = controller);
      await _initZoomForController(controller);
    } catch (_) {
      await controller.dispose();
      if (mounted) {
        setState(() => _isOpeningCamera = false);
      }
      return;
    }

    try {
      final captureState = ref.read(captureControllerProvider);
      // Recording (video buffer) and pose streaming are mutually exclusive on
      // Android CameraX below HARDWARE_LEVEL_3. Only resume recording if the
      // session was actively recording before this reopen or the caller
      // explicitly asks for it. Otherwise stay in preview-only pose mode so
      // the skeleton keeps rendering.
      final shouldStartRecording =
          forceStartCapturePipeline || captureState.isRecording;
      if (shouldStartRecording) {
        await _startManualPreRollBuffer();
      } else {
        if (!captureState.isRunning) {
          await ref.read(captureControllerProvider.notifier).startSession();
        }
        await _startPoseStreamIfNeeded();
        unawaited(_startPreRollBufferIfNeeded());
      }
    } catch (_) {
      ref.read(captureControllerProvider.notifier).setRecording(false);
      ref.read(captureControllerProvider.notifier).setBufferingActive(false);
    } finally {
      if (mounted) {
        setState(() => _isOpeningCamera = false);
      }
    }
  }

  /// While video is recording, pose frames must use [CameraController.startVideoRecording]
  /// `onAvailable` — `startImageStream` cannot run concurrently with recording.
  Future<void> _feedPoseFromRecordingCameraImage(CameraImage image) async {
    if (!mounted) {
      return;
    }
    _lastRecordingFrameAt = DateTime.now();
    _recordingFrameCount += 1;
    if (_recordingFrameCount == 1) {
      debugPrint(
        '[CapturePage] recording callback delivered first frame '
        'image=${image.width}x${image.height}',
      );
    }
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isRecordingVideo) {
      return;
    }
    final frame = await _poseDetectionService.processCameraImage(
      image: image,
      camera: controller.description,
      deviceOrientation: controller.value.deviceOrientation,
    );
    if (!mounted) {
      return;
    }
    await _forwardPoseFrame(frame);
  }

  Future<void> _disposeCameraController() async {
    if (_useNativeAndroidPipeline) {
      await _disposeNativeSession();
      return;
    }

    final controller = _cameraController;
    if (controller == null) {
      return;
    }

    if (controller.value.isRecordingVideo) {
      try {
        await _stopBufferedRecording(
          saveClip: _pendingSwingEvent != null,
          resumePipelineAfterStop: false,
        );
      } catch (_) {
        try {
          final file = await controller.stopVideoRecording();
          await _safeDeleteFile(file.path);
        } catch (_) {
          // Ignore teardown races; controller will still be disposed.
        }
        ref.read(captureControllerProvider.notifier).setRecording(false);
        ref.read(captureControllerProvider.notifier).setBufferingActive(false);
        _recordingStartedAt = null;
        _pendingSwingEvent = null;
      }
    } else {
      await _stopPoseStreamIfNeeded();
    }

    _cameraController = null;
    _minZoom = null;
    _maxZoom = null;
    _zoom = null;
    _scaleGestureStartZoom = null;
    _poseFrameBuffer.clear();
    if (mounted) {
      setState(() {});
    }
    await controller.dispose();
  }

  Future<void> _restoreCameraController() async {
    if (_useNativeAndroidPipeline) {
      await _restoreNativeSession();
      return;
    }
    if (_isOpeningCamera || _cameraController != null || _cameras.isEmpty) {
      return;
    }
    await _openSelectedCamera();
  }

  /// After History/Settings, [IndexedStack] shows Capture again — reopen camera.
  Future<void> _restoreCameraAfterHistoryTab() async {
    if (!ref.read(captureControllerProvider).hasCameraPermission) {
      return;
    }
    if (_useNativeAndroidPipeline) {
      await _restoreNativeSession();
      return;
    }
    if (_isOpeningCamera || _cameras.isEmpty || _selectedCameraIndex < 0) {
      return;
    }
    await _openSelectedCamera(
      forceStartCapturePipeline: ref
          .read(captureControllerProvider)
          .isRecording,
    );
  }

  Future<void> _initZoomForController(CameraController controller) async {
    if (!controller.value.isInitialized) {
      return;
    }
    try {
      final minZ = await controller.getMinZoomLevel();
      final maxZ = await controller.getMaxZoomLevel();
      if (!mounted || _cameraController != controller) {
        return;
      }
      var start = 1.0;
      if (start < minZ) {
        start = minZ;
      }
      if (start > maxZ) {
        start = maxZ;
      }
      setState(() {
        _minZoom = minZ;
        _maxZoom = maxZ;
        _zoom = start;
      });
      await controller.setZoomLevel(start);
    } catch (_) {
      if (!mounted || _cameraController != controller) {
        return;
      }
      setState(() {
        _minZoom = null;
        _maxZoom = null;
        _zoom = null;
      });
    }
  }

  bool get _zoomSupported =>
      _minZoom != null &&
      _maxZoom != null &&
      _zoom != null &&
      _maxZoom! > _minZoom! + 0.001;

  Future<void> _applyZoom(double value) async {
    if (_minZoom == null || _maxZoom == null) {
      return;
    }
    final clamped = value.clamp(_minZoom!, _maxZoom!);
    if (_useNativeAndroidPipeline) {
      try {
        await _capturePlatformChannel.setZoomRatio(clamped);
        if (mounted) {
          setState(() => _zoom = clamped);
        }
      } catch (_) {}
      return;
    }
    final c = _cameraController;
    if (c == null || !c.value.isInitialized) {
      return;
    }
    try {
      await c.setZoomLevel(clamped);
      if (!mounted || _cameraController != c) {
        return;
      }
      setState(() => _zoom = clamped);
    } catch (_) {}
  }

  void _onPreviewScaleStart(ScaleStartDetails details) {
    if (!_zoomSupported) {
      return;
    }
    _scaleGestureStartZoom = _zoom;
  }

  void _onPreviewScaleUpdate(ScaleUpdateDetails details) {
    if (!_zoomSupported || _scaleGestureStartZoom == null) {
      return;
    }
    final next = (_scaleGestureStartZoom! * details.scale).clamp(
      _minZoom!,
      _maxZoom!,
    );
    unawaited(_applyZoom(next));
  }

  Future<void> _startPoseStreamIfNeeded() async {
    final controller = _cameraController;
    final captureState = ref.read(captureControllerProvider);
    if (controller == null ||
        !controller.value.isInitialized ||
        _isStreamingImages ||
        controller.value.isStreamingImages ||
        !captureState.isRunning) {
      return;
    }

    try {
      await controller.startImageStream((image) async {
        final frame = await _poseDetectionService.processCameraImage(
          image: image,
          camera: controller.description,
          deviceOrientation: controller.value.deviceOrientation,
        );
        if (!mounted) {
          return;
        }
        await _forwardPoseFrame(frame);
      });
      _isStreamingImages = true;
    } on CameraException {
      _isStreamingImages = false;
    }
  }

  Future<void> _stopPoseStreamIfNeeded() async {
    final controller = _cameraController;
    if (controller == null) {
      _isStreamingImages = false;
      return;
    }

    if (!controller.value.isInitialized ||
        !controller.value.isStreamingImages) {
      _isStreamingImages = false;
      return;
    }

    try {
      await controller.stopImageStream();
    } on CameraException {
      // Ignore if the stream already stopped as part of a lifecycle change.
    } finally {
      _isStreamingImages = false;
    }
  }

  void _startRecordingFrameWatchdog(String source) {
    _recordingFrameWatchdog?.cancel();
    _lastRecordingFrameAt = null;
    _recordingFrameCount = 0;
    debugPrint('[CapturePage] recording started source=$source');
    _recordingFrameWatchdog = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      final controller = _cameraController;
      if (controller == null || !controller.value.isRecordingVideo) {
        timer.cancel();
        return;
      }
      final lastFrameAt = _lastRecordingFrameAt;
      if (lastFrameAt == null) {
        debugPrint(
          '[CapturePage] recording active but no pose frames received yet '
          'source=$source',
        );
        return;
      }
      final ageMs = DateTime.now().difference(lastFrameAt).inMilliseconds;
      if (ageMs > 1200) {
        debugPrint(
          '[CapturePage] pose frame callback stalled while recording '
          'source=$source ageMs=$ageMs frameCount=$_recordingFrameCount',
        );
      }
    });
  }

  void _stopRecordingFrameWatchdog() {
    _recordingFrameWatchdog?.cancel();
    _recordingFrameWatchdog = null;
    if (_recordingFrameCount > 0) {
      debugPrint(
        '[CapturePage] recording stopped after receiving '
        '$_recordingFrameCount pose callback frame(s)',
      );
    }
    _lastRecordingFrameAt = null;
    _recordingFrameCount = 0;
  }

  Future<void> _startPreRollBufferIfNeeded() async {
    if (!_isCameraReady) {
      return;
    }
    if (_isCaptureLocked()) {
      return;
    }

    final settings = ref.read(settingsControllerProvider).valueOrNull;
    final state = ref.read(captureControllerProvider);
    if (settings == null ||
        !_autoDetectionEnabled(settings) ||
        !state.isRunning ||
        state.detectionState.stage != DetectionStage.swingDetected) {
      return;
    }

    final pendingEvent = _pendingSwingEvent ?? state.lastActionEvent;
    final event = pendingEvent ?? _fallbackSwingEvent();
    _armCaptureLock(event);
    if (_useNativeAndroidPipeline) {
      if (state.isRecording) {
        _pendingSwingEvent = event;
        _scheduleAutoFinalize(event);
        return;
      }
      _pendingSwingEvent = event;
      _autoStartedRecording = true;
      await _startNativeRollingBuffer();
      _scheduleAutoFinalize(event);
      ref
          .read(captureControllerProvider.notifier)
          .setBufferingActive(
            true,
            lastMessage:
                'Cross-body move detected. Capturing buffered clip now.',
          );
      if (mounted) {
        setState(() {});
      }
      return;
    }

    final controller = _cameraController;
    if (controller == null) {
      return;
    }
    if (controller.value.isRecordingVideo) {
      _pendingSwingEvent = event;
      _scheduleAutoFinalize(event);
      return;
    }

    await _stopPoseStreamIfNeeded();
    await controller.prepareForVideoRecording();
    await controller.startVideoRecording(
      onAvailable: _feedPoseFromRecordingCameraImage,
    );
    _startRecordingFrameWatchdog('auto');
    _isStreamingImages = false;
    _recordingStartedAt = DateTime.now();
    _pendingSwingEvent = event;
    _autoStartedRecording = true;
    ref.read(captureControllerProvider.notifier).setRecording(true);
    ref
        .read(captureControllerProvider.notifier)
        .setBufferingActive(
          true,
          lastMessage: 'Cross-body move detected. Capturing buffered clip now.',
        );
    _scheduleAutoFinalize(event);
    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleAutoFinalize(ActionEvent event) {
    _autoStopTimer?.cancel();
    final remaining = event.resolvedWindowEndAt.difference(DateTime.now());
    final wait = remaining.isNegative
        ? const Duration(milliseconds: 50)
        : remaining;
    _autoStopTimer = Timer(wait, () {
      debugPrint(
        '[CapturePage] auto finalize fired '
        'after ${wait.inMilliseconds}ms for ${event.label}',
      );
      unawaited(_finalizeBufferedSwing());
    });
  }

  Future<void> _startManualCaptureFromBuffer() async {
    final settings =
        ref.read(settingsControllerProvider).valueOrNull ??
        CaptureSettings.defaults();
    if (_pendingSwingEvent != null || _isFinalizingBufferedClip) {
      return;
    }
    if (_isCaptureLocked()) {
      ref
          .read(captureControllerProvider.notifier)
          .setLastMessage(_captureCooldownMessage());
      return;
    }

    final event = _fallbackSwingEvent();
    _armCaptureLock(event);
    if (_useNativeAndroidPipeline) {
      final captureState = ref.read(captureControllerProvider);
      if (!captureState.isRunning) {
        await _toggleSession();
        if (!ref.read(captureControllerProvider).isRunning) {
          return;
        }
      }
      await _ensureNativeRollingBufferArmed();
      _pendingSwingEvent = event;
      ref
          .read(captureControllerProvider.notifier)
          .setBufferingActive(
            true,
            lastMessage: _autoDetectionEnabled(settings)
                ? 'Manual capture armed. Saving the current buffered swing.'
                : 'Manual capture armed from rolling buffer. Collecting post-roll.',
          );
      _scheduleAutoFinalize(event);
      if (mounted) {
        setState(() {});
      }
      return;
    }

    if (!_isCameraReady) {
      await _toggleSession();
      if (!_isCameraReady) {
        return;
      }
    }

    if (!ref.read(captureControllerProvider).isRecording) {
      await _toggleRecording();
    }
    if (!ref.read(captureControllerProvider).isRecording) {
      return;
    }

    _pendingSwingEvent = event;
    ref
        .read(captureControllerProvider.notifier)
        .setBufferingActive(
          true,
          lastMessage:
              'Manual capture armed from rolling buffer. Collecting post-roll.',
        );
    _scheduleAutoFinalize(event);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _triggerSwingEvent() async {
    await _startManualCaptureFromBuffer();
  }

  void _handleCaptureStateTransition(
    CaptureSessionState? previous,
    CaptureSessionState next,
  ) {
    final wasRunning = previous?.isRunning ?? false;
    if (!wasRunning && next.isRunning) {
      unawaited(WakelockPlus.enable());
    } else if (wasRunning && !next.isRunning) {
      unawaited(WakelockPlus.disable());
    }

    final settings =
        ref.read(settingsControllerProvider).valueOrNull ??
        CaptureSettings.defaults();

    if (!next.isRunning) {
      _autoStopTimer?.cancel();
      return;
    }
    if (_isCaptureLocked()) {
      return;
    }

    if (_useNativeAndroidPipeline) {
      if (previous?.detectionState.stage != DetectionStage.swingDetected &&
          next.detectionState.stage == DetectionStage.swingDetected) {
        _pendingSwingEvent =
            next.lastActionEvent ?? _pendingSwingEvent ?? _fallbackSwingEvent();
        if (next.isRecording) {
          _scheduleAutoFinalize(_pendingSwingEvent!);
        } else if (_autoDetectionEnabled(settings)) {
          unawaited(() async {
            _autoStartedRecording = true;
            await _startNativeRollingBuffer();
            if (mounted && ref.read(captureControllerProvider).isRecording) {
              _scheduleAutoFinalize(_pendingSwingEvent!);
            }
          }());
        }
      }
      return;
    }

    if (previous?.detectionState.stage != DetectionStage.swingDetected &&
        next.detectionState.stage == DetectionStage.swingDetected) {
      _pendingSwingEvent =
          next.lastActionEvent ?? _pendingSwingEvent ?? _fallbackSwingEvent();
      if ((_cameraController?.value.isRecordingVideo ?? false) ||
          next.isRecording) {
        _scheduleAutoFinalize(_pendingSwingEvent!);
      } else if (_autoDetectionEnabled(settings)) {
        unawaited(_startPreRollBufferIfNeeded());
      }
    }

    if (next.detectionState.hasHitter == false &&
        previous?.detectionState.hasHitter == true &&
        next.isRecording &&
        _autoDetectionEnabled(settings)) {
      _autoStopTimer?.cancel();
      if (_pendingSwingEvent == null) {
        unawaited(_stopBufferedRecording(saveClip: false));
      }
    }
  }

  Future<void> _toggleSession() async {
    final captureNotifier = ref.read(captureControllerProvider.notifier);
    final captureState = ref.read(captureControllerProvider);

    if (!captureState.hasCameraPermission) {
      await openAppSettings();
      return;
    }

    if (_useNativeAndroidPipeline) {
      if (captureState.isRunning) {
        if (captureState.isRecording) {
          await _stopNativeRollingBuffer();
        }
        await captureNotifier.stopSession();
        return;
      }

      await captureNotifier.startSession();
      await _ensureNativeRollingBufferArmed();
      return;
    }

    if (captureState.isRunning) {
      if (_cameraController?.value.isRecordingVideo ?? false) {
        await _stopBufferedRecording(
          saveClip: _pendingSwingEvent != null,
          resumePipelineAfterStop: false,
        );
      }
      await _stopPoseStreamIfNeeded();
      await captureNotifier.stopSession();
      return;
    }

    if (!_isCameraReady) {
      await _openSelectedCamera(forceStartCapturePipeline: true);
      if (!_isCameraReady) return;
    }

    await _startManualPreRollBuffer();
  }

  Future<void> _toggleRecording() async {
    final sessionState = ref.read(captureControllerProvider);
    if (!sessionState.hasCameraPermission) {
      await openAppSettings();
      return;
    }

    if (_useNativeAndroidPipeline) {
      if (!sessionState.isRunning) {
        await _toggleSession();
        if (!ref.read(captureControllerProvider).isRunning) {
          return;
        }
      }

      if (ref.read(captureControllerProvider).isRecording) {
        await _stopNativeRollingBuffer();
      } else {
        await _startNativeRollingBuffer();
      }
      return;
    }

    if (!_isCameraReady) {
      await _openSelectedCamera(forceStartCapturePipeline: true);
      if (!_isCameraReady) return;
      return;
    }

    final controller = _cameraController!;
    if (controller.value.isRecordingVideo) {
      _autoStopTimer?.cancel();
      await _stopBufferedRecording(saveClip: false);
      return;
    }

    await _startManualPreRollBuffer();
  }

  Future<void> _startManualPreRollBuffer() async {
    if (!_isCameraReady || _cameraController == null) {
      return;
    }
    if (_isCaptureLocked()) {
      ref
          .read(captureControllerProvider.notifier)
          .setLastMessage(_captureCooldownMessage());
      return;
    }

    final captureState = ref.read(captureControllerProvider);
    if (!captureState.isRunning) {
      await ref.read(captureControllerProvider.notifier).startSession();
    }

    final controller = _cameraController!;
    if (controller.value.isRecordingVideo) {
      return;
    }

    await _stopPoseStreamIfNeeded();
    await controller.prepareForVideoRecording();
    await controller.startVideoRecording(
      onAvailable: _feedPoseFromRecordingCameraImage,
    );
    _startRecordingFrameWatchdog('manual');
    _isStreamingImages = false;
    _recordingStartedAt = DateTime.now();
    _pendingSwingEvent = null;
    _autoStartedRecording = false;
    ref.read(captureControllerProvider.notifier).setRecording(true);
    ref
        .read(captureControllerProvider.notifier)
        .setBufferingActive(
          true,
          lastMessage: 'Manual pre-roll buffer started.',
        );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _finalizeBufferedSwing() async {
    if (_isFinalizingBufferedClip) {
      return;
    }
    if (_useNativeAndroidPipeline) {
      _isFinalizingBufferedClip = true;
      await _saveNativeBufferedSwing();
      return;
    }
    await _stopBufferedRecording(saveClip: true);
  }

  Future<void> _stopBufferedRecording({
    required bool saveClip,
    bool resumePipelineAfterStop = true,
  }) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isRecordingVideo) {
      return;
    }
    _autoStopTimer?.cancel();
    _stopRecordingFrameWatchdog();
    _isFinalizingBufferedClip = saveClip;
    final wasAutoStartedRecording = _autoStartedRecording;
    _autoStartedRecording = false;

    final file = await controller.stopVideoRecording();
    ref.read(captureControllerProvider.notifier).setRecording(false);
    ref.read(captureControllerProvider.notifier).setBufferingActive(false);

    final bufferStartedAt = _recordingStartedAt ?? DateTime.now();
    final event = _pendingSwingEvent;
    final rawPath = await _moveRecordingToAppFolder(
      file.path,
      prefix: saveClip ? 'buffer_raw' : 'discarded_buffer',
    );
    final totalDurationMs = DateTime.now()
        .difference(bufferStartedAt)
        .inMilliseconds;

    _recordingStartedAt = null;
    _pendingSwingEvent = null;

    if (!saveClip || event == null) {
      await _safeDeleteFile(rawPath);
      _isFinalizingBufferedClip = false;
      if (mounted) {
        setState(() {});
      }
      if (resumePipelineAfterStop &&
          ref.read(captureControllerProvider).isRunning &&
          !(_cameraController?.value.isRecordingVideo ?? false)) {
        await _startPoseStreamIfNeeded();
      }
      return;
    }

    ref
        .read(captureControllerProvider.notifier)
        .setSavingState('Saving pre-roll clip from the live buffer.');

    final clipId = DateTime.now().microsecondsSinceEpoch.toString();
    final triggerMs = event.triggeredAt
        .difference(bufferStartedAt)
        .inMilliseconds
        .clamp(0, totalDurationMs);
    final preRollMs = _eventPreRollMs(event);
    final postRollMs = _eventPostRollMs(event);
    final trimmedPath = await _exportBufferedClip(
      rawPath: rawPath,
      clipId: clipId,
      triggerMs: triggerMs,
      preRollMs: preRollMs,
      postRollMs: postRollMs,
    );
    final clipDurationMs = _estimateClipDurationMs(
      totalDurationMs: totalDurationMs,
      triggerMs: triggerMs,
      preRollMs: preRollMs,
      postRollMs: postRollMs,
    );
    final clipWindow = _resolveActualClipWindow(
      bufferStartedAt: bufferStartedAt,
      totalDurationMs: totalDurationMs,
      triggerMs: triggerMs,
      preRollMs: preRollMs,
      postRollMs: postRollMs,
    );
    String thumbnailPath = '';
    try {
      thumbnailPath = await _videoThumbnailService.generateThumbnail(
        videoPath: trimmedPath,
        clipId: clipId,
      );
    } catch (_) {
      thumbnailPath = '';
    }

    CaptureLocationMetadata? location;
    try {
      location = await _locationMetadataService.getCurrentLocationMetadata();
    } catch (_) {
      location = null;
    }

    final poseJsonPath = await _savePoseJsonForClip(
      clipId: clipId,
      videoPath: trimmedPath,
      event: event,
      clipStartAt: clipWindow.startAt,
      clipEndAt: clipWindow.endAt,
    );

    await ref
        .read(captureControllerProvider.notifier)
        .saveManualCapture(
          videoPath: trimmedPath,
          durationMs: clipDurationMs,
          thumbnailPath: thumbnailPath,
          poseJsonPath: poseJsonPath,
          latitude: location?.latitude,
          longitude: location?.longitude,
          locationLabel: location?.label,
          savedToGallery: false,
        );

    final savedToGallery = await _maybeSaveToGallery(trimmedPath);
    if (savedToGallery) {
      ref
          .read(captureControllerProvider.notifier)
          .setLastMessage('Saved to local history and Photos.');
    }

    if (trimmedPath != rawPath) {
      await _safeDeleteFile(rawPath);
    }
    _isFinalizingBufferedClip = false;

    if (mounted) {
      setState(() {});
    }

    if (!resumePipelineAfterStop) {
      return;
    }

    final stillRunning = ref.read(captureControllerProvider).isRunning;
    final stillRecording = _cameraController?.value.isRecordingVideo ?? false;
    if (stillRunning && !stillRecording) {
      if (_isCaptureLocked()) {
        if (saveClip && !wasAutoStartedRecording) {
          _rearmBufferAfterCooldown = true;
        }
        ref
            .read(captureControllerProvider.notifier)
            .setLastMessage(_captureCooldownMessage());
        await _startPoseStreamIfNeeded();
        return;
      }
      if (saveClip && !wasAutoStartedRecording) {
        await _startManualPreRollBuffer();
        return;
      }
      await _startPreRollBufferIfNeeded();
      if (!(_cameraController?.value.isRecordingVideo ?? false)) {
        await _startPoseStreamIfNeeded();
      }
    }
  }

  Future<bool> _maybeSaveToGallery(String videoPath) async {
    final settings = ref.read(settingsControllerProvider).valueOrNull;
    if (settings == null || !settings.autoSaveToGallery) {
      return false;
    }

    try {
      final hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          return false;
        }
      }

      await Gal.putVideo(videoPath, album: AppConstants.swingCaptureAlbum);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _exportBufferedClip({
    required String rawPath,
    required String clipId,
    required int triggerMs,
    required int preRollMs,
    required int postRollMs,
  }) async {
    final outputPath = await _buildClipPath(clipId);

    try {
      final trimmedPath = await const CapturePlatformChannel().saveClip(
        sourcePath: rawPath,
        outputPath: outputPath,
        triggerMs: triggerMs,
        preRollMs: preRollMs,
        postRollMs: postRollMs,
      );
      if (trimmedPath != null && trimmedPath.isNotEmpty) {
        return trimmedPath;
      }
    } on MissingPluginException {
      // Fall back to the raw clip when the native exporter is unavailable.
    } on Exception {
      // Fall back to the raw clip when trimming fails.
    }

    return rawPath;
  }

  Future<void> _switchCamera() async {
    if (_useNativeAndroidPipeline) {
      if (_isOpeningCamera) {
        return;
      }
      try {
        final response = await _capturePlatformChannel.switchCamera();
        final lensDirection = response?['lensDirection'] as String?;
        if (lensDirection != null && mounted) {
          setState(() => _nativeLensDirection = lensDirection);
        }
      } on MissingPluginException {
        // Ignore on older builds.
      } on PlatformException {
        // Ignore switch failures for now.
      }
      return;
    }

    if (_cameras.length < 2 ||
        _isOpeningCamera ||
        _selectedCameraIndex < 0 ||
        _selectedCameraIndex >= _cameras.length) {
      return;
    }

    final currentCamera = _cameras[_selectedCameraIndex];
    final preferredLens = switch (currentCamera.lensDirection) {
      CameraLensDirection.back => CameraLensDirection.front,
      CameraLensDirection.front => CameraLensDirection.back,
      CameraLensDirection.external => CameraLensDirection.back,
    };
    final nextIndex = _cameras.indexWhere(
      (camera) => camera.lensDirection == preferredLens,
    );
    final resolvedIndex = nextIndex >= 0
        ? nextIndex
        : (_selectedCameraIndex + 1) % _cameras.length;

    if (resolvedIndex == _selectedCameraIndex) {
      return;
    }

    if (_cameraController?.value.isRecordingVideo ?? false) {
      await _stopBufferedRecording(
        saveClip: _pendingSwingEvent != null,
        resumePipelineAfterStop: false,
      );
    }

    setState(() => _selectedCameraIndex = resolvedIndex);
    await _openSelectedCamera();
  }

  Future<String> _moveRecordingToAppFolder(
    String sourcePath, {
    required String prefix,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final clipsDirectory = Directory('${directory.path}/clips');
    if (!await clipsDirectory.exists()) {
      await clipsDirectory.create(recursive: true);
    }

    final targetPath =
        '${clipsDirectory.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final sourceFile = File(sourcePath);

    try {
      final moved = await sourceFile.rename(targetPath);
      return moved.path;
    } catch (_) {
      final copied = await sourceFile.copy(targetPath);
      return copied.path;
    }
  }

  Future<String> _buildClipPath(String clipId) async {
    final directory = await getApplicationDocumentsDirectory();
    final clipsDirectory = Directory('${directory.path}/clips');
    if (!await clipsDirectory.exists()) {
      await clipsDirectory.create(recursive: true);
    }
    return '${clipsDirectory.path}/swing_$clipId.mp4';
  }

  Future<void> _safeDeleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  int _estimateClipDurationMs({
    required int totalDurationMs,
    required int triggerMs,
    required int preRollMs,
    required int postRollMs,
  }) {
    final clipStartMs = (triggerMs - preRollMs).clamp(0, totalDurationMs);
    final clipEndMs = (triggerMs + postRollMs).clamp(0, totalDurationMs);
    return (clipEndMs - clipStartMs).clamp(0, totalDurationMs);
  }

  Future<void> _forwardPoseFrame(PoseFrame? frame) async {
    if (frame != null) {
      _recordPoseFrame(frame);
    }
    await ref.read(captureControllerProvider.notifier).onPoseFrame(frame);
  }

  void _recordPoseFrame(PoseFrame frame) {
    _poseFrameBuffer.add(frame);
    _prunePoseFrameBuffer(frame.timestamp);
  }

  void _prunePoseFrameBuffer(DateTime now) {
    final cutoff = now.subtract(_poseBufferLookback);
    while (_poseFrameBuffer.isNotEmpty &&
        _poseFrameBuffer.first.timestamp.isBefore(cutoff)) {
      _poseFrameBuffer.removeAt(0);
    }
  }

  List<PoseFrame> _poseFramesForWindow(DateTime startAt, DateTime endAt) {
    return _poseFrameBuffer
        .where(
          (frame) =>
              !frame.timestamp.isBefore(startAt) &&
              !frame.timestamp.isAfter(endAt),
        )
        .toList(growable: false);
  }

  Future<String?> _savePoseJsonForClip({
    required String clipId,
    required String videoPath,
    required ActionEvent event,
    required DateTime clipStartAt,
    required DateTime clipEndAt,
  }) async {
    final clipFrames = _poseFramesForWindow(clipStartAt, clipEndAt);
    final outputPath = _buildPoseJsonPath(videoPath);
    try {
      return await _poseClipJsonService.writeClipJson(
        outputPath: outputPath,
        clipId: clipId,
        videoPath: videoPath,
        capturePipeline: _useNativeAndroidPipeline
            ? 'native_android_buffer'
            : 'flutter_camera_buffer',
        cameraFacing: _cameraFacingLabel(),
        clipStartAt: clipStartAt,
        clipEndAt: clipEndAt,
        event: event,
        frames: clipFrames,
      );
    } catch (_) {
      return null;
    }
  }

  String _buildPoseJsonPath(String videoPath) {
    final dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '$videoPath.pose.json';
    }
    return '${videoPath.substring(0, dotIndex)}.pose.json';
  }

  ({DateTime startAt, DateTime endAt}) _resolveActualClipWindow({
    required DateTime bufferStartedAt,
    required int totalDurationMs,
    required int triggerMs,
    required int preRollMs,
    required int postRollMs,
  }) {
    final clipStartMs = (triggerMs - preRollMs).clamp(0, totalDurationMs);
    final clipEndMs = (triggerMs + postRollMs).clamp(0, totalDurationMs);
    return (
      startAt: bufferStartedAt.add(Duration(milliseconds: clipStartMs)),
      endAt: bufferStartedAt.add(Duration(milliseconds: clipEndMs)),
    );
  }

  String _cameraFacingLabel() {
    if (_useNativeAndroidPipeline) {
      return _nativeLensDirection;
    }
    final controller = _cameraController;
    if (controller == null) {
      return 'unknown';
    }
    return switch (controller.description.lensDirection) {
      CameraLensDirection.front => 'front',
      CameraLensDirection.back => 'back',
      CameraLensDirection.external => 'external',
    };
  }

  Future<void> _showOptionsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1B22),
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final hasActiveCamera =
                _selectedCameraIndex >= 0 &&
                _selectedCameraIndex < _cameras.length;
            final currentLens = _lensLabelForUi();
            final resolutionSubtitle = _useNativeAndroidPipeline
                ? 'CameraX HD (native)'
                : _resolutionLabel(_resolutionPreset);

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Capture Settings',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$currentLens • $resolutionSubtitle',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Resolution',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in const [
                          ResolutionPreset.medium,
                          ResolutionPreset.high,
                          ResolutionPreset.veryHigh,
                        ])
                          ChoiceChip(
                            label: Text(_resolutionLabel(preset)),
                            selected: _resolutionPreset == preset,
                            onSelected:
                                hasActiveCamera &&
                                    !_isOpeningCamera &&
                                    !_useNativeAndroidPipeline
                                ? (selected) async {
                                    if (!selected ||
                                        _resolutionPreset == preset) {
                                      return;
                                    }
                                    setModalState(
                                      () => _resolutionPreset = preset,
                                    );
                                    setState(() => _resolutionPreset = preset);
                                    await _openSelectedCamera();
                                  }
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Flash',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final mode in const [
                          FlashMode.off,
                          FlashMode.auto,
                          FlashMode.always,
                          FlashMode.torch,
                        ])
                          ChoiceChip(
                            label: Text(_flashModeLabel(mode)),
                            selected: _flashMode == mode,
                            onSelected: hasActiveCamera
                                ? (selected) async {
                                    if (!selected || _flashMode == mode) {
                                      return;
                                    }
                                    setModalState(() => _flashMode = mode);
                                    setState(() => _flashMode = mode);
                                    if (_cameraController != null &&
                                        _cameraController!
                                            .value
                                            .isInitialized) {
                                      await _cameraController!.setFlashMode(
                                        mode,
                                      );
                                    }
                                  }
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.settings_outlined),
                        title: const Text('Open full settings'),
                        subtitle: const Text(
                          'Adjust model version, pre-roll, post-roll, and debug overlay.',
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          ref.read(appTabProvider.notifier).state = 2;
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(captureControllerProvider);
    final detection = state.detectionState;
    ref.listen<CaptureSessionState>(captureControllerProvider, (
      previous,
      next,
    ) {
      _handleCaptureStateTransition(previous, next);
    });
    ref.listen<int>(appTabProvider, (previous, next) {
      if (Platform.isAndroid) {
        unawaited(
          const CapturePlatformChannel().setVolumeKeysConsumed(next == 0),
        );
      }

      // IndexedStack does not lay out the Capture page while another tab is
      // shown; the camera preview texture often breaks. Release the camera when
      // leaving Capture and reopen when returning (see _restoreCameraController).
      if (previous == 0 && next != 0) {
        _autoStopTimer?.cancel();
        unawaited(_disposeCameraController());
        return;
      }

      if (previous != null && previous != 0 && next == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          unawaited(_restoreCameraAfterHistoryTab());
        });
      }
    });

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildPreview(state),
              if (_isOpeningCamera && _isCameraReady)
                const _PreviewLoadingOverlay(),
              _StatusBadge(stage: detection.stage),
              Positioned(
                top: 16,
                right: 16,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_useNativeAndroidPipeline || _cameras.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: IconButton.filledTonal(
                          onPressed: _isOpeningCamera ? null : _switchCamera,
                          tooltip: 'Switch camera',
                          icon: const Icon(Icons.cameraswitch),
                        ),
                      ),
                    IconButton.filledTonal(
                      tooltip: 'Capture settings',
                      onPressed: _showOptionsSheet,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ],
                ),
              ),
              if (state.isRecording)
                const Positioned(
                  top: 16,
                  right: 128,
                  child: _RecordingIndicator(),
                ),
              if (_zoomSupported)
                Positioned(
                  left: 6,
                  top: 88,
                  bottom: 88,
                  width: 52,
                  child: _PreviewZoomRail(
                    min: _minZoom!,
                    max: _maxZoom!,
                    zoom: _zoom!,
                    onZoom: _applyZoom,
                  ),
                ),
              Positioned(
                left: 16,
                right: 112,
                bottom: 16,
                child: _StatusPanel(
                  detection: detection,
                  message: state.lastMessage,
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: _CaptureControlsOverlay(
                  isRecording: state.isRecording,
                  hasCameraPermission: state.hasCameraPermission,
                  onToggleRecording: _toggleRecording,
                  onCaptureSwing: _triggerSwingEvent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _lensLabelForUi() {
    if (_useNativeAndroidPipeline) {
      if (!_nativePreviewReady) {
        return 'Camera loading';
      }
      return _nativeLensDirection == 'front' ? 'Front camera' : 'Back camera';
    }
    if (_selectedCameraIndex >= 0 && _selectedCameraIndex < _cameras.length) {
      return _lensLabel(_cameras[_selectedCameraIndex]);
    }
    return 'Camera loading';
  }

  Widget _buildPreview(CaptureSessionState state) {
    if (_useNativeAndroidPipeline) {
      return _buildNativePreview(state);
    }

    if (!state.hasCameraPermission) {
      return const _PermissionView();
    }

    if (_isOpeningCamera && !_isCameraReady) {
      return const ColoredBox(
        color: Color(0xFF10212A),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const _CameraPreviewPlaceholder(
        message: 'Camera is not initialized yet.',
      );
    }

    Widget? overlay;
    if (_showPoseSkeletonOverlay(state)) {
      overlay = IgnorePointer(
        child: CustomPaint(
          painter: _PosePainter(state.detectionState.debugPoints),
          child: const SizedBox.expand(),
        ),
      );
    }

    // Let CameraPreview own the overlay too, so the plugin's internal preview
    // rotation and the skeleton layer always stay in the same coordinate space.
    final preview = _LiveCameraPreview(
      controller: controller,
      overlay: overlay,
    );
    if (!_zoomSupported) {
      return preview;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: _onPreviewScaleStart,
      onScaleUpdate: _onPreviewScaleUpdate,
      child: preview,
    );
  }

  bool _showPoseSkeletonOverlay(CaptureSessionState state) {
    if (!state.detectionState.showDebugOverlay || !state.hasCameraPermission) {
      return false;
    }
    if (_useNativeAndroidPipeline) {
      return _nativePreviewReady;
    }
    final c = _cameraController;
    if (c == null || !c.value.isInitialized) {
      return false;
    }
    return true;
  }

  Widget _buildNativePreview(CaptureSessionState state) {
    if (!state.hasCameraPermission) {
      return const _PermissionView();
    }

    // The PlatformView must be in the tree so Android attaches [PreviewView]
    // before bindUseCasesIfReady can run; never gate AndroidNativeCameraPreview
    // on _nativePreviewReady or we deadlock (no bind → no camera_state).
    Widget? overlay;
    if (_showPoseSkeletonOverlay(state)) {
      overlay = IgnorePointer(
        child: CustomPaint(
          painter: _PosePainter(
            state.detectionState.debugPoints,
            sourceAspectRatio: _nativePoseAspectRatio,
          ),
          child: const SizedBox.expand(),
        ),
      );
    }

    final showLoadingOverlay = !_nativePreviewReady || _isOpeningCamera;

    final stack = Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(
          color: Colors.black,
          child: AndroidNativeCameraPreview(),
        ),
        if (overlay != null) overlay,
        if (showLoadingOverlay)
          const ColoredBox(
            color: Color(0xFF10212A),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
    if (!_zoomSupported) {
      return stack;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: _onPreviewScaleStart,
      onScaleUpdate: _onPreviewScaleUpdate,
      child: stack,
    );
  }
}

class _LiveCameraPreview extends StatelessWidget {
  const _LiveCameraPreview({required this.controller, this.overlay});

  final CameraController controller;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: _previewAspectRatio(context, controller),
          child: CameraPreview(controller, child: overlay),
        ),
      ),
    );
  }
}

class _PreviewZoomRail extends StatelessWidget {
  const _PreviewZoomRail({
    required this.min,
    required this.max,
    required this.zoom,
    required this.onZoom,
  });

  final double min;
  final double max;
  final double zoom;
  final Future<void> Function(double) onZoom;

  @override
  Widget build(BuildContext context) {
    final span = (max - min).clamp(0.001, double.infinity);
    final step = (span * 0.06).clamp(0.01, 1.0);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () => unawaited(onZoom((zoom + step).clamp(min, max))),
            icon: const Icon(Icons.add, color: Colors.white),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  value: zoom.clamp(min, max),
                  min: min,
                  max: max,
                  onChanged: (v) => unawaited(onZoom(v)),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () => unawaited(onZoom((zoom - step).clamp(min, max))),
            icon: const Icon(Icons.remove, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF18313C), Color(0xFF0A1D26)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                size: 56,
                color: Colors.white54,
              ),
              const SizedBox(height: 12),
              Text(
                'Camera permission is required',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Grant camera access to open live preview and start recording.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraPreviewPlaceholder extends StatelessWidget {
  const _CameraPreviewPlaceholder({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF18313C), Color(0xFF0A1D26)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.camera_alt_outlined,
              size: 56,
              color: Colors.white54,
            ),
            const SizedBox(height: 12),
            Text(message, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _PreviewLoadingOverlay extends StatelessWidget {
  const _PreviewLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.18)),
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
        ),
      ),
    );
  }
}

class _RecordingIndicator extends StatelessWidget {
  const _RecordingIndicator();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fiber_manual_record, size: 14, color: Colors.white),
            SizedBox(width: 4),
            Text('BUFFER'),
          ],
        ),
      ),
    );
  }
}

class _CaptureControlsOverlay extends StatelessWidget {
  const _CaptureControlsOverlay({
    required this.isRecording,
    required this.hasCameraPermission,
    required this.onToggleRecording,
    required this.onCaptureSwing,
  });

  final bool isRecording;
  final bool hasCameraPermission;
  final Future<void> Function() onToggleRecording;
  final Future<void> Function() onCaptureSwing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filled(
              onPressed: hasCameraPermission
                  ? () => unawaited(onToggleRecording())
                  : null,
              tooltip: isRecording ? 'Stop buffer' : 'Start buffer',
              style: IconButton.styleFrom(
                backgroundColor: isRecording
                    ? const Color(0xFFB91C1C)
                    : const Color(0xFF0F766E),
                foregroundColor: Colors.white,
                minimumSize: const Size.square(56),
              ),
              icon: Icon(
                isRecording ? Icons.stop_circle_outlined : Icons.videocam,
                size: 28,
              ),
            ),
            const SizedBox(height: 10),
            IconButton.filledTonal(
              onPressed: hasCameraPermission
                  ? () => unawaited(onCaptureSwing())
                  : null,
              tooltip: 'Capture swing',
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: const Color(0xFF1D4ED8).withValues(alpha: 0.9),
                minimumSize: const Size.square(56),
              ),
              icon: const Icon(Icons.sports_baseball, size: 26),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.stage});

  final DetectionStage stage;

  @override
  Widget build(BuildContext context) {
    final label = switch (stage) {
      DetectionStage.idle => 'Idle',
      DetectionStage.hitterDetected => 'Hitter detected',
      DetectionStage.ready => 'Ready',
      DetectionStage.swingDetected => 'Swing detected',
      DetectionStage.saving => 'Saving',
    };

    return Positioned(
      top: 16,
      left: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(label),
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.detection, required this.message});

  final DetectionState detection;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    detection.statusText ?? 'Idle',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message ??
                        'Use the right-side controls to keep the live buffer running and save the swing that matters.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Hitter ${(detection.hitterConfidence ?? 0).toStringAsFixed(2)}',
                ),
                Text(
                  detection.isBuffering ? 'Buffering on' : 'Buffering off',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PosePainter extends CustomPainter {
  _PosePainter(this.points, {this.sourceAspectRatio})
    : _byName = {
        for (final p in points)
          if (p.name != null) p.name!: p,
      };

  final List<PosePoint> points;
  final double? sourceAspectRatio;
  final Map<String, PosePoint> _byName;

  /// Match scripts' `MIN_VIS` (~0.35);0.5 hid full skeletons at distance.
  static const double _minConfidenceBone = 0.35;
  static const double _minConfidenceJoint = 0.25;
  static const Color _bonePrimary = Color(0xFF22D3EE);
  static const Color _boneArm = Color(0xFFFACC15);
  static const Color _boneLeg = Color(0xFF34D399);
  static const Color _jointColor = Color(0xFFE0F7FA);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) {
      return;
    }

    final bonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final shadowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = Colors.black.withValues(alpha: 0.55);
    final paintRect = _paintRectFor(size);

    Offset? toOffset(PoseLandmark landmark, {required double minConf}) {
      final p = _byName[landmark.name];
      if (p == null || p.confidence < minConf) {
        return null;
      }
      return Offset(
        paintRect.left + p.x * paintRect.width,
        paintRect.top + p.y * paintRect.height,
      );
    }

    for (final bone in kPoseBones) {
      final a = toOffset(bone.a, minConf: _minConfidenceBone);
      final b = toOffset(bone.b, minConf: _minConfidenceBone);
      if (a == null || b == null) continue;
      bonePaint.color = _colorForBone(bone.a, bone.b);
      canvas.drawLine(a, b, shadowPaint);
      canvas.drawLine(a, b, bonePaint);
    }

    final head = toOffset(PoseLandmark.nose, minConf: _minConfidenceJoint);
    final lShoulder = toOffset(
      PoseLandmark.leftShoulder,
      minConf: _minConfidenceJoint,
    );
    final rShoulder = toOffset(
      PoseLandmark.rightShoulder,
      minConf: _minConfidenceJoint,
    );
    if (head != null) {
      double radius = 10;
      if (lShoulder != null && rShoulder != null) {
        radius = ((rShoulder - lShoulder).distance * 0.35).clamp(8.0, 28.0);
        final neckMid = Offset(
          (lShoulder.dx + rShoulder.dx) / 2,
          (lShoulder.dy + rShoulder.dy) / 2,
        );
        canvas.drawLine(neckMid, head, shadowPaint);
        canvas.drawLine(
          neckMid,
          head,
          Paint()
            ..color = _bonePrimary
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round,
        );
      }
      canvas.drawCircle(
        head,
        radius + 1.5,
        Paint()..color = Colors.black.withValues(alpha: 0.55),
      );
      canvas.drawCircle(
        head,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = _bonePrimary,
      );
    }

    final jointPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = _jointColor;
    final jointHalo = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.black.withValues(alpha: 0.55);

    for (final landmark in PoseLandmark.values) {
      if (landmark == PoseLandmark.nose) continue;
      final offset = toOffset(landmark, minConf: _minConfidenceJoint);
      if (offset == null) continue;
      canvas.drawCircle(offset, 5, jointHalo);
      canvas.drawCircle(offset, 3.5, jointPaint);
    }
  }

  Color _colorForBone(PoseLandmark a, PoseLandmark b) {
    bool isArm(PoseLandmark l) =>
        l == PoseLandmark.leftElbow ||
        l == PoseLandmark.rightElbow ||
        l == PoseLandmark.leftWrist ||
        l == PoseLandmark.rightWrist;
    bool isLeg(PoseLandmark l) =>
        l == PoseLandmark.leftKnee ||
        l == PoseLandmark.rightKnee ||
        l == PoseLandmark.leftAnkle ||
        l == PoseLandmark.rightAnkle;
    if (isArm(a) || isArm(b)) return _boneArm;
    if (isLeg(a) || isLeg(b)) return _boneLeg;
    return _bonePrimary;
  }

  Rect _paintRectFor(Size size) {
    final aspect = sourceAspectRatio;
    if (aspect == null || aspect <= 0 || size.isEmpty) {
      return Offset.zero & size;
    }
    final canvasAspect = size.width / size.height;
    if ((canvasAspect - aspect).abs() < 0.0001) {
      return Offset.zero & size;
    }
    if (canvasAspect > aspect) {
      final paintedHeight = size.width / aspect;
      final top = (size.height - paintedHeight) / 2;
      return Rect.fromLTWH(0, top, size.width, paintedHeight);
    }
    final paintedWidth = size.height * aspect;
    final left = (size.width - paintedWidth) / 2;
    return Rect.fromLTWH(left, 0, paintedWidth, size.height);
  }

  @override
  bool shouldRepaint(covariant _PosePainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.sourceAspectRatio != sourceAspectRatio;
  }
}

String _lensLabel(CameraDescription camera) {
  return switch (camera.lensDirection) {
    CameraLensDirection.front => 'Front Camera',
    CameraLensDirection.back => 'Back Camera',
    CameraLensDirection.external => 'External Camera',
  };
}

String _resolutionLabel(ResolutionPreset preset) {
  return switch (preset) {
    ResolutionPreset.low => 'Low',
    ResolutionPreset.medium => 'Medium',
    ResolutionPreset.high => 'High',
    ResolutionPreset.veryHigh => 'Very High',
    ResolutionPreset.ultraHigh => 'Ultra High',
    ResolutionPreset.max => 'Max',
  };
}

double _previewAspectRatio(BuildContext context, CameraController controller) {
  final ratio = controller.value.aspectRatio;
  if (ratio <= 0) {
    return 9 / 16;
  }
  final orientation = MediaQuery.orientationOf(context);
  if (orientation == Orientation.portrait && ratio > 1) {
    return 1 / ratio;
  }
  if (orientation == Orientation.landscape && ratio < 1) {
    return 1 / ratio;
  }
  return ratio;
}

String _flashModeLabel(FlashMode mode) {
  return switch (mode) {
    FlashMode.off => 'Off',
    FlashMode.auto => 'Auto',
    FlashMode.always => 'Always',
    FlashMode.torch => 'Torch',
  };
}
