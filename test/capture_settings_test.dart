import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swingcapture/core/config/app_constants.dart';
import 'package:swingcapture/core/models/capture_settings.dart';
import 'package:swingcapture/features/settings/data/shared_prefs_settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('videoFpsModeFromWire', () {
    test('maps wired tokens and defaults unknown/null to standard', () {
      expect(videoFpsModeFromWire(null), VideoFpsMode.standard);
      expect(videoFpsModeFromWire(''), VideoFpsMode.standard);
      expect(videoFpsModeFromWire('standard'), VideoFpsMode.standard);
      expect(videoFpsModeFromWire('fps60'), VideoFpsMode.high60);
      expect(videoFpsModeFromWire('fps120'), VideoFpsMode.high120);
      expect(videoFpsModeFromWire('fps240'), VideoFpsMode.high240);
      expect(videoFpsModeFromWire('maxSupported'), VideoFpsMode.maxSupported);
      expect(videoFpsModeFromWire('unknown'), VideoFpsMode.standard);
    });
  });

  group('VideoFpsModeWire', () {
    test('wireValue round-trips with videoFpsModeFromWire', () {
      for (final mode in VideoFpsMode.values) {
        expect(videoFpsModeFromWire(mode.wireValue), mode);
      }
    });

    test('nominalTargetFps reflects UI / bitrate hints', () {
      expect(VideoFpsMode.standard.nominalTargetFps, 30);
      expect(VideoFpsMode.high60.nominalTargetFps, 60);
      expect(VideoFpsMode.high120.nominalTargetFps, 120);
      expect(VideoFpsMode.high240.nominalTargetFps, 240);
      expect(VideoFpsMode.maxSupported.nominalTargetFps, 240);
    });
  });

  group('VideoFpsModeIosCapture', () {
    test('iosCaptureFps is null for standard only', () {
      expect(VideoFpsMode.standard.iosCaptureFps, isNull);
      expect(VideoFpsMode.high60.iosCaptureFps, 60);
      expect(VideoFpsMode.high120.iosCaptureFps, 120);
      expect(VideoFpsMode.high240.iosCaptureFps, 240);
      expect(VideoFpsMode.maxSupported.iosCaptureFps, 240);
    });

    test('iosVideoBitrate scales with high-speed modes', () {
      expect(VideoFpsMode.standard.iosVideoBitrate, isNull);
      expect(VideoFpsMode.high60.iosVideoBitrate, 16_000_000);
      expect(VideoFpsMode.high120.iosVideoBitrate, 28_000_000);
      expect(VideoFpsMode.high240.iosVideoBitrate, 52_000_000);
      expect(VideoFpsMode.maxSupported.iosVideoBitrate, 56_000_000);
    });
  });

  group('CaptureSettings', () {
    test('defaults match AppConstants and high-speed fps', () {
      final d = CaptureSettings.defaults();
      expect(d.preRollSeconds, AppConstants.defaultPreRollSeconds);
      expect(d.postRollSeconds, AppConstants.defaultPostRollSeconds);
      expect(d.swingCooldownMs, AppConstants.defaultCooldownMs);
      expect(d.captureModelId, 'swing_tf_balance_20260423');
      expect(d.showDebugSkeleton, isTrue);
      expect(d.autoRecordOnReady, isTrue);
      expect(d.autoSaveToGallery, isTrue);
      expect(d.videoFpsMode, VideoFpsMode.high60);
      expect(d.autoSelectBestFps, isTrue);
      expect(d.dualCameraRole, DualCameraRole.disabled);
      expect(d.dualCameraTransportMode, DualCameraTransportMode.wifi);
      expect(d.autoRecordThreshold, 0.7);
      expect(d.activeModelVersion, 'hybrid_v1');
      expect(d.enableHybridLearning, isTrue);
    });

    test('fromMap fills defaults for missing keys', () {
      final parsed = CaptureSettings.fromMap(const {});
      final defaults = CaptureSettings.defaults();
      expect(parsed.preRollSeconds, defaults.preRollSeconds);
      expect(parsed.postRollSeconds, defaults.postRollSeconds);
      expect(parsed.swingCooldownMs, defaults.swingCooldownMs);
      expect(parsed.captureModelId, defaults.captureModelId);
      expect(parsed.showDebugSkeleton, defaults.showDebugSkeleton);
      expect(parsed.autoRecordOnReady, defaults.autoRecordOnReady);
      expect(parsed.autoSaveToGallery, defaults.autoSaveToGallery);
      expect(parsed.videoFpsMode, defaults.videoFpsMode);
      expect(parsed.autoSelectBestFps, defaults.autoSelectBestFps);
      expect(parsed.dualCameraRole, defaults.dualCameraRole);
      expect(parsed.autoRecordThreshold, defaults.autoRecordThreshold);
      expect(parsed.activeModelVersion, defaults.activeModelVersion);
      expect(parsed.enableHybridLearning, defaults.enableHybridLearning);
    });

    test(
      'fromMap/toMap round-trip preserves fields including videoFpsMode',
      () {
        final original = CaptureSettings.defaults().copyWith(
          preRollSeconds: 3.5,
          postRollSeconds: 1.25,
          swingCooldownMs: 900,
          captureModelId: 'custom_model',
          showDebugSkeleton: false,
          autoRecordOnReady: false,
          autoSaveToGallery: false,
          videoFpsMode: VideoFpsMode.maxSupported,
          autoSelectBestFps: false,
          dualCameraRole: DualCameraRole.detector,
          dualCameraTransportMode: DualCameraTransportMode.bluetoothControl,
          autoRecordThreshold: 0.82,
          activeModelVersion: 'hybrid_v2',
          enableHybridLearning: false,
        );
        final roundTrip = CaptureSettings.fromMap(original.toMap());
        expect(roundTrip.preRollSeconds, original.preRollSeconds);
        expect(roundTrip.postRollSeconds, original.postRollSeconds);
        expect(roundTrip.swingCooldownMs, original.swingCooldownMs);
        expect(roundTrip.captureModelId, original.captureModelId);
        expect(roundTrip.showDebugSkeleton, original.showDebugSkeleton);
        expect(roundTrip.autoRecordOnReady, original.autoRecordOnReady);
        expect(roundTrip.autoSaveToGallery, original.autoSaveToGallery);
        expect(roundTrip.videoFpsMode, original.videoFpsMode);
        expect(roundTrip.autoSelectBestFps, original.autoSelectBestFps);
        expect(roundTrip.dualCameraRole, original.dualCameraRole);
        expect(
          roundTrip.dualCameraTransportMode,
          original.dualCameraTransportMode,
        );
        expect(roundTrip.autoRecordThreshold, original.autoRecordThreshold);
        expect(roundTrip.activeModelVersion, original.activeModelVersion);
        expect(roundTrip.enableHybridLearning, original.enableHybridLearning);
      },
    );

    test('each VideoFpsMode round-trips through map storage', () {
      final base = CaptureSettings.defaults();
      for (final mode in VideoFpsMode.values) {
        final s = base.copyWith(videoFpsMode: mode);
        expect(CaptureSettings.fromMap(s.toMap()).videoFpsMode, mode);
        expect((s.toMap()['videoFpsMode'] as String), mode.wireValue);
      }
    });

    test('preRoll/postRoll ms match native buffering convention', () {
      final s = CaptureSettings.defaults().copyWith(
        preRollSeconds: 2.5,
        postRollSeconds: 1.125,
      );
      expect((s.preRollSeconds * 1000).round(), 2500);
      expect((s.postRollSeconds * 1000).round(), 1125);
    });

    test('recommendedVideoFpsModeForFps chooses fastest supported bucket', () {
      expect(recommendedVideoFpsModeForFps(29), VideoFpsMode.standard);
      expect(recommendedVideoFpsModeForFps(60), VideoFpsMode.high60);
      expect(recommendedVideoFpsModeForFps(119), VideoFpsMode.high60);
      expect(recommendedVideoFpsModeForFps(120), VideoFpsMode.high120);
      expect(recommendedVideoFpsModeForFps(239), VideoFpsMode.high120);
      expect(recommendedVideoFpsModeForFps(240), VideoFpsMode.high240);
    });

    test(
      'minimumHighSpeedVideoFpsMode keeps rolling buffer at 60fps or above',
      () {
        expect(
          minimumHighSpeedVideoFpsMode(VideoFpsMode.standard),
          VideoFpsMode.high60,
        );
        expect(
          minimumHighSpeedVideoFpsMode(VideoFpsMode.high60),
          VideoFpsMode.high60,
        );
        expect(
          minimumHighSpeedVideoFpsMode(VideoFpsMode.high120),
          VideoFpsMode.high120,
        );
        expect(
          minimumHighSpeedVideoFpsMode(VideoFpsMode.high240),
          VideoFpsMode.high240,
        );
        expect(
          minimumHighSpeedVideoFpsMode(VideoFpsMode.maxSupported),
          VideoFpsMode.maxSupported,
        );
      },
    );

    test('recommendedSharedVideoFpsMode uses the lowest phone capability', () {
      expect(sharedRecordingMaxFps(localMaxFps: 240, peerMaxFps: [120]), 120);
      expect(
        recommendedSharedVideoFpsMode(localMaxFps: 240, peerMaxFps: [120]),
        VideoFpsMode.high120,
      );
      expect(
        recommendedSharedVideoFpsMode(localMaxFps: 120, peerMaxFps: [240]),
        VideoFpsMode.high120,
      );
      expect(
        recommendedSharedVideoFpsMode(localMaxFps: 240, peerMaxFps: [59]),
        VideoFpsMode.standard,
      );
    });

    test('dual camera role wire values round-trip', () {
      for (final role in DualCameraRole.values) {
        expect(dualCameraRoleFromWire(role.wireValue), role);
      }
      expect(dualCameraRoleFromWire(null), DualCameraRole.disabled);
      expect(dualCameraRoleFromWire('unknown'), DualCameraRole.disabled);
    });

    test('dual camera transport wire values round-trip', () {
      for (final mode in DualCameraTransportMode.values) {
        expect(dualCameraTransportModeFromWire(mode.wireValue), mode);
      }
      expect(
        dualCameraTransportModeFromWire(null),
        DualCameraTransportMode.wifi,
      );
      expect(
        dualCameraTransportModeFromWire('unknown'),
        DualCameraTransportMode.wifi,
      );
    });
  });

  group('SharedPrefsSettingsRepository', () {
    test('persists dual camera role and bluetooth transport mode', () async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final repository = SharedPrefsSettingsRepository(prefs);
      final settings = CaptureSettings.defaults().copyWith(
        dualCameraRole: DualCameraRole.recorder,
        dualCameraTransportMode: DualCameraTransportMode.bluetoothControl,
        videoFpsMode: VideoFpsMode.high120,
      );

      await repository.saveSettings(settings);
      final loaded = await repository.loadSettings();

      expect(loaded.dualCameraRole, DualCameraRole.recorder);
      expect(
        loaded.dualCameraTransportMode,
        DualCameraTransportMode.bluetoothControl,
      );
      expect(loaded.videoFpsMode, VideoFpsMode.high120);
    });

    test('defaults missing dual camera transport to wifi', () async {
      SharedPreferences.setMockInitialValues({
        'dual_camera_role': DualCameraRole.detector.wireValue,
      });
      final prefs = await SharedPreferences.getInstance();
      final repository = SharedPrefsSettingsRepository(prefs);

      final loaded = await repository.loadSettings();

      expect(loaded.dualCameraRole, DualCameraRole.detector);
      expect(loaded.dualCameraTransportMode, DualCameraTransportMode.wifi);
    });

    test('defaults missing fps preference to 60fps buffer recording', () async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final repository = SharedPrefsSettingsRepository(prefs);

      final loaded = await repository.loadSettings();

      expect(loaded.videoFpsMode, VideoFpsMode.high60);
    });
  });
}
