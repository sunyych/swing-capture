import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../domain/models/pose_candidate.dart';
import 'yolo_pose_decoder.dart';

class YoloPoseDetectionService {
  YoloPoseDetectionService({
    YoloPoseDecoder decoder = const YoloPoseDecoder(),
    String? modelPath,
  }) : _decoder = decoder,
       _configuredModelPath = modelPath;

  static const modelAssetPath = 'assets/models/yolo_pose.tflite';
  static const metadataAssetPath = 'assets/models/yolo_pose_metadata.json';
  static const modelFileName = 'yolo_pose.tflite';
  static const metadataFileName = 'yolo_pose_metadata.json';

  final YoloPoseDecoder _decoder;
  final String? _configuredModelPath;
  Interpreter? _interpreter;

  Future<void> close() async {
    _interpreter?.close();
    _interpreter = null;
  }

  Future<bool> isModelAvailable() async {
    final file = await _modelFile();
    return file.existsSync();
  }

  /// Runs an already-preprocessed YOLO input tensor and returns all people found.
  ///
  /// The caller owns camera/image preprocessing so this service can stay reusable
  /// across Flutter camera frames, native video import, and future platform
  /// accelerators.
  Future<List<PoseCandidate>> detectPreparedInput({
    required Object input,
    required DateTime timestamp,
  }) async {
    await _ensureLoaded();
    final output = _emptyOutputBuffer(_interpreter!.getOutputTensor(0).shape);
    _interpreter!.run(input, output);
    return decodeOutput(output: output, timestamp: timestamp);
  }

  List<PoseCandidate> decodeOutput({
    required Object output,
    required DateTime timestamp,
  }) {
    return _decoder.decode(output: output, timestamp: timestamp);
  }

  Future<void> _ensureLoaded() async {
    if (_interpreter != null) {
      return;
    }
    final file = await _modelFile();
    if (!file.existsSync()) {
      await _tryMaterializeAssetToFile(modelAssetPath, file);
    }
    if (!file.existsSync()) {
      throw StateError(
        'Missing YOLO pose TFLite model. Place it at ${file.path}, or bundle '
        '$modelAssetPath and add it to pubspec.yaml assets.',
      );
    }
    await _tryMaterializeMetadata();
    _interpreter = Interpreter.fromFile(file);
  }

  Future<File> _modelFile() async {
    if (_configuredModelPath != null) {
      return File(_configuredModelPath);
    }
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/models/$modelFileName');
  }

  Future<void> _tryMaterializeMetadata() async {
    final appDir = await getApplicationDocumentsDirectory();
    final metadataFile = File('${appDir.path}/models/$metadataFileName');
    if (metadataFile.existsSync()) {
      return;
    }
    await _tryMaterializeAssetToFile(metadataAssetPath, metadataFile);
    if (!metadataFile.existsSync()) {
      return;
    }
    // Validate early so a broken metadata file is caught during setup.
    json.decode(metadataFile.readAsStringSync());
  }

  Future<void> _tryMaterializeAssetToFile(String assetPath, File target) async {
    try {
      final byteData = await rootBundle.load(assetPath);
      target.parent.createSync(recursive: true);
      await target.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
        flush: true,
      );
    } catch (_) {
      // Missing optional assets are handled by the caller's file existence check.
    }
  }

  Object _emptyOutputBuffer(List<int> shape) {
    if (shape.isEmpty) {
      return 0.0;
    }
    if (shape.length == 1) {
      return List<double>.filled(shape.first, 0);
    }
    return List<Object>.generate(
      shape.first,
      (_) => _emptyOutputBuffer(shape.sublist(1)),
    );
  }
}
