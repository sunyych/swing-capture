import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../../../core/config/app_constants.dart';
import '../domain/models/pose_frame.dart' as swing_pose;

/// Wraps the native ML Kit pose detector and throttles frame processing so
/// preview, buffering, and inference do not saturate the device.
class PoseDetectionService {
  PoseDetectionService({
    Duration minProcessingInterval = const Duration(milliseconds: 80),
  }) : _minProcessingInterval = minProcessingInterval,
       _poseDetector = PoseDetector(
         options: PoseDetectorOptions(
           model: PoseDetectionModel.base,
           mode: PoseDetectionMode.stream,
         ),
       );

  final Duration _minProcessingInterval;
  final PoseDetector _poseDetector;
  bool _isProcessing = false;
  DateTime? _lastProcessedAt;
  DateTime? _lastNoPoseLogAt;
  DateTime? _lastPoseLogAt;

  Future<swing_pose.PoseFrame?> processCameraImage({
    required CameraImage image,
    required CameraDescription camera,
    required DeviceOrientation deviceOrientation,
  }) async {
    final now = DateTime.now();
    if (_isProcessing ||
        (_lastProcessedAt != null &&
            now.difference(_lastProcessedAt!) < _minProcessingInterval)) {
      return null;
    }

    final rotation = _rotationForInputImage(
      lensDirection: camera.lensDirection,
      sensorOrientation: camera.sensorOrientation,
      deviceOrientation: deviceOrientation,
    );
    final inputImage = _toInputImage(image: image, rotation: rotation);
    if (inputImage == null) {
      return null;
    }

    _isProcessing = true;
    _lastProcessedAt = now;

    try {
      final poses = await _poseDetector.processImage(inputImage);
      if (poses.isEmpty) {
        _debugLogNoPose(
          imageWidth: image.width,
          imageHeight: image.height,
          rotation: rotation,
          camera: camera,
        );
        return swing_pose.PoseFrame(timestamp: now, landmarks: const {});
      }

      final frame = _mapPoseToFrame(
        pose: poses.first,
        timestamp: now,
        imageWidth: image.width.toDouble(),
        imageHeight: image.height.toDouble(),
        rotation: rotation,
        isFrontCamera: camera.lensDirection == CameraLensDirection.front,
      );
      _debugLogPoseFrame(
        frame: frame,
        rotation: rotation,
        camera: camera,
        imageWidth: image.width,
        imageHeight: image.height,
      );
      return frame;
    } catch (error, stackTrace) {
      debugPrint('[PoseDetection] processImage failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> dispose() async {
    await _poseDetector.close();
  }

  InputImage? _toInputImage({
    required CameraImage image,
    required InputImageRotation? rotation,
  }) {
    final bytes = _extractBytes(image);
    final format = _inputFormatForCameraImage(image, bytes: bytes);
    if (rotation == null || format == null || image.planes.isEmpty) {
      debugPrint(
        '[PoseDetection] input image rejected '
        'rotation=${rotation?.rawValue ?? 'null'} '
        'formatRaw=${image.format.raw} '
        'planes=${image.planes.length}',
      );
      return null;
    }
    if (bytes == null) {
      debugPrint(
        '[PoseDetection] failed to extract camera bytes '
        'formatRaw=${image.format.raw} '
        'planes=${image.planes.length}',
      );
      return null;
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  /// Maps [CameraImage.format] to ML Kit [InputImageFormat], with Android fallbacks.
  InputImageFormat? _inputFormatForCameraImage(
    CameraImage image, {
    required Uint8List? bytes,
  }) {
    final fromRaw = InputImageFormatValue.fromRawValue(image.format.raw);
    if (fromRaw == InputImageFormat.nv21 || fromRaw == InputImageFormat.yv12) {
      return fromRaw;
    }
    if (Platform.isIOS) {
      return InputImageFormat.bgra8888;
    }
    if (bytes != null) {
      return InputImageFormat.nv21;
    }
    return null;
  }

  /// Rotation ML Kit expects for the camera image buffer (Android).
  InputImageRotation? _rotationForInputImage({
    required CameraLensDirection lensDirection,
    required int sensorOrientation,
    required DeviceOrientation deviceOrientation,
  }) {
    if (Platform.isIOS) {
      return _rotationFromDegrees(sensorOrientation) ??
          InputImageRotation.rotation0deg;
    }

    final rotationCompensation = switch (deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };

    int rotation;
    if (lensDirection == CameraLensDirection.front) {
      rotation = (sensorOrientation + rotationCompensation) % 360;
      rotation = (360 - rotation) % 360;
    } else {
      rotation = (sensorOrientation - rotationCompensation + 360) % 360;
    }

    final snapped = ((rotation + 45) ~/ 90) * 90 % 360;
    return InputImageRotationValue.fromRawValue(snapped);
  }

  Uint8List? _extractBytes(CameraImage image) {
    if (Platform.isIOS) {
      return image.planes.first.bytes;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (image.planes.length == 1 &&
        (format == InputImageFormat.nv21 || format == null)) {
      return image.planes.first.bytes;
    }

    if (image.planes.length == 3) {
      return _yuv420ToNv21(image);
    }
    return null;
  }

  InputImageRotation? _rotationFromDegrees(int degrees) {
    return switch (degrees) {
      0 => InputImageRotation.rotation0deg,
      90 => InputImageRotation.rotation90deg,
      180 => InputImageRotation.rotation180deg,
      270 => InputImageRotation.rotation270deg,
      _ => null,
    };
  }

  swing_pose.PoseFrame _mapPoseToFrame({
    required Pose pose,
    required DateTime timestamp,
    required double imageWidth,
    required double imageHeight,
    required InputImageRotation? rotation,
    required bool isFrontCamera,
  }) {
    final landmarks = <swing_pose.PoseLandmark, swing_pose.PoseLandmarkPoint>{};

    void addLandmark(swing_pose.PoseLandmark key, PoseLandmarkType type) {
      final landmark = pose.landmarks[type];
      if (landmark == null) {
        return;
      }

      final normalized = _normalizeToPreview(
        x: landmark.x,
        y: landmark.y,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        rotation: rotation,
        isFrontCamera: isFrontCamera,
      );
      landmarks[key] = swing_pose.PoseLandmarkPoint(
        x: normalized.$1,
        y: normalized.$2,
        confidence: landmark.likelihood,
      );
    }

    addLandmark(swing_pose.PoseLandmark.nose, PoseLandmarkType.nose);
    addLandmark(
      swing_pose.PoseLandmark.leftShoulder,
      PoseLandmarkType.leftShoulder,
    );
    addLandmark(
      swing_pose.PoseLandmark.rightShoulder,
      PoseLandmarkType.rightShoulder,
    );
    addLandmark(swing_pose.PoseLandmark.leftElbow, PoseLandmarkType.leftElbow);
    addLandmark(
      swing_pose.PoseLandmark.rightElbow,
      PoseLandmarkType.rightElbow,
    );
    addLandmark(swing_pose.PoseLandmark.leftWrist, PoseLandmarkType.leftWrist);
    addLandmark(
      swing_pose.PoseLandmark.rightWrist,
      PoseLandmarkType.rightWrist,
    );
    addLandmark(swing_pose.PoseLandmark.leftHip, PoseLandmarkType.leftHip);
    addLandmark(swing_pose.PoseLandmark.rightHip, PoseLandmarkType.rightHip);
    addLandmark(swing_pose.PoseLandmark.leftKnee, PoseLandmarkType.leftKnee);
    addLandmark(swing_pose.PoseLandmark.rightKnee, PoseLandmarkType.rightKnee);
    addLandmark(swing_pose.PoseLandmark.leftAnkle, PoseLandmarkType.leftAnkle);
    addLandmark(
      swing_pose.PoseLandmark.rightAnkle,
      PoseLandmarkType.rightAnkle,
    );

    return swing_pose.PoseFrame(timestamp: timestamp, landmarks: landmarks);
  }

  /// ML Kit returns landmark coordinates in image space; align them with the
  /// upright camera preview so the skeleton paints in the visible preview rect.
  (double, double) _normalizeToPreview({
    required double x,
    required double y,
    required double imageWidth,
    required double imageHeight,
    required InputImageRotation? rotation,
    required bool isFrontCamera,
  }) {
    // ML Kit already uses the declared input rotation to interpret the camera
    // bytes. The returned landmarks are therefore in the display-oriented
    // image space, so we only need to normalize against the oriented frame
    // size here instead of rotating the coordinates a second time.
    final orientedWidth = switch (rotation) {
      InputImageRotation.rotation90deg ||
      InputImageRotation.rotation270deg => imageHeight,
      InputImageRotation.rotation0deg ||
      InputImageRotation.rotation180deg ||
      null => imageWidth,
    };
    final orientedHeight = switch (rotation) {
      InputImageRotation.rotation90deg ||
      InputImageRotation.rotation270deg => imageWidth,
      InputImageRotation.rotation0deg ||
      InputImageRotation.rotation180deg ||
      null => imageHeight,
    };

    final normalizedX = (x / orientedWidth).clamp(0, 1).toDouble();
    final normalizedY = (y / orientedHeight).clamp(0, 1).toDouble();

    if (!isFrontCamera) {
      return (normalizedX, normalizedY);
    }
    return ((1 - normalizedX).clamp(0, 1).toDouble(), normalizedY);
  }

  void _debugLogNoPose({
    required int imageWidth,
    required int imageHeight,
    required InputImageRotation? rotation,
    required CameraDescription camera,
  }) {
    final now = DateTime.now();
    if (_lastNoPoseLogAt != null &&
        now.difference(_lastNoPoseLogAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastNoPoseLogAt = now;
    debugPrint(
      '[PoseDetection] no poses detected '
      'lens=${camera.lensDirection.name} '
      'image=${imageWidth}x$imageHeight '
      'rotation=${rotation?.rawValue ?? 'null'}',
    );
  }

  void _debugLogPoseFrame({
    required swing_pose.PoseFrame frame,
    required InputImageRotation? rotation,
    required CameraDescription camera,
    required int imageWidth,
    required int imageHeight,
  }) {
    if (AppConstants.verbosePoseJsonLog) {
      return;
    }
    final now = DateTime.now();
    if (_lastPoseLogAt != null &&
        now.difference(_lastPoseLogAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastPoseLogAt = now;
    final leftWrist = frame.landmarks[swing_pose.PoseLandmark.leftWrist];
    final rightWrist = frame.landmarks[swing_pose.PoseLandmark.rightWrist];
    debugPrint(
      '[PoseDetection] pose mapped '
      'lens=${camera.lensDirection.name} '
      'image=${imageWidth}x$imageHeight '
      'rotation=${rotation?.rawValue ?? 'null'} '
      'landmarks=${frame.landmarks.length} '
      'lw=${_formatPoint(leftWrist)} '
      'rw=${_formatPoint(rightWrist)}',
    );
  }

  String _formatPoint(swing_pose.PoseLandmarkPoint? point) {
    if (point == null) {
      return 'null';
    }
    return '(${point.x.toStringAsFixed(2)},${point.y.toStringAsFixed(2)},'
        '${point.confidence.toStringAsFixed(2)})';
  }

  /// CameraX commonly delivers YUV_420_888 for analysis even when NV21 was
  /// requested. ML Kit's Flutter bridge only accepts NV21/YV12 on Android, so
  /// repack the three planes into a contiguous NV21 buffer here.
  Uint8List _yuv420ToNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final nv21 = Uint8List(width * height + (width * height ~/ 2));
    var writeIndex = 0;

    final yRowStride = yPlane.bytesPerRow;
    final yPixelStride = yPlane.bytesPerPixel ?? 1;
    for (var row = 0; row < height; row++) {
      final rowOffset = row * yRowStride;
      for (var col = 0; col < width; col++) {
        nv21[writeIndex++] = yPlane.bytes[rowOffset + col * yPixelStride];
      }
    }

    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final chromaHeight = height ~/ 2;
    final chromaWidth = width ~/ 2;
    for (var row = 0; row < chromaHeight; row++) {
      final rowOffset = row * uvRowStride;
      for (var col = 0; col < chromaWidth; col++) {
        final offset = rowOffset + col * uvPixelStride;
        nv21[writeIndex++] = vPlane.bytes[offset];
        nv21[writeIndex++] = uPlane.bytes[offset];
      }
    }

    return nv21;
  }
}
