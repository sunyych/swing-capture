/// Rolling-buffer clip bounds within `[0, totalDurationMs]` relative to buffer start.
///
/// Keeps duration estimates and resolved export windows aligned with the same
/// clamping rules.
({int clipStartMs, int clipEndMs}) rollingClipBoundsMs({
  required int totalDurationMs,
  required int triggerMs,
  required int preRollMs,
  required int postRollMs,
}) {
  final clipStartMs = (triggerMs - preRollMs).clamp(0, totalDurationMs);
  final clipEndMs = (triggerMs + postRollMs).clamp(0, totalDurationMs);
  return (clipStartMs: clipStartMs, clipEndMs: clipEndMs);
}

/// Length of the intersection of the requested pre/post window with the buffer.
int rollingClipDurationMs({
  required int totalDurationMs,
  required int triggerMs,
  required int preRollMs,
  required int postRollMs,
}) {
  final bounds = rollingClipBoundsMs(
    totalDurationMs: totalDurationMs,
    triggerMs: triggerMs,
    preRollMs: preRollMs,
    postRollMs: postRollMs,
  );
  return (bounds.clipEndMs - bounds.clipStartMs).clamp(0, totalDurationMs);
}
