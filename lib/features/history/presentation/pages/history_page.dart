import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';
import '../../../../core/config/app_constants.dart';
import '../../../../core/models/capture_record.dart';
import '../../../../core/utils/formatters.dart';
import '../controllers/history_controller.dart';
import 'history_detail_page.dart';

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _enterSelectionMode({String? initialId}) {
    setState(() {
      _selectionMode = true;
      _selectedIds.clear();
      if (initialId != null) {
        _selectedIds.add(initialId);
      }
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _selectAll(Iterable<CaptureRecordViewModel> items) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(items.map((e) => e.record.id));
    });
  }

  void _clearSelection() {
    setState(_selectedIds.clear);
  }

  Future<void> _confirmDeleteSelected(
    List<CaptureRecordViewModel> items,
  ) async {
    final selectedRecords = items
        .where((e) => _selectedIds.contains(e.record.id))
        .map((e) => e.record)
        .toList();
    if (selectedRecords.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete clips'),
        content: Text(
          'Permanently delete ${selectedRecords.length} clip'
          '${selectedRecords.length == 1 ? '' : 's'} from this device? '
          'Video files and thumbnails will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    await ref
        .read(historyControllerProvider.notifier)
        .deleteRecords(selectedRecords);
    if (!mounted) {
      return;
    }
    _exitSelectionMode();
  }

  Future<void> _exportClips(List<CaptureRecordViewModel> items) async {
    late final List<CaptureRecord> targets;
    if (_selectionMode && _selectedIds.isNotEmpty) {
      targets = items
          .where((e) => _selectedIds.contains(e.record.id))
          .map((e) => e.record)
          .toList();
    } else if (_selectionMode) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Select clips to export, or cancel selection to export all.',
          ),
        ),
      );
      return;
    } else {
      targets = items.map((e) => e.record).toList();
    }

    final count = targets.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export to Photos'),
        content: Text(
          'Save $count clip${count == 1 ? '' : 's'} to the '
          '${AppConstants.swingCaptureAlbum} album?',
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
        .exportRecordsToGallery(targets);
    if (!mounted) {
      return;
    }
    final saved = result.$1;
    final skipped = result.$2;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          skipped == 0
              ? 'Saved $saved clip${saved == 1 ? '' : 's'} to Photos.'
              : 'Saved $saved clip${saved == 1 ? '' : 's'}; '
                    'could not save $skipped.',
        ),
      ),
    );
  }

  void _onTileTap(
    CaptureRecordViewModel item,
    List<CaptureRecordViewModel> items,
  ) {
    if (_selectionMode) {
      _toggleSelected(item.record.id);
      return;
    }
    final records = items.map((entry) => entry.record).toList(growable: false);
    final initialIndex = records.indexWhere(
      (record) => record.id == item.record.id,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HistoryDetailPage(
          record: item.record,
          records: records,
          initialIndex: initialIndex >= 0 ? initialIndex : 0,
        ),
      ),
    );
  }

  void _onTileLongPress(CaptureRecordViewModel item) {
    if (_selectionMode) {
      _toggleSelected(item.record.id);
    } else {
      _enterSelectionMode(initialId: item.record.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(appTabProvider, (previous, next) {
      if (next == 1) {
        unawaited(ref.read(historyControllerProvider.notifier).refresh());
      }
    });

    final asyncHistory = ref.watch(historyControllerProvider);
    final hasItems = asyncHistory.valueOrNull?.isNotEmpty ?? false;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'History',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                if (hasItems)
                  TextButton.icon(
                    onPressed: () {
                      final data = asyncHistory.valueOrNull;
                      if (data != null) {
                        unawaited(_exportClips(data));
                      }
                    },
                    icon: const Icon(Icons.save_alt_outlined),
                    label: const Text('Export'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _selectionMode
                  ? 'Tap a clip to toggle selection. Use Export or Delete when ready.'
                  : 'Clips you record are saved here. Long-press a tile to select, or tap Select. Export saves copies to your photo library.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            _SelectionToolbar(
              selectionMode: _selectionMode,
              canEnterSelectionMode: hasItems,
              selectedCount: _selectedIds.length,
              onEnterSelect: () => _enterSelectionMode(),
              onExitSelect: _exitSelectionMode,
              onSelectAll: () {
                final data = asyncHistory.valueOrNull;
                if (data != null) {
                  _selectAll(data);
                }
              },
              onClearSelection: _clearSelection,
              onExport: () {
                final data = asyncHistory.valueOrNull;
                if (data != null) {
                  unawaited(_exportClips(data));
                }
              },
              onDelete: () {
                final data = asyncHistory.valueOrNull;
                if (data != null) {
                  unawaited(_confirmDeleteSelected(data));
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: asyncHistory.when(
                data: (items) {
                  if (items.isEmpty) {
                    if (_selectionMode) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _exitSelectionMode();
                        }
                      });
                    }
                    return const _EmptyHistory();
                  }

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount = constraints.maxWidth >= 520
                          ? 3
                          : 2;
                      return GridView.builder(
                        padding: EdgeInsets.zero,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.78,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final selected = _selectedIds.contains(
                            item.record.id,
                          );
                          return _HistoryGalleryTile(
                            item: item,
                            selectionMode: _selectionMode,
                            selected: selected,
                            onTap: () => _onTileTap(item, items),
                            onLongPress: () => _onTileLongPress(item),
                          );
                        },
                      );
                    },
                  );
                },
                error: (error, _) => Center(child: Text('Failed: $error')),
                loading: () => const Center(child: CircularProgressIndicator()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.selectionMode,
    required this.canEnterSelectionMode,
    required this.selectedCount,
    required this.onEnterSelect,
    required this.onExitSelect,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onExport,
    required this.onDelete,
  });

  final bool selectionMode;
  final bool canEnterSelectionMode;
  final int selectedCount;
  final VoidCallback onEnterSelect;
  final VoidCallback onExitSelect;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    if (!selectionMode) {
      if (!canEnterSelectionMode) {
        return const SizedBox.shrink();
      }
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: onEnterSelect,
          icon: const Icon(Icons.checklist_rounded, size: 20),
          label: const Text('Select'),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(onPressed: onExitSelect, child: const Text('Cancel')),
        TextButton(onPressed: onSelectAll, child: const Text('Select all')),
        TextButton(
          onPressed: selectedCount == 0 ? null : onClearSelection,
          child: const Text('Clear'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            selectedCount == 0 ? 'None selected' : '$selectedCount selected',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: onExport,
          icon: const Icon(Icons.save_alt_outlined),
          label: const Text('Export'),
        ),
        FilledButton.tonalIcon(
          onPressed: selectedCount == 0 ? null : onDelete,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Delete'),
        ),
      ],
    );
  }
}

