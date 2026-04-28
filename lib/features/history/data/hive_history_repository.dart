import 'package:hive/hive.dart';

import '../../../core/models/capture_record.dart';
import 'history_repository.dart';

class HiveHistoryRepository implements HistoryRepository {
  const HiveHistoryRepository(this._box);

  final Box<Map> _box;

  @override
  Future<void> deleteRecord(String id) async {
    await _box.delete(id);
  }

  @override
  Future<List<CaptureRecord>> listRecords() async {
    final values =
        _box.values.map((entry) => CaptureRecord.fromMap(entry)).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final deduped = <CaptureRecord>[];
    final seenVideoPaths = <String>{};
    for (final record in values) {
      if (seenVideoPaths.add(record.videoPath)) {
        deduped.add(record);
      }
    }
    return deduped;
  }

  @override
  Future<void> saveRecord(CaptureRecord record) async {
    await _box.put(record.id, record.toMap());
  }
}
