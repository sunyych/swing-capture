import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/action_event.dart';

void main() {
  group('ActionEvent window helpers', () {
    test('resolvedWindowStartAt/EndAt use pre/post when overrides absent', () {
      final t = DateTime.utc(2026, 5, 1, 12, 0, 0);
      final event = ActionEvent(
        label: 'swing',
        triggeredAt: t,
        score: 1,
        preRollMs: 2000,
        postRollMs: 1500,
        reason: 'test',
      );
      expect(
        event.resolvedWindowStartAt,
        t.subtract(const Duration(milliseconds: 2000)),
      );
      expect(
        event.resolvedWindowEndAt,
        t.add(const Duration(milliseconds: 1500)),
      );
    });

    test('resolvedWindowStartAt/EndAt prefer explicit window bounds', () {
      final t = DateTime.utc(2026, 5, 1, 12, 0, 0);
      final start = DateTime.utc(2026, 5, 1, 11, 59, 50);
      final end = DateTime.utc(2026, 5, 1, 12, 0, 5);
      final event = ActionEvent(
        label: 'swing',
        triggeredAt: t,
        score: 1,
        preRollMs: 9999,
        postRollMs: 9999,
        reason: 'test',
        windowStartAt: start,
        windowEndAt: end,
      );
      expect(event.resolvedWindowStartAt, start);
      expect(event.resolvedWindowEndAt, end);
    });
  });
}
