/// Generic motion event emitted by an action detector or native buffering pipeline.
class ActionEvent {
  const ActionEvent({
    required this.label,
    required this.triggeredAt,
    required this.score,
    required this.preRollMs,
    required this.postRollMs,
    this.category,
    this.reason,
    this.windowStartAt,
    this.windowEndAt,
  });

  final String label;
  final DateTime triggeredAt;
  final double score;
  final int preRollMs;
  final int postRollMs;
  final String? category;
  final String? reason;
  final DateTime? windowStartAt;
  final DateTime? windowEndAt;

  DateTime get resolvedWindowStartAt =>
      windowStartAt ?? triggeredAt.subtract(Duration(milliseconds: preRollMs));

  DateTime get resolvedWindowEndAt =>
      windowEndAt ?? triggeredAt.add(Duration(milliseconds: postRollMs));
}
