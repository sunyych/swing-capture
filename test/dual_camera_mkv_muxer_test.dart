import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/features/capture/domain/services/dual_camera_mkv_muxer.dart';

void main() {
  test('writes a two-track Matroska file from paired MP4 clips', () async {
    final directory = await Directory.systemTemp.createTemp(
      'dual_camera_mkv_muxer_test_',
    );
    final detectorPath = '${directory.path}/detector.mp4';
    final recorderPath = '${directory.path}/recorder.mp4';
    final outputPath = '${directory.path}/dual.mkv';

    await File(
      detectorPath,
    ).writeAsBytes(_minimalAvcMp4(width: 640, height: 480));
    await File(
      recorderPath,
    ).writeAsBytes(_minimalAvcMp4(width: 1280, height: 720));

    final result = await const DualCameraMkvMuxer().mux(
      detectorVideoPath: detectorPath,
      recorderVideoPath: recorderPath,
      outputPath: outputPath,
      detectorTrackName: 'Detector',
      recorderTrackName: 'Recorder',
    );

    final output = await File(result.outputPath).readAsBytes();
    expect(result.durationMs, greaterThan(0));
    expect(output.take(4), [0x1a, 0x45, 0xdf, 0xa3]);
    expect(_containsAscii(output, 'matroska'), isTrue);
    expect(_containsAscii(output, 'Detector'), isTrue);
    expect(_containsAscii(output, 'Recorder'), isTrue);
    expect(_countAscii(output, 'V_MPEG4/ISO/AVC'), 2);
  });
}

List<int> _minimalAvcMp4({required int width, required int height}) {
  final sample1 = <int>[0, 0, 0, 1, 0x65];
  final sample2 = <int>[0, 0, 0, 1, 0x41];
  final ftyp = _box('ftyp', [
    ...ascii.encode('isom'),
    ..._u32(0x200),
    ...ascii.encode('isomiso2avc1mp41'),
  ]);
  final mdatPayload = [...sample1, ...sample2];
  final mdat = _box('mdat', mdatPayload);
  final firstSampleOffset = ftyp.length + 8;

  final avcC = _box('avcC', [1, 0x42, 0, 0x1e, 0xff, 0xe1, 0, 0, 1, 0]);
  final avc1 = _box('avc1', [
    ...List<int>.filled(6, 0),
    ..._u16(1),
    ...List<int>.filled(16, 0),
    ..._u16(width),
    ..._u16(height),
    ..._u32(0x00480000),
    ..._u32(0x00480000),
    ..._u32(0),
    ..._u16(1),
    ...List<int>.filled(32, 0),
    ..._u16(24),
    ..._u16(0xffff),
    ...avcC,
  ]);
  final stsd = _fullBox('stsd', 0, 0, [..._u32(1), ...avc1]);
  final stts = _fullBox('stts', 0, 0, [..._u32(1), ..._u32(2), ..._u32(33)]);
  final stss = _fullBox('stss', 0, 0, [..._u32(1), ..._u32(1)]);
  final stsc = _fullBox('stsc', 0, 0, [
    ..._u32(1),
    ..._u32(1),
    ..._u32(2),
    ..._u32(1),
  ]);
  final stsz = _fullBox('stsz', 0, 0, [
    ..._u32(0),
    ..._u32(2),
    ..._u32(sample1.length),
    ..._u32(sample2.length),
  ]);
  final stco = _fullBox('stco', 0, 0, [..._u32(1), ..._u32(firstSampleOffset)]);
  final stbl = _box('stbl', [
    ...stsd,
    ...stts,
    ...stss,
    ...stsc,
    ...stsz,
    ...stco,
  ]);
  final minf = _box('minf', stbl);
  final mdhd = _fullBox('mdhd', 0, 0, [
    ..._u32(0),
    ..._u32(0),
    ..._u32(1000),
    ..._u32(66),
    ..._u16(0),
    ..._u16(0),
  ]);
  final hdlr = _fullBox('hdlr', 0, 0, [
    ..._u32(0),
    ...ascii.encode('vide'),
    ...List<int>.filled(12, 0),
    0,
  ]);
  final mdia = _box('mdia', [...mdhd, ...hdlr, ...minf]);
  final tkhd = _fullBox('tkhd', 0, 7, [
    ...List<int>.filled(76, 0),
    ..._u32(width << 16),
    ..._u32(height << 16),
  ]);
  final trak = _box('trak', [...tkhd, ...mdia]);
  final moov = _box('moov', trak);
  return [...ftyp, ...mdat, ...moov];
}

List<int> _box(String type, List<int> payload) {
  return [..._u32(payload.length + 8), ...ascii.encode(type), ...payload];
}

List<int> _fullBox(String type, int version, int flags, List<int> payload) {
  return _box(type, [
    version,
    (flags >> 16) & 0xff,
    (flags >> 8) & 0xff,
    flags & 0xff,
    ...payload,
  ]);
}

List<int> _u16(int value) => [(value >> 8) & 0xff, value & 0xff];

List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

bool _containsAscii(List<int> bytes, String value) =>
    _countAscii(bytes, value) > 0;

int _countAscii(List<int> bytes, String value) {
  final needle = ascii.encode(value);
  var count = 0;
  for (var i = 0; i <= bytes.length - needle.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      count += 1;
    }
  }
  return count;
}
