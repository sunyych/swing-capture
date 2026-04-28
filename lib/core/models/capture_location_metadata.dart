/// Optional location metadata attached to a captured clip.
class CaptureLocationMetadata {
  const CaptureLocationMetadata({
    required this.latitude,
    required this.longitude,
    required this.label,
  });

  final double? latitude;
  final double? longitude;
  final String? label;
}
