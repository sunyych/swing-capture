import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/rolling_buffer_clip.dart';

void main() {
  group('rollingClipBoundsMs', () {
    test('centers window on trigger within buffer', () {
      final bounds = rollingClipBoundsMs(
        totalDurationMs: 10_000,
        triggerMs: 5000,
        preRollMs: 2000,
        postRollMs: 2000,
      );
      expect(bounds.clipStartMs, 3000);
      expect(bounds.clipEndMs, 7000);
    });

    test('clamps start to zero when pre-roll exceeds trigger', () {
      final bounds = rollingClipBoundsMs(
        totalDurationMs: 5000,
        triggerMs: 500,
        preRollMs: 2000,
        postRollMs: 1000,
      );
      expect(bounds.clipStartMs, 0);
      expect(bounds.clipEndMs, 1500);
    });

    test('clamps end to totalDurationMs when post-roll exceeds tail', () {
      final bounds = rollingClipBoundsMs(
        totalDurationMs: 8000,
        triggerMs: 7500,
        preRollMs: 1000,
        postRollMs: 4000,
      );
      expect(bounds.clipStartMs, 6500);
      expect(bounds.clipEndMs, 8000);
    });
  });

  group('rollingClipDurationMs', () {
    test('matches span of clamped bounds', () {
      expect(
        rollingClipDurationMs(
          totalDurationMs: 10_000,
          triggerMs: 5000,
          preRollMs: 2000,
          postRollMs: 2000,
        ),
        4000,
      );
    });

    test('returns zero when clamp collapses start and end to the same instant', () {
      expect(
        rollingClipDurationMs(
          totalDurationMs: 1000,
          triggerMs: 1000,
          preRollMs: 0,
          postRollMs: 1000,
        ),
        0,
      );
    });
  });
}
