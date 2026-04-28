/// A locally persisted swing clip entry shown in the history list.
class CaptureRecord {
  const CaptureRecord({
    required this.id,
    required this.videoPath,
    required this.thumbnailPath,
    required this.createdAt,
    required this.durationMs,
    required this.albumName,
    this.poseJsonPath,
    this.latitude,
    this.longitude,
    this.locationLabel,
  });

  final String id;
  final String videoPath;
  final String thumbnailPath;
  final DateTime createdAt;
  final int durationMs;
  final String albumName;
  final String? poseJsonPath;
  final double? latitude;
  final double? longitude;
  final String? locationLabel;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'videoPath': videoPath,
      'thumbnailPath': thumbnailPath,
      'createdAt': createdAt.toIso8601String(),
      'durationMs': durationMs,
      'albumName': albumName,
      'poseJsonPath': poseJsonPath,
      'latitude': latitude,
      'longitude': longitude,
      'locationLabel': locationLabel,
    };
  }

  factory CaptureRecord.fromMap(Map<dynamic, dynamic> map) {
    return CaptureRecord(
      id: map['id'] as String,
      videoPath: map['videoPath'] as String,
      thumbnailPath: map['thumbnailPath'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      durationMs: map['durationMs'] as int,
      albumName: map['albumName'] as String,
      poseJsonPath: map['poseJsonPath'] as String?,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      locationLabel: map['locationLabel'] as String?,
    );
  }
}
