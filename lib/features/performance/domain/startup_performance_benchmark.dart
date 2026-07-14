import '../../../core/models/action_event.dart';
import '../../../platform_channels/capture_platform_channel.dart';
import '../../capture/data/yolo_pose_decoder.dart';
import '../../capture/domain/models/pose_frame.dart';
import '../../capture/domain/patterns/action_pattern_catalog.dart';
import '../../capture/domain/patterns/capture_model_catalog.dart';
import '../../capture/domain/services/action_detector.dart';
import '../../capture/domain/services/action_pattern_matcher.dart';
import '../../capture/domain/services/lateral_burst_swing_detector.dart';
import '../../capture/domain/services/target_pose_selector.dart';

class StartupPerformanceReport {
  const StartupPerformanceReport({
    required this.recordingCapability,
    required this.poseDetection,
    required this.poseProcessing,
    required this.elapsed,
    this.recordingError,
  });

  final NativeRecordingCapability? recordingCapability;
  final Object? recordingError;
  final PoseDetectionBenchmarkResult poseDetection;
  final PoseProcessingBenchmarkResult poseProcessing;
  final Duration elapsed;

  String get recordingSummary {
    final capability = recordingCapability;
    if (capability == null) {
      return recordingError == null ? 'Unavailable' : 'Unavailable';
    }
    return 'Recording ${capability.summary}';
  }

  String? get recordingDetail => recordingCapability?.lensSummary;
}

class PoseDetectionBenchmarkResult {
  const PoseDetectionBenchmarkResult({
    required this.framesProcessed,
    required this.candidatesDetected,
    required this.selectedFrames,
    required this.elapsed,
    required this.fps,
    required this.averageCandidatesPerFrame,
  });

  final int framesProcessed;
  final int candidatesDetected;
  final int selectedFrames;
  final Duration elapsed;
  final double fps;
  final double averageCandidatesPerFrame;
}

class PoseProcessingBenchmarkResult {
  const PoseProcessingBenchmarkResult({
    required this.framesProcessed,
    required this.elapsed,
    required this.fps,
    required this.detectedEvents,
    required this.averageCompleteness,
  });

  final int framesProcessed;
  final Duration elapsed;
  final double fps;
  final int detectedEvents;
  final double averageCompleteness;
}

class StartupPerformanceBenchmark {
  const StartupPerformanceBenchmark({
    CapturePlatformChannel channel = const CapturePlatformChannel(),
  }) : _channel = channel;

  final CapturePlatformChannel _channel;

  Future<StartupPerformanceReport> run() async {
    final total = Stopwatch()..start();
    NativeRecordingCapability? capability;
    Object? recordingError;
    try {
      capability = await _channel.queryRecordingCapability().timeout(
        const Duration(seconds: 3),
      );
    } catch (error) {
      recordingError = error;
    }
    final poseDetection = runPoseDetectionBenchmark();
    final poseProcessing = runPoseProcessingBenchmark();
    total.stop();
    return StartupPerformanceReport(
      recordingCapability: capability,
      recordingError: recordingError,
      poseDetection: poseDetection,
      poseProcessing: poseProcessing,
      elapsed: total.elapsed,
    );
  }

  PoseDetectionBenchmarkResult runPoseDetectionBenchmark() {
    const decoder = YoloPoseDecoder();
    final selector = TargetPoseSelector();
    final frames = _sampleYoloPoseOutputs();
    var framesProcessed = 0;
    var candidatesDetected = 0;
    var selectedFrames = 0;
    const passes = 18;
    final stopwatch = Stopwatch()..start();
    for (var pass = 0; pass < passes; pass++) {
      selector.reset();
      for (var i = 0; i < frames.length; i++) {
        final candidates = decoder.decode(
          output: frames[i],
          timestamp: DateTime(
            2026,
          ).add(Duration(milliseconds: (pass * frames.length + i) * 16)),
        );
        final selected = selector.select(candidates);
        if (selected != null) {
          selectedFrames += 1;
        }
        candidatesDetected += candidates.length;
        framesProcessed += 1;
      }
    }
    stopwatch.stop();
    final elapsedMicros = stopwatch.elapsedMicroseconds <= 0
        ? 1
        : stopwatch.elapsedMicroseconds;
    return PoseDetectionBenchmarkResult(
      framesProcessed: framesProcessed,
      candidatesDetected: candidatesDetected,
      selectedFrames: selectedFrames,
      elapsed: stopwatch.elapsed,
      fps: framesProcessed * Duration.microsecondsPerSecond / elapsedMicros,
      averageCandidatesPerFrame: framesProcessed == 0
          ? 0
          : candidatesDetected / framesProcessed,
    );
  }

  PoseProcessingBenchmarkResult runPoseProcessingBenchmark() {
    final frames = _samplePoseFrames();
    final detectors = _detectors();
    var framesProcessed = 0;
    var detectedEvents = 0;
    var completenessTotal = 0.0;
    const passes = 24;
    final stopwatch = Stopwatch()..start();
    for (var pass = 0; pass < passes; pass++) {
      for (final frame in frames) {
        completenessTotal += frame.completenessScore();
        for (final detector in detectors) {
          final ActionEvent? event = detector.process(frame);
          if (event != null) {
            detectedEvents += 1;
          }
        }
        framesProcessed += 1;
      }
    }
    stopwatch.stop();
    final elapsedMicros = stopwatch.elapsedMicroseconds <= 0
        ? 1
        : stopwatch.elapsedMicroseconds;
    return PoseProcessingBenchmarkResult(
      framesProcessed: framesProcessed,
      elapsed: stopwatch.elapsed,
      fps: framesProcessed * Duration.microsecondsPerSecond / elapsedMicros,
      detectedEvents: detectedEvents,
      averageCompleteness: completenessTotal / framesProcessed,
    );
  }

