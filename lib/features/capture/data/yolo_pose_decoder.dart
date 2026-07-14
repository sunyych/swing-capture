import '../domain/models/pose_candidate.dart';
import '../domain/models/pose_frame.dart';

enum YoloPoseBoxFormat { centerXywh, xyxy }

class YoloPoseDecoderConfig {
  const YoloPoseDecoderConfig({
    this.inputWidth = 640,
    this.inputHeight = 640,
    this.keypointCount = 17,
    this.attributesBeforeKeypoints = 5,
    this.minPoseConfidence = 0.25,
    this.minKeypointConfidence = 0.2,
    this.nmsIouThreshold = 0.45,
    this.maxDetections = 8,
    this.boxFormat = YoloPoseBoxFormat.centerXywh,
  });

  final int inputWidth;
  final int inputHeight;
  final int keypointCount;
  final int attributesBeforeKeypoints;
  final double minPoseConfidence;
  final double minKeypointConfidence;
  final double nmsIouThreshold;
  final int maxDetections;
  final YoloPoseBoxFormat boxFormat;

  int get minimumAttributeCount =>
      attributesBeforeKeypoints + keypointCount * 3;
}

class YoloPoseDecoder {
  const YoloPoseDecoder({this.config = const YoloPoseDecoderConfig()});

  final YoloPoseDecoderConfig config;

  List<PoseCandidate> decode({
    required Object output,
    required DateTime timestamp,
  }) {
    final rows = _predictionRows(output);
    final candidates = <PoseCandidate>[];
    for (final row in rows) {
      if (row.length < config.minimumAttributeCount) {
        continue;
      }
      final confidence = row[4].clamp(0.0, 1.0).toDouble();
      if (confidence < config.minPoseConfidence) {
        continue;
      }
      final landmarks = _decodeLandmarks(row);
      final bounds = _decodeBounds(row);
      candidates.add(
        PoseCandidate(
          source: PoseFrameSource.yolo,
          timestamp: timestamp,
          landmarks: landmarks,
          confidence: confidence,
          bounds: bounds,
        ),
      );
    }
    return _nonMaxSuppression(candidates);
  }

  List<List<double>> _predictionRows(Object output) {
    final value = _stripSingleBatch(output);
    if (value is List) {
      final channelsFirst = _looksChannelFirst(value);
      if (channelsFirst) {
        final transposed = _tryChannelsFirst(value);
        if (transposed != null) {
          return transposed;
        }
      }
      final rows = _tryCandidateRows(value);
      if (rows != null) {
        return rows;
      }
      final transposed = _tryChannelsFirst(value);
      if (transposed != null) {
        return transposed;
      }
    }

    final flat = <double>[];
    _flattenNumbers(output, flat);
    final attrs = config.minimumAttributeCount;
    if (flat.isEmpty || flat.length % attrs != 0) {
      return const <List<double>>[];
    }
    return [
      for (var i = 0; i < flat.length; i += attrs) flat.sublist(i, i + attrs),
    ];
  }

  Object _stripSingleBatch(Object output) {
    var value = output;
    while (value is List && value.length == 1 && value.first is List) {
      value = value.first as Object;
    }
    return value;
  }

  bool _looksChannelFirst(List<dynamic> value) {
    if (value.length < config.minimumAttributeCount || value.length > 256) {
      return false;
    }
    final first = _numbersInShallowList(value.first);
    if (first == null) {
      return false;
    }
    return first.length > value.length;
  }

  List<List<double>>? _tryCandidateRows(List<dynamic> value) {
    if (value.isEmpty) {
      return null;
    }
    final rows = <List<double>>[];
    for (final row in value) {
      final numbers = _numbersInShallowList(row);
      if (numbers == null || numbers.length < config.minimumAttributeCount) {
        return null;
      }
      rows.add(numbers);
    }
    return rows;
  }

  List<List<double>>? _tryChannelsFirst(List<dynamic> value) {
    if (value.length < config.minimumAttributeCount) {
      return null;
    }
    final channels = <List<double>>[];
    for (final channel in value) {
      final numbers = _numbersInShallowList(channel);
      if (numbers == null || numbers.isEmpty) {
        return null;
      }
      channels.add(numbers);
    }
    final candidateCount = channels
        .map((channel) => channel.length)
        .reduce((a, b) => a < b ? a : b);
    return [
      for (var i = 0; i < candidateCount; i++)
        [for (final channel in channels) channel[i]],
    ];
  }

