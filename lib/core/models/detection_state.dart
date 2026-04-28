enum DetectionStage { idle, hitterDetected, ready, swingDetected, saving }

/// Snapshot of the live capture state used by the UI and native bridge.
class DetectionState {
  const DetectionState({
    required this.stage,
    required this.hasHitter,
    required this.isBuffering,
    required this.showDebugOverlay,
    this.statusText,
    this.hitterConfidence,
    this.debugPoints = const [],
  });

  final DetectionStage stage;
  final bool hasHitter;
  final bool isBuffering;
  final bool showDebugOverlay;
  final String? statusText;
  final double? hitterConfidence;
  final List<PosePoint> debugPoints;

  DetectionState copyWith({
    DetectionStage? stage,
    bool? hasHitter,
    bool? isBuffering,
    bool? showDebugOverlay,
    String? statusText,
    double? hitterConfidence,
    List<PosePoint>? debugPoints,
  }) {
    return DetectionState(
      stage: stage ?? this.stage,
      hasHitter: hasHitter ?? this.hasHitter,
      isBuffering: isBuffering ?? this.isBuffering,
      showDebugOverlay: showDebugOverlay ?? this.showDebugOverlay,
      statusText: statusText ?? this.statusText,
      hitterConfidence: hitterConfidence ?? this.hitterConfidence,
      debugPoints: debugPoints ?? this.debugPoints,
    );
  }

  factory DetectionState.initial({required bool showDebugOverlay}) {
    return DetectionState(
      stage: DetectionStage.idle,
      hasHitter: false,
      isBuffering: false,
      showDebugOverlay: showDebugOverlay,
      statusText: 'Idle',
    );
  }
}

class PosePoint {
  const PosePoint({
    required this.x,
    required this.y,
    required this.confidence,
    this.name,
  });

  final double x;
  final double y;
  final double confidence;
  final String? name;
}
