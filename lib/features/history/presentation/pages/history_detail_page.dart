import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../../app/providers.dart';
import '../../../../core/config/app_constants.dart';
import '../../../../core/models/capture_record.dart';
import '../../../../core/utils/formatters.dart';
import '../../domain/services/swing_tflite_inference_service.dart';

class HistoryDetailPage extends ConsumerStatefulWidget {
  const HistoryDetailPage({
    required this.record,
    this.records,
    this.initialIndex,
    super.key,
  });

  final CaptureRecord record;
  final List<CaptureRecord>? records;
  final int? initialIndex;

  @override
  ConsumerState<HistoryDetailPage> createState() => _HistoryDetailPageState();
}

class _HistoryDetailPageState extends ConsumerState<HistoryDetailPage> {
  late final List<CaptureRecord> _records;
  late int _currentIndex;
  VideoPlayerController? _videoController;
  int _videoLoadToken = 0;
  final SwingTfliteInferenceService _inferenceService =
      SwingTfliteInferenceService();
  SwingTfliteInferenceResult? _inferenceResult;
  bool _isInferring = false;
  String? _inferenceMessage;

  CaptureRecord get _currentRecord => _records[_currentIndex];
  bool get _hasPrevious => _currentIndex > 0;
  bool get _hasNext => _currentIndex < _records.length - 1;

  @override
  void initState() {
    super.initState();
    _records = (widget.records != null && widget.records!.isNotEmpty)
        ? List<CaptureRecord>.from(widget.records!)
        : <CaptureRecord>[widget.record];
    final indexedRecord = _records.indexWhere(
      (record) => record.id == widget.record.id,
    );
    final preferredIndex = widget.initialIndex;
    _currentIndex =
        preferredIndex != null &&
            preferredIndex >= 0 &&
            preferredIndex < _records.length
        ? preferredIndex
        : (indexedRecord >= 0 ? indexedRecord : 0);
    _initializeVideo();
  }

  @override
  void dispose() {
    _videoLoadToken++;
    final controller = _videoController;
    _videoController = null;
    unawaited(controller?.dispose());
    unawaited(_inferenceService.close());
    super.dispose();
  }

