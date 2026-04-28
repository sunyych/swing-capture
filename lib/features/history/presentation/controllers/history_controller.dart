import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../../../app/providers.dart';
import '../../../../core/config/app_constants.dart';
import '../../../../core/models/capture_record.dart';
import '../../data/history_media_cleanup.dart';

class CaptureRecordViewModel {
  const CaptureRecordViewModel({required this.record, required this.subtitle});

  final CaptureRecord record;
  final String subtitle;
}

class HistoryController extends AsyncNotifier<List<CaptureRecordViewModel>> {
  @override
  Future<List<CaptureRecordViewModel>> build() async {
    ref.watch(historyRepositoryProvider);
    return _loadViewModels();
  }

  CaptureRecordViewModel _toViewModel(CaptureRecord record) {
    return CaptureRecordViewModel(
      record: record,
      subtitle: record.locationLabel ?? 'Location unavailable',
    );
  }

  Future<List<CaptureRecordViewModel>> _loadViewModels() async {
    final repository = ref.read(historyRepositoryProvider);
    final records = await repository.listRecords();
    return records.map(_toViewModel).toList();
  }

  Future<void> refresh({bool preserveVisibleItems = true}) async {
    final previous = state.valueOrNull;
    if (preserveVisibleItems && previous != null) {
      state = AsyncValue.data(previous);
    } else {
      state = const AsyncValue.loading();
    }
    state = AsyncValue.data(await _loadViewModels());
  }

  Future<void> recordSaved(CaptureRecord record) async {
    final current = state.valueOrNull;
    if (current == null) {
      await refresh(preserveVisibleItems: false);
      return;
    }

    final updated = [
      _toViewModel(record),
      ...current.where((item) => item.record.id != record.id),
    ]..sort((a, b) => b.record.createdAt.compareTo(a.record.createdAt));
    state = AsyncValue.data(updated);
  }

  /// Deletes persisted rows and local video/thumbnail files, then refreshes list state.
  Future<void> deleteRecords(List<CaptureRecord> records) async {
    if (records.isEmpty) {
      return;
    }
    final repository = ref.read(historyRepositoryProvider);
    for (final record in records) {
      await repository.deleteRecord(record.id);
      await deleteCaptureFiles(record);
    }
    await refresh();
  }

  /// Copies clip files into the device photo library ([AppConstants.swingCaptureAlbum]).
  /// Returns `(saved, skipped)` where `skipped` counts missing files or failed puts.
  Future<(int saved, int skipped)> exportRecordsToGallery(
    List<CaptureRecord> records,
  ) async {
    if (records.isEmpty) {
      return (0, 0);
    }

    try {
      final hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          return (0, records.length);
        }
      }
    } catch (_) {
      return (0, records.length);
    }

    var saved = 0;
    var skipped = 0;
    for (final record in records) {
      final file = File(record.videoPath);
      if (!await file.exists()) {
        skipped++;
        continue;
      }
      try {
        await Gal.putVideo(
          record.videoPath,
          album: AppConstants.swingCaptureAlbum,
        );
        saved++;
      } catch (_) {
        skipped++;
      }
    }
    return (saved, skipped);
  }
}
