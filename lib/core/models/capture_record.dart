/// A locally persisted swing clip entry shown in the history list.
enum CaptureSessionStatus { draft, committed }

enum CaptureReviewState { unreviewed, accepted, rejected, needsReview }

enum CaptureDatasetState { extracted, labeled, verified, uploaded }

enum TrainingLifecycleState { none, queued, training, completed, failed }

class CaptureRecord {
  const CaptureRecord({
    required this.id,
    required this.videoPath,
    required this.thumbnailPath,
    required this.createdAt,
    required this.durationMs,
    required this.albumName,
    this.videoFps,
    this.poseJsonPath,
    this.latitude,
    this.longitude,
    this.locationLabel,
    this.sessionId,
    this.clipIndex,
    this.sessionStatus,
    this.userTag,
    this.reviewState = CaptureReviewState.unreviewed,
    this.datasetState = CaptureDatasetState.extracted,
    this.modelLabel,
    this.modelConfidence,
    this.trainingState = TrainingLifecycleState.none,
  });

  final String id;
  final String videoPath;
  final String thumbnailPath;
  final DateTime createdAt;
  final int durationMs;
  final String albumName;
  final double? videoFps;
  final String? poseJsonPath;
  final double? latitude;
  final double? longitude;
  final String? locationLabel;
  final String? sessionId;
  final int? clipIndex;
  final CaptureSessionStatus? sessionStatus;
  final String? userTag;
  final CaptureReviewState reviewState;
  final CaptureDatasetState datasetState;
  final String? modelLabel;
  final double? modelConfidence;
  final TrainingLifecycleState trainingState;

  CaptureRecord copyWith({
    String? userTag,
    CaptureReviewState? reviewState,
    CaptureDatasetState? datasetState,
    String? modelLabel,
    double? modelConfidence,
    TrainingLifecycleState? trainingState,
    double? videoFps,
  }) {
    return CaptureRecord(
      id: id,
      videoPath: videoPath,
      thumbnailPath: thumbnailPath,
      createdAt: createdAt,
      durationMs: durationMs,
      albumName: albumName,
      videoFps: videoFps ?? this.videoFps,
      poseJsonPath: poseJsonPath,
      latitude: latitude,
      longitude: longitude,
      locationLabel: locationLabel,
      sessionId: sessionId,
      clipIndex: clipIndex,
      sessionStatus: sessionStatus,
      userTag: userTag ?? this.userTag,
      reviewState: reviewState ?? this.reviewState,
      datasetState: datasetState ?? this.datasetState,
      modelLabel: modelLabel ?? this.modelLabel,
      modelConfidence: modelConfidence ?? this.modelConfidence,
      trainingState: trainingState ?? this.trainingState,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'videoPath': videoPath,
      'thumbnailPath': thumbnailPath,
      'createdAt': createdAt.toIso8601String(),
      'durationMs': durationMs,
      'albumName': albumName,
      'videoFps': videoFps,
      'poseJsonPath': poseJsonPath,
      'latitude': latitude,
      'longitude': longitude,
      'locationLabel': locationLabel,
      'sessionId': sessionId,
      'clipIndex': clipIndex,
      'sessionStatus': sessionStatus?.name,
      'userTag': userTag,
      'reviewState': reviewState.name,
      'datasetState': datasetState.name,
      'modelLabel': modelLabel,
      'modelConfidence': modelConfidence,
      'trainingState': trainingState.name,
    };
  }

  factory CaptureRecord.fromMap(Map<dynamic, dynamic> map) {
    return CaptureRecord(
      id: map['id'] as String,
      videoPath: map['videoPath'] as String,
      thumbnailPath: map['thumbnailPath'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      durationMs: (map['durationMs'] as num).toInt(),
      albumName: map['albumName'] as String,
      videoFps: (map['videoFps'] as num?)?.toDouble(),
      poseJsonPath: map['poseJsonPath'] as String?,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      locationLabel: map['locationLabel'] as String?,
      sessionId: map['sessionId'] as String?,
      clipIndex: (map['clipIndex'] as num?)?.toInt(),
      sessionStatus: _captureSessionStatusFromWire(map['sessionStatus']),
      userTag: map['userTag'] as String?,
      reviewState: _captureReviewStateFromWire(map['reviewState']),
      datasetState: _captureDatasetStateFromWire(map['datasetState']),
      modelLabel: map['modelLabel'] as String?,
      modelConfidence: (map['modelConfidence'] as num?)?.toDouble(),
      trainingState: _trainingLifecycleStateFromWire(map['trainingState']),
    );
  }
}

CaptureSessionStatus? _captureSessionStatusFromWire(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return null;
  }
  for (final value in CaptureSessionStatus.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return null;
}

CaptureReviewState _captureReviewStateFromWire(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return CaptureReviewState.unreviewed;
  }
  for (final value in CaptureReviewState.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return CaptureReviewState.unreviewed;
}

CaptureDatasetState _captureDatasetStateFromWire(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return CaptureDatasetState.extracted;
  }
  for (final value in CaptureDatasetState.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return CaptureDatasetState.extracted;
}

TrainingLifecycleState _trainingLifecycleStateFromWire(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return TrainingLifecycleState.none;
  }
  for (final value in TrainingLifecycleState.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return TrainingLifecycleState.none;
}
