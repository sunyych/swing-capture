import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';
import '../../../../core/config/app_constants.dart';
import '../../debug/pose_json_logger.dart';
import '../../../../core/models/action_event.dart';
import '../../../../core/models/capture_record.dart';
import '../../../../core/models/capture_settings.dart';
import '../../../../core/models/detection_state.dart';
import '../../domain/models/pose_frame.dart';
import '../../domain/patterns/action_pattern_catalog.dart';
import '../../domain/patterns/capture_model_catalog.dart';
import '../../../../platform_channels/capture_platform_channel.dart';
import '../../domain/services/action_detector.dart';
import '../../domain/services/action_pattern_matcher.dart';
import '../../domain/services/lateral_burst_swing_detector.dart';

class CaptureSessionState {
  const CaptureSessionState({
    required this.isRunning,
    required this.detectionState,
    this.isRecording = false,
    this.hasCameraPermission = false,
    this.hasMicrophonePermission = false,
    this.lastMessage,
    this.lastActionEvent,
  });

  final bool isRunning;
  final DetectionState detectionState;
  final bool isRecording;
  final bool hasCameraPermission;
  final bool hasMicrophonePermission;
  final String? lastMessage;
  final ActionEvent? lastActionEvent;

  static const Object _keepActionEvent = Object();

  CaptureSessionState copyWith({
    bool? isRunning,
    DetectionState? detectionState,
    bool? isRecording,
    bool? hasCameraPermission,
    bool? hasMicrophonePermission,
    String? lastMessage,
    Object? lastActionEvent = _keepActionEvent,
  }) {
    return CaptureSessionState(
      isRunning: isRunning ?? this.isRunning,
      detectionState: detectionState ?? this.detectionState,
      isRecording: isRecording ?? this.isRecording,
      hasCameraPermission: hasCameraPermission ?? this.hasCameraPermission,
      hasMicrophonePermission:
          hasMicrophonePermission ?? this.hasMicrophonePermission,
      lastMessage: lastMessage ?? this.lastMessage,
      lastActionEvent: identical(lastActionEvent, _keepActionEvent)
          ? this.lastActionEvent
          : lastActionEvent as ActionEvent?,
    );
  }
}

/// Orchestrates the capture state machine and keeps Flutter usable before the
/// native bridge is fully implemented.
class CaptureController extends AutoDisposeNotifier<CaptureSessionState> {
  final CapturePlatformChannel _channel = const CapturePlatformChannel();
  late List<ActionDetector> _actionDetectors;
  ActionPatternMatcher? _patternMatcher;
  String _modelName = 'Capture Model';
  String _modelDescription = 'Waiting for configured model trigger.';
  String _patternLabel = 'action_event';
  String? _patternCategory;
  bool _autoDetectionEnabled = true;
  DateTime? _hitterFirstSeenAt;
  DateTime? _lastNoPoseFrameLogAt;

  @override
  CaptureSessionState build() {
    // Keep session/permission state when switching tabs; IndexedStack + async
    // settings must not rebuild this notifier into a fresh default state.
    ref.keepAlive();

    final settings =
        ref.read(settingsControllerProvider).valueOrNull ??
        CaptureSettings.defaults();
    _configureActionPattern(settings);

    ref.listen<AsyncValue<CaptureSettings>>(settingsControllerProvider, (
      _,
      next,
    ) {
      final s = next.valueOrNull;
      if (s == null) {
        return;
      }
      _configureActionPattern(s);
      state = state.copyWith(
        detectionState: state.detectionState.copyWith(
          showDebugOverlay: s.showDebugSkeleton,
        ),
      );
    });

    return CaptureSessionState(
      isRunning: false,
      detectionState: DetectionState.initial(
        showDebugOverlay: settings.showDebugSkeleton,
      ),
    );
  }

  void setPermissions({
    required bool hasCameraPermission,
    required bool hasMicrophonePermission,
  }) {
    state = state.copyWith(
      hasCameraPermission: hasCameraPermission,
      hasMicrophonePermission: hasMicrophonePermission,
      lastMessage: hasCameraPermission
          ? 'Camera ready.'
          : 'Camera permission is required to preview and record.',
    );
  }

