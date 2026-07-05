import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../app/providers.dart';
import '../../../../core/models/capture_record.dart';
import '../../../../platform_channels/capture_platform_channel.dart';
import '../../data/video_pose_import_service.dart';
import '../../../history/domain/services/swing_tflite_inference_service.dart';
import '../../../history/presentation/controllers/history_controller.dart';
import '../../../history/presentation/pages/history_detail_page.dart';

class VideoStudioPage extends ConsumerStatefulWidget {
  const VideoStudioPage({super.key});

  @override
  ConsumerState<VideoStudioPage> createState() => _VideoStudioPageState();
}

class _VideoStudioPageState extends ConsumerState<VideoStudioPage> {
  final SwingTfliteInferenceService _inferenceService =
      SwingTfliteInferenceService();
  final VideoPoseImportService _importService = const VideoPoseImportService();
  String? _selectedRecordId;
  bool _busy = false;
  String? _busyMessage;
  double? _importProgress;

  @override
  void dispose() {
    unawaited(_inferenceService.close());
    super.dispose();
  }

  CaptureRecord? _resolveSelected(List<CaptureRecordViewModel> items) {
    if (items.isEmpty) {
      return null;
    }
    final selected = items
        .map((item) => item.record)
        .where((record) => record.id == _selectedRecordId)
        .toList();
    if (selected.isNotEmpty) {
      return selected.first;
    }
    return items.first.record;
  }