  Future<void> _initializeVideo({bool autoplay = false}) async {
    final activeToken = ++_videoLoadToken;
    final priorController = _videoController;
    _videoController = null;
    if (mounted) {
      setState(() {});
    }
    await priorController?.dispose();

    final file = File(_currentRecord.videoPath);
    if (!await file.exists()) {
      if (mounted && activeToken == _videoLoadToken) {
        setState(() {});
      }
      return;
    }

    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
      await controller.setLooping(true);
      if (autoplay) {
        await controller.play();
      }
    } catch (_) {
      await controller.dispose();
      if (mounted && activeToken == _videoLoadToken) {
        setState(() {});
      }
      return;
    }
    if (!mounted || activeToken != _videoLoadToken) {
      await controller.dispose();
      return;
    }
    setState(() => _videoController = controller);
  }

  Future<void> _showRecordAt(int nextIndex) async {
    if (nextIndex < 0 ||
        nextIndex >= _records.length ||
        nextIndex == _currentIndex) {
      return;
    }
    final shouldContinuePlayback = _videoController?.value.isPlaying ?? false;
    setState(() => _currentIndex = nextIndex);
    await _initializeVideo(autoplay: shouldContinuePlayback);
  }

  Future<void> _handleHorizontalSwipe(DragEndDetails details) async {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 250) {
      return;
    }
    if (velocity < 0) {
      await _showRecordAt(_currentIndex + 1);
      return;
    }
    await _showRecordAt(_currentIndex - 1);
  }

  Future<void> _deleteCapture() async {
    final removedRecord = _currentRecord;
    await ref.read(historyControllerProvider.notifier).deleteRecords([
      removedRecord,
    ]);
    if (!mounted) {
      return;
    }
    if (_records.length > 1) {
      final shouldContinuePlayback = _videoController?.value.isPlaying ?? false;
      setState(() {
        _records.removeAt(_currentIndex);
        if (_currentIndex >= _records.length) {
          _currentIndex = _records.length - 1;
        }
      });
      await _initializeVideo(autoplay: shouldContinuePlayback);
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _exportToGallery() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export to Photos'),
        content: Text(
          'Save this clip to the ${AppConstants.swingCaptureAlbum} album?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Export'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final result = await ref
        .read(historyControllerProvider.notifier)
        .exportRecordsToGallery([_currentRecord]);
    if (!mounted) {
      return;
    }
    final saved = result.$1;
    final skipped = result.$2;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          skipped == 0 && saved > 0
              ? 'Saved to Photos.'
              : saved == 0
              ? 'Could not save to Photos.'
              : 'Saved $saved; could not save $skipped.',
        ),
      ),
    );
  }

  Future<void> _runOnDeviceInference() async {
    final poseJsonPath = _currentRecord.poseJsonPath;
    if (poseJsonPath == null || poseJsonPath.isEmpty) {
      setState(() {
        _inferenceMessage = 'No pose JSON available for this clip.';
      });
      return;
    }
    final poseFile = File(poseJsonPath);
    if (!await poseFile.exists()) {
      setState(() {
        _inferenceMessage = 'Pose JSON file not found: $poseJsonPath';
      });
      return;
    }

    setState(() {
      _isInferring = true;
      _inferenceMessage = null;
    });
    try {
      final result = await _inferenceService.classifyPoseJson(poseJsonPath);
      if (!mounted) {
        return;
      }
      setState(() {
        _inferenceResult = result;
        _inferenceMessage = 'On-device inference completed.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _inferenceMessage = 'Inference failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isInferring = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;
    final currentRecord = _currentRecord;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _records.length > 1
              ? 'Capture ${_currentIndex + 1} / ${_records.length}'
              : 'Capture Detail',
        ),
        actions: [
          IconButton(
            onPressed: _exportToGallery,
            icon: const Icon(Icons.save_alt_outlined),
            tooltip: 'Export to Photos',
          ),
          IconButton(
            onPressed: _deleteCapture,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: _handleHorizontalSwipe,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: AspectRatio(
                aspectRatio: controller?.value.aspectRatio ?? (16 / 9),
                child: ColoredBox(
                  color: Colors.black,
                  child: controller != null && controller.value.isInitialized
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            VideoPlayer(controller),
                            Center(
                              child: IconButton.filled(
                                onPressed: () {
                                  if (controller.value.isPlaying) {
                                    controller.pause();
                                  } else {
                                    controller.play();
                                  }
                                  setState(() {});
                                },
                                icon: Icon(
                                  controller.value.isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                              ),
                            ),
                            if (_hasPrevious)
                              Positioned(
                                left: 12,
                                top: 0,
                                bottom: 0,
                                child: _VideoNavButton(
                                  icon: Icons.chevron_left_rounded,
                                  tooltip: 'Previous video',
                                  onPressed: () => unawaited(
                                    _showRecordAt(_currentIndex - 1),
                                  ),
                                ),
                              ),
                            if (_hasNext)
                              Positioned(
                                right: 12,
                                top: 0,
                                bottom: 0,
                                child: _VideoNavButton(
                                  icon: Icons.chevron_right_rounded,
                                  tooltip: 'Next video',
                                  onPressed: () => unawaited(
                                    _showRecordAt(_currentIndex + 1),
                                  ),
                                ),
                              ),
                          ],
                        )
                      : const Center(child: Text('Video unavailable')),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_records.length > 1)
              Text(
                'Swipe left or right to browse adjacent clips.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Formatters.historyDateFormat.format(
                        currentRecord.createdAt,
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Duration: ${Formatters.formatDurationMs(currentRecord.durationMs)}',
                    ),
                    Text('Album: ${currentRecord.albumName}'),
                    Text(
                      'Location: ${currentRecord.locationLabel ?? 'Unavailable'}',
                    ),
                    Text('Video: ${currentRecord.videoPath}'),
                    if (currentRecord.poseJsonPath != null &&
                        currentRecord.poseJsonPath!.isNotEmpty)
                      Text('Pose JSON: ${currentRecord.poseJsonPath}'),
                    if (currentRecord.thumbnailPath.isNotEmpty)
                      Text('Thumbnail: ${currentRecord.thumbnailPath}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'On-device Swing Classifier (TFLite)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: _isInferring ? null : _runOnDeviceInference,
                      icon: _isInferring
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_graph),
                      label: Text(
                        _isInferring ? 'Running...' : 'Run On-device Inference',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Model path on device: <app-documents>/models/swing_classifier.tflite',
                    ),
                    if (_inferenceResult != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Predicted label: ${_inferenceResult!.label} '
                        '(${(_inferenceResult!.confidence * 100).toStringAsFixed(1)}%)',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      for (final entry
                          in _inferenceResult!.classProbabilities.entries)
                        Text(
                          '${entry.key}: ${(entry.value * 100).toStringAsFixed(1)}%',
                        ),
                    ],
                    if (_inferenceMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(_inferenceMessage!),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoNavButton extends StatelessWidget {
  const _VideoNavButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IconButton.filledTonal(
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.35),
          foregroundColor: Colors.white70,
        ),
        icon: Icon(icon, size: 28),
      ),
    );
  }
}
