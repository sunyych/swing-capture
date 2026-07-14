import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/utils/formatters.dart';

void main() {
  test('formatFileTimestamp uses readable date and time with microseconds', () {
    final timestamp = DateTime(2026, 7, 6, 15, 4, 5, 123, 456);

    expect(Formatters.formatFileTimestamp(timestamp), '20260706_150405_123456');
  });
}
