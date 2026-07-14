import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/platform_channels/capture_platform_channel.dart';

void main() {
  test('parses picked video metadata from native map', () {
    final picked = NativeVideoPickResult.fromMap({
      'videoPath': '/tmp/imported.mp4',
      'durationMs': 1234,
      'displayName': 'imported.mp4',
    });

    expect(picked.videoPath, '/tmp/imported.mp4');
    expect(picked.durationMs, 1234);
    expect(picked.displayName, 'imported.mp4');
  });

  test('parses video track metadata from native map', () {
    final metadata = NativeVideoMetadataResult.fromMap({
      'durationMs': 1800,
      'frameRate': 59.94,
    });

    expect(metadata.durationMs, 1800);
    expect(metadata.frameRate, 59.94);
  });

  test('parses extracted pose frames from native map', () {
    final extraction = NativeVideoPoseExtractionResult.fromMap({
      'durationMs': 2000,
      'frameCount': 2,
      'poseFrameCount': 1,
      'frames': [
        {
          'offsetMs': 0,
          'landmarks': [
            {'name': 'leftWrist', 'x': 0.25, 'y': 0.5, 'confidence': 0.9},
          ],
        },
        {'offsetMs': 83, 'landmarks': []},
      ],
    });

    expect(extraction.durationMs, 2000);
    expect(extraction.frameCount, 2);
    expect(extraction.poseFrameCount, 1);
    expect(extraction.frames.first.offsetMs, 0);
    expect(extraction.frames.first.points.single.name, 'leftWrist');
    expect(extraction.frames.first.points.single.confidence, 0.9);
    expect(extraction.frames.last.points, isEmpty);
  });
}
