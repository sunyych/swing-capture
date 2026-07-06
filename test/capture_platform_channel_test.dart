import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/capture_settings.dart';
import 'package:swingcapture/platform_channels/capture_platform_channel.dart';

void main() {
  group('NativeBufferStateEvent.fromMap', () {
    test('parses buffer_state fields including targetFps and achievedFps', () {
      final event = NativeBufferStateEvent.fromMap({
        'buffering': true,
        'completedSegmentCount': 3,
        'segmentSliceMs': 500,
        'targetFps': 120.0,
        'achievedFps': 118.5,
        'highSpeed': true,
      });

      expect(event.isBuffering, isTrue);
      expect(event.completedSegmentCount, 3);
      expect(event.segmentSliceMs, 500);
      expect(event.targetFps, 120.0);
      expect(event.achievedFps, 118.5);
      expect(event.highSpeed, isTrue);
    });

    test('uses legacy nominalTargetFps when targetFps is absent', () {
      final fromNominal = NativeBufferStateEvent.fromMap({
        'buffering': false,
        'nominalTargetFps': 240,
      });
      expect(fromNominal.targetFps, 240.0);
    });

    test('ignores legacy nominalTargetFps when negative', () {
      final event = NativeBufferStateEvent.fromMap({
        'buffering': true,
        'nominalTargetFps': -1,
      });
      expect(event.targetFps, isNull);
    });

    test('explicit targetFps wins over legacy nominalTargetFps', () {
      final event = NativeBufferStateEvent.fromMap({
        'buffering': true,
        'targetFps': 60.0,
        'nominalTargetFps': 240,
      });
      expect(event.targetFps, 60.0);
    });

    test(
      'highFpsEnabled fallback supplies highSpeed when highSpeed absent',
      () {
        final legacy = NativeBufferStateEvent.fromMap({
          'buffering': true,
          'highFpsEnabled': true,
        });
        expect(legacy.highSpeed, isTrue);

        final explicitFalse = NativeBufferStateEvent.fromMap({
          'buffering': true,
          'highSpeed': false,
          'highFpsEnabled': true,
        });
        expect(explicitFalse.highSpeed, isFalse);
      },
    );
  });

  group('NativeCaptureEvent.fromMap', () {
    test('parses camera_state with fractional logical zoom', () {
      final event = NativeCaptureEvent.fromMap({
        'type': 'camera_state',
        'lensDirection': 'back',
        'minZoom': 0.5,
        'maxZoom': 12.0,
        'zoom': 0.75,
      });

      expect(event, isA<NativeCameraStateEvent>());
      final camera = event as NativeCameraStateEvent;
      expect(camera.lensDirection, 'back');
      expect(camera.minZoom, 0.5);
      expect(camera.maxZoom, 12.0);
      expect(camera.zoom, 0.75);
    });

    test('dispatches buffer_state to NativeBufferStateEvent', () {
      final event = NativeCaptureEvent.fromMap({
        'type': 'buffer_state',
        'buffering': true,
        'targetFps': 30.0,
      });
      expect(event, isA<NativeBufferStateEvent>());
      final buffer = event as NativeBufferStateEvent;
      expect(buffer.isBuffering, isTrue);
      expect(buffer.targetFps, 30.0);
    });

    test('dispatches video_import_progress to progress event', () {
      final event = NativeCaptureEvent.fromMap({
        'type': 'video_import_progress',
        'jobId': 'import_1',
        'phase': 'extracting',
        'progress': 0.42,
        'processedFrames': 42,
        'totalFrames': 100,
        'message': 'Extracting pose JSON... 42%',
      });

      expect(event, isA<NativeVideoImportProgressEvent>());
      final progress = event as NativeVideoImportProgressEvent;
      expect(progress.jobId, 'import_1');
      expect(progress.phase, 'extracting');
      expect(progress.progress, 0.42);
      expect(progress.processedFrames, 42);
      expect(progress.totalFrames, 100);
      expect(progress.message, 'Extracting pose JSON... 42%');
    });
  });

  group('NativeRecordingCapability.fromMap', () {
    test('maps native max fps to recommended fps mode', () {
      final capability = NativeRecordingCapability.fromMap({
        'maxFps': 120,
        'supportedFps': [30, 60, 120],
        'source': 'camera2',
        'cameraLabel': 'back camera',
      });

      expect(capability.maxFps, 120);
      expect(capability.supportedFps, [30, 60, 120]);
      expect(capability.recommendedFpsMode, VideoFpsMode.high120);
      expect(capability.summary, '120 fps back camera');
    });

    test('preserves 240fps capability as the fastest recording mode', () {
      final capability = NativeRecordingCapability.fromMap({
        'maxFps': 240,
        'supportedFps': [30, 60, 120, 240],
        'source': 'camera2',
      });

      expect(capability.maxFps, 240);
      expect(capability.recommendedFpsMode, VideoFpsMode.high240);
      expect(
        minimumHighSpeedVideoFpsMode(capability.recommendedFpsMode),
        VideoFpsMode.high240,
      );
    });

    test('native recommended mode overrides max fps bucket', () {
      final capability = NativeRecordingCapability.fromMap({
        'maxFps': 240,
        'recommendedVideoFpsMode': 'fps120',
      });

      expect(capability.recommendedFpsMode, VideoFpsMode.high120);
    });

    test('parses per-lens recording capabilities', () {
      final capability = NativeRecordingCapability.fromMap({
        'maxFps': 60,
        'supportedFps': [30, 60],
        'source': 'camera2',
        'cameraLabel': 'across 2 lenses',
        'lensCapabilities': [
          {
            'cameraLabel': 'back 1.0x lens',
            'lensDirection': 'back',
            'maxFps': 240,
            'supportedFps': [30, 60, 120, 240],
          },
          {
            'cameraLabel': 'back 3.0x lens',
            'lensDirection': 'back',
            'maxFps': 60,
            'supportedFps': [30, 60],
          },
        ],
      });

      expect(capability.maxFps, 60);
      expect(capability.recommendedFpsMode, VideoFpsMode.high60);
      expect(capability.summary, '60 fps across 2 lenses');
      expect(capability.lensCapabilities, hasLength(2));
      expect(
        capability.lensCapabilities.first.summary,
        'back 1.0x lens 240 fps',
      );
      expect(
        capability.lensSummary,
        'back 1.0x lens 240 fps, back 3.0x lens 60 fps',
      );
    });
  });
}