  Future<void> startSession() async {
    if (state.isRunning) return;

    final settings =
        ref.read(settingsControllerProvider).valueOrNull ??
        CaptureSettings.defaults();

    try {
      await _channel.startPreview();
      await _channel.startDetection();
    } on MissingPluginException {
      // Flutter camera preview handles the current MVP.
    } on PlatformException {
      // Native bridge can be absent during scaffold stage.
    }

    state = state.copyWith(
      isRunning: true,
      detectionState: DetectionState(
        stage: DetectionStage.idle,
        hasHitter: false,
        isBuffering: false,
        showDebugOverlay: settings.showDebugSkeleton,
        statusText: 'Idle',
        hitterConfidence: 0,
      ),
      lastMessage: 'Preview started. Monitoring for a hitter.',
      lastActionEvent: null,
    );
    for (final detector in _actionDetectors) {
      detector.reset();
    }
    _hitterFirstSeenAt = null;
  }

  Future<void> stopSession() async {
    try {
      await _channel.stopDetection();
      await _channel.stopPreview();
    } on MissingPluginException {
      // Ignore until native bridge exists.
    } on PlatformException {
      // Ignore until native bridge exists.
    }

    state = state.copyWith(
      isRunning: false,
      isRecording: false,
      detectionState: DetectionState.initial(
        showDebugOverlay: state.detectionState.showDebugOverlay,
      ),
      lastMessage: 'Capture stopped.',
      lastActionEvent: null,
    );
    for (final detector in _actionDetectors) {
      detector.reset();
    }
    _hitterFirstSeenAt = null;
  }

  void setRecording(bool isRecording) {
    _lastNoPoseFrameLogAt = null;
    debugPrint('[CaptureController] recording=${isRecording ? 'on' : 'off'}');
    state = state.copyWith(
      isRecording: isRecording,
      lastMessage: isRecording
          ? 'Pre-roll buffer is running.'
          : 'Pre-roll buffer stopped.',
    );
  }

  void setBufferingActive(bool isBuffering, {String? lastMessage}) {
    state = state.copyWith(
      detectionState: state.detectionState.copyWith(isBuffering: isBuffering),
      lastMessage: lastMessage ?? state.lastMessage,
    );
  }

  void setSavingState(String message) {
    state = state.copyWith(
      detectionState: state.detectionState.copyWith(
        stage: DetectionStage.saving,
        statusText: 'Saving',
      ),
      lastMessage: message,
    );
  }

  void setLastMessage(String message) {
    state = state.copyWith(lastMessage: message);
  }

  Future<void> simulateSwing() async {
    if (!state.isRunning) {
      return;
    }
    // Clear frames from the live pose stream so mock thresholds are reliable.
    for (final detector in _actionDetectors) {
      detector.reset();
    }
    final event = _runMockActionDetection();
    final now = DateTime.now();
    _applySwingEvent(
      event ??
          ActionEvent(
            label: _patternLabel,
            category: _patternCategory,
            triggeredAt: now,
            score: 1,
            preRollMs: 2000,
            postRollMs: 2000,
            windowStartAt: now.subtract(const Duration(seconds: 2)),
            windowEndAt: now.add(const Duration(seconds: 2)),
            reason: 'manual trigger',
          ),
    );
  }

  void simulateHitterExit() {
    if (!state.isRunning) {
      return;
    }

    state = state.copyWith(
      detectionState: state.detectionState.copyWith(
        stage: DetectionStage.idle,
        hasHitter: false,
        isBuffering: false,
        hitterConfidence: 0,
        statusText: 'Idle',
      ),
      lastMessage: 'Hitter left frame. Returned to idle monitoring.',
      lastActionEvent: null,
    );
    _hitterFirstSeenAt = null;
    for (final detector in _actionDetectors) {
      detector.reset();
    }
  }

