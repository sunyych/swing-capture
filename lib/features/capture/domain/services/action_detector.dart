import '../../../../core/models/action_event.dart';
import '../models/pose_frame.dart';

/// Generic interface for detecting actions from a live pose stream.
abstract class ActionDetector {
  ActionEvent? process(PoseFrame frame);
  void reset();
}
