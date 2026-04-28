import '../../../core/models/capture_record.dart';

abstract class HistoryRepository {
  Future<List<CaptureRecord>> listRecords();
  Future<void> saveRecord(CaptureRecord record);
  Future<void> deleteRecord(String id);
}