  Future<void> onPoseFrame(PoseFrame? frame) async {
    if (!state.isRunning) {
      return;
    }

    // null = throttled or failed conversion — do not reset the whole detector.
    if (frame == null) {
      return;
    }
    if (frame.landmarks.isEmpty) {
      _handleNoPoseFrame();
      return;
    }

    final completeness = frame.completenessScore();
    final hasHitter = completeness >= 0.65;
    final debugPoints = frame.landmarks.entries
        .map(
          (entry) => PosePoint(
            x: entry.value.x,
            y: entry.value.y,
            confidence: entry.value.confidence,
            name: entry.key.name,
          ),
        )
        .toList(growable: false);

    if (!hasHitter) {
      _emitPoseJsonLog(
        frame: frame,
        completeness: completeness,
        hasHitter: false,
        gatherAllowsSwing: false,
        stableMs: null,
        stage: _poseStageLabel(
          hasHitter: false,
          isReady: false,
          prior: state.detectionState.stage,
        ),
      );
      state = state.copyWith(
        detectionState: state.detectionState.copyWith(
          stage: DetectionStage.idle,
          hasHitter: false,
          hitterConfidence: completeness,
          isBuffering: false,
          statusText: 'Idle',
          debugPoints: debugPoints,
        ),
        lastMessage: 'Monitoring for a hitter.',
        lastActionEvent: null,
      );
      _hitterFirstSeenAt = null;
      for (final detector in _actionDetectors) {
        detector.reset();
      }
      return;
    }

    _hitterFirstSeenAt ??= frame.timestamp;
    final stableDuration = frame.timestamp.difference(_hitterFirstSeenAt!);
    final isReady = stableDuration >= AppConstants.hitterStableDuration;
    final patternArmed =
        _autoDetectionEnabled && (_patternMatcher?.isArmed ?? false);

    _emitPoseJsonLog(
      frame: frame,
      completeness: completeness,
      hasHitter: true,
      gatherAllowsSwing: patternArmed,
      stableMs: stableDuration.inMilliseconds,
      stage: _poseStageLabel(
        hasHitter: true,
        isReady: isReady,
        prior: state.detectionState.stage,
      ),
    );

    final nextStage = switch (state.detectionState.stage) {
      DetectionStage.swingDetected ||
      DetectionStage.saving => state.detectionState.stage,
      _ => isReady ? DetectionStage.ready : DetectionStage.hitterDetected,
    };
    state = state.copyWith(
      detectionState: state.detectionState.copyWith(
        stage: nextStage,
        hasHitter: true,
        hitterConfidence: completeness,
        isBuffering: false,
        statusText: isReady
            ? (_autoDetectionEnabled
                  ? 'Tracking $_modelName'
                  : 'Manual rolling buffer')
            : 'Hitter detected',
        debugPoints: debugPoints,
      ),
      lastMessage: isReady
          ? (_autoDetectionEnabled
                ? 'Pose is stable. $_modelDescription'
                : 'Auto detection is off. Use the capture control to save from the rolling buffer.')
          : 'Hitter detected. Holding until pose stabilizes.',
    );

    if (!isReady || !_autoDetectionEnabled) {
      return;
    }

    ActionEvent? event;
    for (final detector in _actionDetectors) {
      event ??= detector.process(frame);
    }
    if (event != null) {
      _applySwingEvent(event, frame: frame, completeness: completeness);
    }
  }

  Future<void> saveManualCapture({
    required String videoPath,
    required int durationMs,
    String thumbnailPath = '',
    String? poseJsonPath,
    double? latitude,
    double? longitude,
    String? locationLabel,
    bool savedToGallery = false,
  }) async {
    final repository = ref.read(historyRepositoryProvider);
    final existing = await repository.listRecords();
    final alreadySaved = existing.any((item) => item.videoPath == videoPath);
    if (alreadySaved) {
      final hasHitter = state.detectionState.hasHitter;
      state = state.copyWith(
        lastMessage: 'Duplicate clip ignored (already saved).',
        detectionState: state.detectionState.copyWith(
          stage: hasHitter ? DetectionStage.ready : DetectionStage.idle,
          isBuffering: false,
          statusText: hasHitter ? 'Ready' : 'Idle',
        ),
        lastActionEvent: null,
      );
      return;
    }

    final record = CaptureRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      videoPath: videoPath,
      thumbnailPath: thumbnailPath,
      createdAt: DateTime.now(),
      durationMs: durationMs,
      albumName: AppConstants.swingCaptureAlbum,
      poseJsonPath: poseJsonPath,
      latitude: latitude,
      longitude: longitude,
      locationLabel: locationLabel,
    );