  List<ActionDetector> _detectors() {
    final model = CaptureModelCatalog.resolve(
      CaptureModelCatalog.defaultModelId,
    );
    final definition = ActionPatternCatalog.resolve(
      model.actionPatternId,
      preRollMs: 2000,
      postRollMs: 2000,
      cooldownMs: 1800,
    );
    return <ActionDetector>[
      ActionPatternMatcher(definition: definition),
      LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1800),
          minAbsVx: 0.42,
          minMeanWristSpeed: 0.28,
          minScore: 0.18,
          preRollMs: 2000,
          postRollMs: 2000,
        ),
      ),
    ];
  }

  List<Object> _sampleYoloPoseOutputs() {
    return <Object>[
      for (var i = 0; i < 120; i++)
        _channelFirstYoloOutput(<List<double>>[
          _sampleYoloPoseRow(
            centerX: 0.50 + ((i % 9) - 4) * 0.006,
            centerY: 0.52,
            confidence: 0.78,
          ),
          _sampleYoloPoseRow(
            centerX: 0.17,
            centerY: 0.50 + ((i % 7) - 3) * 0.004,
            confidence: 0.94,
          ),
          _sampleYoloPoseRow(
            centerX: 0.505 + ((i % 5) - 2) * 0.003,
            centerY: 0.522,
            confidence: 0.56,
          ),
        ]),
    ];
  }

  Object _channelFirstYoloOutput(List<List<double>> rows) {
    return <Object>[
      <Object>[
        for (var attr = 0; attr < rows.first.length; attr++)
          <double>[for (final row in rows) row[attr]],
      ],
    ];
  }

  List<double> _sampleYoloPoseRow({
    required double centerX,
    required double centerY,
    required double confidence,
  }) {
    const width = 0.26;
    const height = 0.55;
    final row = List<double>.filled(56, 0);
    row[0] = centerX;
    row[1] = centerY;
    row[2] = width;
    row[3] = height;
    row[4] = confidence;

    void keypoint(int index, double x, double y, [double score = 0.9]) {
      final offset = 5 + index * 3;
      row[offset] = x.clamp(0.0, 1.0).toDouble();
      row[offset + 1] = y.clamp(0.0, 1.0).toDouble();
      row[offset + 2] = score;
    }

    keypoint(0, centerX, centerY - 0.24);
    keypoint(5, centerX - 0.07, centerY - 0.13);
    keypoint(6, centerX + 0.07, centerY - 0.13);
    keypoint(7, centerX - 0.10, centerY - 0.03);
    keypoint(8, centerX + 0.10, centerY - 0.03);
    keypoint(9, centerX - 0.12, centerY + 0.07);
    keypoint(10, centerX + 0.12, centerY + 0.07);
    keypoint(11, centerX - 0.055, centerY + 0.10);
    keypoint(12, centerX + 0.055, centerY + 0.10);
    keypoint(13, centerX - 0.065, centerY + 0.23);
    keypoint(14, centerX + 0.065, centerY + 0.23);
    keypoint(15, centerX - 0.07, centerY + 0.31);
    keypoint(16, centerX + 0.07, centerY + 0.31);
    return row;
  }

  List<PoseFrame> _samplePoseFrames() {
    final base = DateTime(2026);
    return <PoseFrame>[
      for (var i = 0; i < 360; i++)
        _samplePoseFrame(
          timestamp: base.add(Duration(milliseconds: i * 8)),
          phase: (i % 90) / 89.0,
          cycle: i ~/ 90,
        ),
    ];
  }

  PoseFrame _samplePoseFrame({
    required DateTime timestamp,
    required double phase,
    required int cycle,
  }) {
    final reverse = cycle.isOdd;
    final swingX = reverse ? 0.72 - (phase * 0.34) : 0.38 + (phase * 0.34);
    final gatherBias = phase < 0.35 ? -0.04 : 0.04;
    return PoseFrame(
      timestamp: timestamp,
      landmarks: <PoseLandmark, PoseLandmarkPoint>{
        PoseLandmark.leftShoulder: const PoseLandmarkPoint(
          x: 0.42,
          y: 0.34,
          confidence: 0.92,
        ),
        PoseLandmark.rightShoulder: const PoseLandmarkPoint(
          x: 0.58,
          y: 0.34,
          confidence: 0.92,
        ),
        PoseLandmark.leftHip: const PoseLandmarkPoint(
          x: 0.44,
          y: 0.56,
          confidence: 0.90,
        ),
        PoseLandmark.rightHip: const PoseLandmarkPoint(
          x: 0.56,
          y: 0.56,
          confidence: 0.90,
        ),
        PoseLandmark.leftWrist: PoseLandmarkPoint(
          x: swingX + gatherBias,
          y: 0.40 + phase * 0.08,
          confidence: 0.88,
        ),
        PoseLandmark.rightWrist: PoseLandmarkPoint(
          x: swingX + 0.05 + gatherBias,
          y: 0.42 + phase * 0.07,
          confidence: 0.88,
        ),
        PoseLandmark.leftAnkle: const PoseLandmarkPoint(
          x: 0.38,
          y: 0.90,
          confidence: 0.82,
        ),
        PoseLandmark.rightAnkle: const PoseLandmarkPoint(
          x: 0.62,
          y: 0.90,
          confidence: 0.82,
        ),
      },
    );
  }
}
