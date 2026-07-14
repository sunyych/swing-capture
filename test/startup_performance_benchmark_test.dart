import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/features/performance/domain/startup_performance_benchmark.dart';

void main() {
  test('startup benchmark includes YOLO pose detection candidate timing', () {
    const benchmark = StartupPerformanceBenchmark();

    final result = benchmark.runPoseDetectionBenchmark();

    expect(result.framesProcessed, greaterThan(0));
    expect(result.candidatesDetected, greaterThan(result.framesProcessed));
    expect(result.selectedFrames, result.framesProcessed);
    expect(result.fps, greaterThan(0));
    expect(result.averageCandidatesPerFrame, greaterThan(1));
  });

  test('startup benchmark still includes single-pose processing timing', () {
    const benchmark = StartupPerformanceBenchmark();

    final result = benchmark.runPoseProcessingBenchmark();

    expect(result.framesProcessed, greaterThan(0));
    expect(result.averageCompleteness, greaterThan(0.6));
    expect(result.fps, greaterThan(0));
  });
}