    await repository.saveRecord(record);
    final historyController = ref.read(historyControllerProvider.notifier);
    await historyController.recordSaved(record);
    await historyController.refresh();
    final hasHitter = state.detectionState.hasHitter;
    state = state.copyWith(
      lastMessage: savedToGallery
          ? 'Recording saved to gallery and local history.'
          : 'Recording saved to local history.',
      detectionState: state.detectionState.copyWith(
        stage: hasHitter ? DetectionStage.ready : DetectionStage.idle,
        isBuffering: false,
        statusText: hasHitter ? 'Ready' : 'Idle',
      ),
      lastActionEvent: null,
    );
  }

  ActionEvent? _runMockActionDetection() {
    final base = DateTime.now();
    final positions = <(double, double)>[
      (0.45, 0.47),
      (0.45, 0.47),
      (0.49, 0.52),
      (0.55, 0.60),
      (0.62, 0.68),
      (0.69, 0.75),
    ];
    final frames = <PoseFrame>[
      for (var i = 0; i < positions.length; i++)
        PoseFrame(
          timestamp: base.subtract(
            Duration(milliseconds: 60 * (positions.length - 1 - i)),
          ),
          landmarks: _mockFrameLandmarks(
            leftWristX: positions[i].$1,
            rightWristX: positions[i].$2,
            shoulderBias: 0,
          ),
        ),
    ];

    ActionEvent? event;
    for (final frame in frames) {
      for (final detector in _actionDetectors) {
        event = detector.process(frame) ?? event;
      }
    }
    return event;
  }

  void _applySwingEvent(
    ActionEvent event, {
    PoseFrame? frame,
    double? completeness,
  }) {
    if (AppConstants.verbosePoseJsonLog) {
      debugPrint(
        '[SwingDetect] '
        '${event.label} score=${event.score.toStringAsFixed(2)} ${event.reason}',
      );
      if (frame != null) {
        _emitPoseJsonLog(
          frame: frame,
          completeness: completeness ?? frame.completenessScore(),
          hasHitter: true,
          gatherAllowsSwing: true,
          stage: DetectionStage.swingDetected.name,
          stableMs: _hitterFirstSeenAt == null
              ? null
              : frame.timestamp.difference(_hitterFirstSeenAt!).inMilliseconds,
          detected: true,
          event: event,
        );
      }
    } else {
      debugPrint(
        '[CaptureController] swing detected '
        'label=${event.label} '
        'score=${event.score.toStringAsFixed(2)} '
        'reason=${event.reason}',
      );
    }
    state = state.copyWith(
      detectionState: state.detectionState.copyWith(
        stage: DetectionStage.swingDetected,
        statusText: 'Swing detected',
      ),
      lastMessage:
          '${event.label} locked. Score ${event.score.toStringAsFixed(2)}.',
      lastActionEvent: event,
    );
  }

  void _configureActionPattern(CaptureSettings settings) {
    final cooldown = Duration(milliseconds: settings.swingCooldownMs);
    final preRollMs = (settings.preRollSeconds * 1000).round();
    final postRollMs = (settings.postRollSeconds * 1000).round();
    _autoDetectionEnabled = settings.autoRecordOnReady;
    final model = CaptureModelCatalog.resolve(settings.captureModelId);
    final definition = ActionPatternCatalog.resolve(
      model.actionPatternId,
      preRollMs: preRollMs,
      postRollMs: postRollMs,
      cooldownMs: cooldown.inMilliseconds,
    );
    _patternMatcher = ActionPatternMatcher(definition: definition);
    _modelName = model.name;
    _modelDescription = model.description;
    _patternLabel = definition.label;
    _patternCategory = definition.category;
    _actionDetectors = <ActionDetector>[
      _patternMatcher!,
      LateralWristBurstSwingDetector(
        config: LateralWristBurstDetectorConfig(
          cooldown: cooldown,
          label: _patternLabel,
          category: _patternCategory ?? 'sports',
          // Live-device swings are often slower/noisier than the synthetic test
          // traces, so keep the fallback detector materially more permissive.
          minAbsVx: 0.42,
          minMeanWristSpeed: 0.28,
          minScore: 0.18,
          preRollMs: preRollMs,
          postRollMs: postRollMs,
        ),
      ),
    ];
  }

  void _handleNoPoseFrame() {
    _debugLogNoPoseFrame();
    if (AppConstants.verbosePoseJsonLog) {
      debugPrint(
        '[PoseJson] {"tag":"PoseJson","empty":true,'
        '"wallMs":${DateTime.now().millisecondsSinceEpoch}}',
      );
    }
    state = state.copyWith(
      detectionState: state.detectionState.copyWith(
        stage: DetectionStage.idle,
        hasHitter: false,
        hitterConfidence: 0,
        isBuffering: false,
        statusText: 'Idle',
        debugPoints: const <PosePoint>[],
      ),
      lastMessage: 'Monitoring for a hitter.',
      lastActionEvent: null,
    );
    _hitterFirstSeenAt = null;
    for (final detector in _actionDetectors) {
      detector.reset();
    }
  }

  void _emitPoseJsonLog({
    required PoseFrame frame,
    required double completeness,
    required bool hasHitter,
    required bool gatherAllowsSwing,
    required String stage,
    int? stableMs,
    bool detected = false,
    ActionEvent? event,
  }) {
    if (!AppConstants.verbosePoseJsonLog) {
      return;
    }
    final wallMs = DateTime.now().millisecondsSinceEpoch;
    PoseJsonLogger.printLine(
      PoseJsonLogger.buildLine(
        frame: frame,
        wallMs: wallMs,
        stage: stage,
        completeness: completeness,
        hasHitter: hasHitter,
        gatherAllowsSwing: gatherAllowsSwing,
        stableMs: stableMs,
        detected: detected,
        detectLabel: event?.label,
        detectScore: event?.score,
        detectReason: event?.reason,
      ),
    );
  }

  static String _poseStageLabel({
    required bool hasHitter,
    required bool isReady,
    required DetectionStage prior,
  }) {
    if (prior == DetectionStage.swingDetected ||
        prior == DetectionStage.saving) {
      return prior.name;
    }
    if (!hasHitter) {
      return 'idle';
    }
    if (!isReady) {
      return 'stabilizing';
    }
    return 'ready';
  }

  void _debugLogNoPoseFrame() {
    final now = DateTime.now();
    if (_lastNoPoseFrameLogAt != null &&
        now.difference(_lastNoPoseFrameLogAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastNoPoseFrameLogAt = now;
    debugPrint('[CaptureController] frame has no detected pose landmarks');
  }
}

Map<PoseLandmark, PoseLandmarkPoint> _mockFrameLandmarks({
  required double leftWristX,
  required double rightWristX,
  double shoulderBias = 0,
}) {
  return {
    PoseLandmark.leftShoulder: PoseLandmarkPoint(
      x: 0.45 - shoulderBias,
      y: 0.29,
      confidence: 0.9,
    ),
    PoseLandmark.rightShoulder: PoseLandmarkPoint(
      x: 0.56 + shoulderBias,
      y: 0.27,
      confidence: 0.9,
    ),
    PoseLandmark.leftHip: const PoseLandmarkPoint(
      x: 0.48,
      y: 0.62,
      confidence: 0.9,
    ),
    PoseLandmark.rightHip: const PoseLandmarkPoint(
      x: 0.55,
      y: 0.62,
      confidence: 0.9,
    ),
    PoseLandmark.leftWrist: PoseLandmarkPoint(
      x: leftWristX,
      y: 0.48,
      confidence: 0.9,
    ),
    PoseLandmark.rightWrist: PoseLandmarkPoint(
      x: rightWristX,
      y: 0.44,
      confidence: 0.9,
    ),
  };
}