  List<double>? _numbersInShallowList(Object? value) {
    if (value is! List) {
      return null;
    }
    final numbers = <double>[];
    for (final item in value) {
      if (item is! num) {
        return null;
      }
      numbers.add(item.toDouble());
    }
    return numbers;
  }

  void _flattenNumbers(Object? value, List<double> out) {
    if (value is num) {
      out.add(value.toDouble());
      return;
    }
    if (value is Iterable) {
      for (final item in value) {
        _flattenNumbers(item, out);
      }
    }
  }

  PoseBounds _decodeBounds(List<double> row) {
    if (config.boxFormat == YoloPoseBoxFormat.xyxy) {
      final left = _normalizeX(row[0]);
      final top = _normalizeY(row[1]);
      final right = _normalizeX(row[2]);
      final bottom = _normalizeY(row[3]);
      return PoseBounds(
        left: left < right ? left : right,
        top: top < bottom ? top : bottom,
        right: right > left ? right : left,
        bottom: bottom > top ? bottom : top,
      ).clamp();
    }

    final centerX = _normalizeX(row[0]);
    final centerY = _normalizeY(row[1]);
    final width = _normalizeWidth(row[2]);
    final height = _normalizeHeight(row[3]);
    return PoseBounds(
      left: centerX - width / 2,
      top: centerY - height / 2,
      right: centerX + width / 2,
      bottom: centerY + height / 2,
    ).clamp();
  }

  Map<PoseLandmark, PoseLandmarkPoint> _decodeLandmarks(List<double> row) {
    final landmarks = <PoseLandmark, PoseLandmarkPoint>{};
    for (var i = 0; i < config.keypointCount; i++) {
      final landmark = _coco17ToSwingLandmark[i];
      if (landmark == null) {
        continue;
      }
      final offset = config.attributesBeforeKeypoints + i * 3;
      if (offset + 2 >= row.length) {
        break;
      }
      final confidence = row[offset + 2].clamp(0.0, 1.0).toDouble();
      if (confidence < config.minKeypointConfidence) {
        continue;
      }
      landmarks[landmark] = PoseLandmarkPoint(
        x: _normalizeX(row[offset]),
        y: _normalizeY(row[offset + 1]),
        confidence: confidence,
      );
    }
    return landmarks;
  }

  List<PoseCandidate> _nonMaxSuppression(List<PoseCandidate> candidates) {
    final sorted = List<PoseCandidate>.from(candidates)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <PoseCandidate>[];
    for (final candidate in sorted) {
      final overlaps = kept.any(
        (existing) =>
            candidate.bounds.iou(existing.bounds) > config.nmsIouThreshold,
      );
      if (overlaps) {
        continue;
      }
      kept.add(candidate);
      if (kept.length >= config.maxDetections) {
        break;
      }
    }
    return kept;
  }

  double _normalizeX(double value) => _normalize(value, config.inputWidth);
  double _normalizeY(double value) => _normalize(value, config.inputHeight);
  double _normalizeWidth(double value) => _normalize(value, config.inputWidth);
  double _normalizeHeight(double value) =>
      _normalize(value, config.inputHeight);

  double _normalize(double value, int scale) {
    if (!value.isFinite) {
      return 0;
    }
    if (value >= 0 && value <= 1) {
      return value;
    }
    return (value / scale).clamp(0.0, 1.0).toDouble();
  }
}

const Map<int, PoseLandmark> _coco17ToSwingLandmark = {
  0: PoseLandmark.nose,
  5: PoseLandmark.leftShoulder,
  6: PoseLandmark.rightShoulder,
  7: PoseLandmark.leftElbow,
  8: PoseLandmark.rightElbow,
  9: PoseLandmark.leftWrist,
  10: PoseLandmark.rightWrist,
  11: PoseLandmark.leftHip,
  12: PoseLandmark.rightHip,
  13: PoseLandmark.leftKnee,
  14: PoseLandmark.rightKnee,
  15: PoseLandmark.leftAnkle,
  16: PoseLandmark.rightAnkle,
};