  Future<void> _applyTag(CaptureRecord record, String tag) async {
    setState(() {
      _busy = true;
      _busyMessage = 'Updating label...';
    });
    try {
      await ref
          .read(historyControllerProvider.notifier)
          .updateRecordTagging(
            record: record,
            userTag: tag,
            reviewState: tag == 'action'
                ? CaptureReviewState.accepted
                : CaptureReviewState.rejected,
            datasetState: CaptureDatasetState.labeled,
            trainingState: TrainingLifecycleState.queued,
          );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Tagged as "$tag".')));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
          _importProgress = null;
        });
      }
    }
  }

  Future<void> _importPhoneVideo() async {
    final shouldContinue = await _showPowerReminder();
    if (!shouldContinue || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _busyMessage = 'Waiting for video selection...';
      _importProgress = null;
    });
    try {
      final result = await _importService.importFromLibrary(
        repository: ref.read(historyRepositoryProvider),
        inferenceService: _inferenceService,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _importProgress = progress.progress;
            _busyMessage = progress.message ?? _formatImportProgress(progress);
          });
        },
      );
      if (!mounted) {
        return;
      }
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video import cancelled.')),
        );
        return;
      }
      await ref
          .read(historyControllerProvider.notifier)
          .recordSaved(result.record);
      await ref.read(historyControllerProvider.notifier).refresh();
      if (!mounted) {
        return;
      }
      setState(() => _selectedRecordId = result.record.id);
      final model = result.modelResult;
      final modelText = model == null
          ? ''
          : ' • ${model.label} ${(model.confidence * 100).toStringAsFixed(1)}%';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${result.poseFrameCount}/${result.totalFrameCount} pose frames$modelText.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
          _importProgress = null;
        });
      }
    }
  }

  Future<bool> _showPowerReminder() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Plug in for long videos'),
        content: const Text(
          'Pose extraction can use a lot of battery. Connecting power is recommended before processing, but you can continue now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  String _formatImportProgress(NativeVideoImportProgressEvent progress) {
    final percent = (progress.progress * 100).clamp(0, 100).toStringAsFixed(0);
    final total = progress.totalFrames;
    if (total != null && total > 0) {
      return 'Extracting pose JSON... $percent% (${progress.processedFrames}/$total frames)';
    }
    return 'Extracting pose JSON... $percent%';
  }

  Future<void> _scanWithModel(CaptureRecord record) async {
    final poseJsonPath = record.poseJsonPath;
    if (poseJsonPath == null || poseJsonPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This video has no pose JSON to scan.')),
      );
      return;
    }
    if (!await File(poseJsonPath).exists()) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pose JSON not found: $poseJsonPath')),
      );
      return;
    }

    setState(() {
      _busy = true;
      _busyMessage = 'Scanning pose JSON with the current model...';
    });
    try {
      final result = await _inferenceService.classifyPoseJson(poseJsonPath);
      await ref
          .read(historyControllerProvider.notifier)
          .updateRecordTagging(
            record: record,
            modelLabel: result.label,
            modelConfidence: result.confidence,
            trainingState: TrainingLifecycleState.queued,
          );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Scan complete: ${result.label} (${(result.confidence * 100).toStringAsFixed(1)}%)',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Scan failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
          _importProgress = null;
        });
      }
    }
  }

  Future<void> _exportTranscript(
    CaptureRecord selected,
    List<CaptureRecord> all,
  ) async {
    setState(() {
      _busy = true;
      _busyMessage = 'Exporting transcript...';
    });
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final exportDir = Directory('${appDir.path}/exports');
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      final target = File('${exportDir.path}/motioncapture_transcript_$ts.txt');
      final buffer = StringBuffer()
        ..writeln('MotionCapture Video Transcript')
        ..writeln('generatedAt=${DateTime.now().toIso8601String()}')
        ..writeln('selectedId=${selected.id}')
        ..writeln('');
      for (final record in all) {
        buffer
          ..writeln('---')
          ..writeln('id=${record.id}')
          ..writeln('createdAt=${record.createdAt.toIso8601String()}')
          ..writeln('durationMs=${record.durationMs}')
          ..writeln('videoPath=${record.videoPath}')
          ..writeln('poseJsonPath=${record.poseJsonPath ?? ''}')
          ..writeln('tag=${record.userTag ?? ''}')
          ..writeln('review=${record.reviewState.name}')
          ..writeln('dataset=${record.datasetState.name}')
          ..writeln('modelLabel=${record.modelLabel ?? ''}')
          ..writeln(
            'modelConfidence=${record.modelConfidence?.toStringAsFixed(4) ?? ''}',
          );
      }
      await target.writeAsString(buffer.toString());
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transcript exported: ${target.path}')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
          _importProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncHistory = ref.watch(historyControllerProvider);

    return SafeArea(
      child: asyncHistory.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Failed: $error')),
        data: (items) {
          final records = items.map((item) => item.record).toList();
          final selected = _resolveSelected(items);
          if (selected != null && _selectedRecordId != selected.id) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() => _selectedRecordId = selected.id);
              }
            });
          }

          return Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                Text(
                  'Video Studio',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Use existing videos for end-to-end workflows: tagging, scanning, and transcript export.',
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
                          'Phone video pose import',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_busyMessage != null) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: _importProgress,
                            minHeight: 3,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          const SizedBox(height: 8),
                          Text(_busyMessage!),
                        ],
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _busy ? null : _importPhoneVideo,
                          icon: const Icon(Icons.video_file_outlined),
                          label: const Text('Import Phone Video'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (selected == null)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No dataset videos yet. Import a phone video or record clips in Capture first.',
                      ),
                    ),
                  )
                else ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Select existing video',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: selected.id,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'Dataset video',
                            ),
                            items: records
                                .map(
                                  (record) => DropdownMenuItem<String>(
                                    value: record.id,
                                    child: Text(
                                      '${record.createdAt.toLocal()} • ${record.userTag ?? 'untagged'}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: _busy
                                ? null
                                : (value) {
                                    if (value == null) {
                                      return;
                                    }
                                    setState(() => _selectedRecordId = value);
                                  },
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => _applyTag(selected, 'action'),
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text('Tag: Action'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => _applyTag(selected, 'not_action'),
                                icon: const Icon(Icons.cancel_outlined),
                                label: const Text('Tag: Not Action'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => _scanWithModel(selected),
                                icon: const Icon(Icons.auto_graph),
                                label: const Text('Scan Pose JSON'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () =>
                                          _exportTranscript(selected, records),
                                icon: const Icon(Icons.text_snippet_outlined),
                                label: const Text('Export Transcript'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => HistoryDetailPage(
                                            record: selected,
                                            records: records,
                                            initialIndex: records.indexWhere(
                                              (r) => r.id == selected.id,
                                            ),
                                          ),
                                        ),
                                      ),
                                icon: const Icon(Icons.open_in_new),
                                label: const Text('Open Detail'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