class _HistoryGalleryTile extends StatelessWidget {
  const _HistoryGalleryTile({
    required this.item,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final CaptureRecordViewModel item;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel = Formatters.historyDateFormat.format(
      item.record.createdAt,
    );
    final durationLabel = Formatters.formatDurationMs(item.record.durationMs);

    return Material(
      color: const Color(0xFF132833),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: selected ? 2.5 : 0,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (item.record.thumbnailPath.isNotEmpty)
                Image.file(
                  File(item.record.thumbnailPath),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
                )
              else
                const _ThumbPlaceholder(),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.05),
                        Colors.black.withValues(alpha: 0.72),
                      ],
                    ),
                  ),
                ),
              ),
              if (selectionMode)
                Positioned(
                  top: 8,
                  left: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? theme.colorScheme.primary
                            : Colors.white54,
                        width: 2,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: selected
                          ? const Icon(
                              Icons.check,
                              size: 20,
                              color: Colors.white,
                            )
                          : const SizedBox(width: 20, height: 20),
                    ),
                  ),
                ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      dateLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        shadows: const [
                          Shadow(blurRadius: 8, color: Colors.black54),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 14,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          durationLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              if (!selectionMode)
                Positioned(
                  top: 8,
                  right: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0E1A22),
      child: Center(
        child: Icon(
          Icons.videocam_outlined,
          size: 40,
          color: Colors.white.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10),
        ),
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.video_library_outlined,
                size: 42,
                color: Colors.white54,
              ),
              SizedBox(height: 12),
              Text('No captured swings yet'),
              SizedBox(height: 8),
              Text(
                'Record a clip from Capture — it will show up here as a tile.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
