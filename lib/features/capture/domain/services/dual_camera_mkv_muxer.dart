import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class DualCameraMkvResult {
  const DualCameraMkvResult({
    required this.outputPath,
    required this.durationMs,
  });

  final String outputPath;
  final int durationMs;
}

class DualCameraMkvException implements Exception {
  const DualCameraMkvException(this.message);

  final String message;

  @override
  String toString() => 'DualCameraMkvException: $message';
}

class DualCameraMkvMuxer {
  const DualCameraMkvMuxer();

  Future<DualCameraMkvResult> mux({
    required String detectorVideoPath,
    required String recorderVideoPath,
    required String outputPath,
    String detectorTrackName = 'Detector phone',
    String recorderTrackName = 'Recorder phone',
    int recorderStartOffsetMs = 0,
  }) async {
    final detector = await _Mp4VideoTrack.read(detectorVideoPath);
    final recorder = await _Mp4VideoTrack.read(recorderVideoPath);
    final outputFile = File(outputPath);
    final parent = outputFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    final events =
        <_MuxSample>[
          for (final sample in detector.samples)
            _MuxSample(trackNumber: 1, track: detector, sample: sample),
          for (final sample in recorder.samples)
            _MuxSample(
              trackNumber: 2,
              track: recorder,
              sample: sample,
              timeOffsetMs: recorderStartOffsetMs,
            ),
        ]..sort((a, b) {
          final byTime = a.timeMs.compareTo(b.timeMs);
          return byTime != 0 ? byTime : a.trackNumber.compareTo(b.trackNumber);
        });
    if (events.isEmpty) {
      throw const DualCameraMkvException('No video samples to mux.');
    }

    final minTimeMs = events.first.timeMs;
    final normalizedEvents = minTimeMs < 0
        ? [
            for (final event in events)
              event.copyWith(normalizeOffsetMs: -minTimeMs),
          ]
        : events;
    final durationMs =
        normalizedEvents.map((event) => event.timeMs).reduce(max) + 1;

    final sink = outputFile.openWrite();
    try {
      sink.add(_MkvWriter.element(_MkvIds.ebml, _buildEbmlHeader()));
      sink.add(_MkvWriter.id(_MkvIds.segment));
      sink.add(_MkvWriter.unknownSize());
      sink.add(
        _MkvWriter.element(
          _MkvIds.info,
          _MkvWriter.join([
            _MkvWriter.uintElement(_MkvIds.timecodeScale, 1000000),
            _MkvWriter.stringElement(_MkvIds.muxingApp, 'SwingCapture'),
            _MkvWriter.stringElement(_MkvIds.writingApp, 'SwingCapture'),
            _MkvWriter.floatElement(_MkvIds.duration, durationMs.toDouble()),
          ]),
        ),
      );
      sink.add(
        _MkvWriter.element(
          _MkvIds.tracks,
          _MkvWriter.join([
            _trackEntry(
              number: 1,
              uid: 1,
              name: detectorTrackName,
              track: detector,
            ),
            _trackEntry(
              number: 2,
              uid: 2,
              name: recorderTrackName,
              track: recorder,
            ),
          ]),
        ),
      );

      _writeClusters(
        sink,
        normalizedEvents,
        clusterSpanMs: const Duration(seconds: 30).inMilliseconds,
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
    return DualCameraMkvResult(outputPath: outputPath, durationMs: durationMs);
  }

  static List<int> _buildEbmlHeader() {
    return _MkvWriter.join([
      _MkvWriter.uintElement(_MkvIds.ebmlVersion, 1),
      _MkvWriter.uintElement(_MkvIds.ebmlReadVersion, 1),
      _MkvWriter.uintElement(_MkvIds.ebmlMaxIdLength, 4),
      _MkvWriter.uintElement(_MkvIds.ebmlMaxSizeLength, 8),
      _MkvWriter.stringElement(_MkvIds.docType, 'matroska'),
      _MkvWriter.uintElement(_MkvIds.docTypeVersion, 4),
      _MkvWriter.uintElement(_MkvIds.docTypeReadVersion, 2),
    ]);
  }

  static List<int> _trackEntry({
    required int number,
    required int uid,
    required String name,
    required _Mp4VideoTrack track,
  }) {
    return _MkvWriter.element(
      _MkvIds.trackEntry,
      _MkvWriter.join([
        _MkvWriter.uintElement(_MkvIds.trackNumber, number),
        _MkvWriter.uintElement(_MkvIds.trackUid, uid),
        _MkvWriter.uintElement(_MkvIds.trackType, 1),
        _MkvWriter.stringElement(_MkvIds.trackName, name),
        _MkvWriter.stringElement(_MkvIds.codecId, track.mkvCodecId),
        _MkvWriter.bytesElement(_MkvIds.codecPrivate, track.codecPrivate),
        if (track.defaultDurationNs != null)
          _MkvWriter.uintElement(
            _MkvIds.defaultDuration,
            track.defaultDurationNs!,
          ),
        _MkvWriter.element(
          _MkvIds.video,
          _MkvWriter.join([
            _MkvWriter.uintElement(_MkvIds.pixelWidth, track.width),
            _MkvWriter.uintElement(_MkvIds.pixelHeight, track.height),
          ]),
        ),
      ]),
    );
  }

  static void _writeClusters(
    IOSink sink,
    List<_MuxSample> events, {
    required int clusterSpanMs,
  }) {
    BytesBuilder? cluster;
    var clusterTimecode = 0;

    void flushCluster() {
      final current = cluster;
      if (current == null) {
        return;
      }
      sink.add(_MkvWriter.element(_MkvIds.cluster, current.takeBytes()));
      cluster = null;
    }

    for (final event in events) {
      if (cluster == null ||
          event.timeMs - clusterTimecode > clusterSpanMs ||
          event.timeMs - clusterTimecode > 32767) {
        flushCluster();
        clusterTimecode = event.timeMs;
        cluster = BytesBuilder(copy: false)
          ..add(
            _MkvWriter.uintElement(_MkvIds.clusterTimecode, clusterTimecode),
          );
      }
      final relativeTimecode = event.timeMs - clusterTimecode;
      cluster!.add(_MkvWriter.simpleBlock(event, relativeTimecode));
    }
    flushCluster();
  }
}

class _Mp4VideoTrack {
  const _Mp4VideoTrack({
    required this.path,
    required this.bytes,
    required this.mkvCodecId,
    required this.codecPrivate,
    required this.width,
    required this.height,
    required this.samples,
  });

  final String path;
  final Uint8List bytes;
  final String mkvCodecId;
  final Uint8List codecPrivate;
  final int width;
  final int height;
  final List<_Mp4Sample> samples;

  int? get defaultDurationNs {
    if (samples.length < 2) {
      return null;
    }
    final deltas = <int>[];
    for (var i = 1; i < min(samples.length, 8); i++) {
      final deltaUs =
          samples[i].presentationTimeUs - samples[i - 1].presentationTimeUs;
      if (deltaUs > 0) {
        deltas.add(deltaUs);
      }
    }
    if (deltas.isEmpty) {
      return null;
    }
    deltas.sort();
    return deltas[deltas.length ~/ 2] * 1000;
  }

  static Future<_Mp4VideoTrack> read(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw DualCameraMkvException('Missing video file: $path');
    }
    final bytes = await file.readAsBytes();
    final parser = _Mp4Parser(path: path, bytes: bytes);
    return parser.parseVideoTrack();
  }
}

class _Mp4Sample {
  const _Mp4Sample({
    required this.offset,
    required this.size,
    required this.presentationTimeUs,
    required this.isKeyframe,
  });

  final int offset;
  final int size;
  final int presentationTimeUs;
  final bool isKeyframe;
}

class _MuxSample {
  const _MuxSample({
    required this.trackNumber,
    required this.track,
    required this.sample,
    this.timeOffsetMs = 0,
    this.normalizeOffsetMs = 0,
  });

  final int trackNumber;
  final _Mp4VideoTrack track;
  final _Mp4Sample sample;
  final int timeOffsetMs;
  final int normalizeOffsetMs;

  int get timeMs =>
      sample.presentationTimeUs ~/ 1000 + timeOffsetMs + normalizeOffsetMs;

  _MuxSample copyWith({int normalizeOffsetMs = 0}) {
    return _MuxSample(
      trackNumber: trackNumber,
      track: track,
      sample: sample,
      timeOffsetMs: timeOffsetMs,
      normalizeOffsetMs: this.normalizeOffsetMs + normalizeOffsetMs,
    );
  }
}

class _Mp4Parser {
  const _Mp4Parser({required this.path, required this.bytes});

  final String path;
  final Uint8List bytes;

  ByteData get _data => ByteData.sublistView(bytes);

  _Mp4VideoTrack parseVideoTrack() {
    final moov = _findChild(0, bytes.length, 'moov');
    if (moov == null) {
      throw DualCameraMkvException('MP4 missing moov box: $path');
    }
    for (final trak in _children(moov.contentStart, moov.end)) {
      if (trak.type != 'trak') {
        continue;
      }
      final mdia = _findChild(trak.contentStart, trak.end, 'mdia');
      if (mdia == null) {
        continue;
      }
      final hdlr = _findChild(mdia.contentStart, mdia.end, 'hdlr');
      if (hdlr == null || _readAscii(hdlr.contentStart + 8, 4) != 'vide') {
        continue;
      }
      return _parseVideoTrak(trak, mdia);
    }
    throw DualCameraMkvException('MP4 missing video track: $path');
  }

  _Mp4VideoTrack _parseVideoTrak(_Mp4Box trak, _Mp4Box mdia) {
    final tkhd = _findChild(trak.contentStart, trak.end, 'tkhd');
    final mdhd = _requireChild(mdia, 'mdhd');
    final minf = _requireChild(mdia, 'minf');
    final stbl = _requireChild(minf, 'stbl');
    final stsd = _requireChild(stbl, 'stsd');
    final stts = _requireChild(stbl, 'stts');
    final stsc = _requireChild(stbl, 'stsc');
    final stsz = _requireChild(stbl, 'stsz');
    final chunkOffsetsBox =
        _findChild(stbl.contentStart, stbl.end, 'co64') ??
        _requireChild(stbl, 'stco');

    final sampleDescription = _parseSampleDescription(stsd);
    final timescale = _parseMdhdTimescale(mdhd);
    final sampleDurations = _parseStts(stts);
    final compositionOffsets = _parseCtts(
      _findChild(stbl.contentStart, stbl.end, 'ctts'),
    );
    final sampleSizes = _parseStsz(stsz);
    final sampleToChunks = _parseStsc(stsc);
    final chunkOffsets = _parseChunkOffsets(chunkOffsetsBox);
    final syncSamples = _parseStss(
      _findChild(stbl.contentStart, stbl.end, 'stss'),
    );
    if (sampleSizes.isEmpty) {
      throw DualCameraMkvException('MP4 video track has no samples: $path');
    }
    final sampleOffsets = _sampleOffsets(
      sampleSizes: sampleSizes,
      chunkOffsets: chunkOffsets,
      sampleToChunks: sampleToChunks,
    );
    if (sampleOffsets.length != sampleSizes.length) {
      throw DualCameraMkvException('MP4 sample table mismatch: $path');
    }

    var decodeTimeUnits = 0;
    final samples = <_Mp4Sample>[];
    for (var i = 0; i < sampleSizes.length; i++) {
      final durationUnits = i < sampleDurations.length
          ? sampleDurations[i]
          : sampleDurations.lastOrNull ?? 0;
      final compositionOffset = i < compositionOffsets.length
          ? compositionOffsets[i]
          : 0;
      final presentationUnits = decodeTimeUnits + compositionOffset;
      samples.add(
        _Mp4Sample(
          offset: sampleOffsets[i],
          size: sampleSizes[i],
          presentationTimeUs: presentationUnits * 1000000 ~/ timescale,
          isKeyframe: syncSamples == null || syncSamples.contains(i + 1),
        ),
      );
      decodeTimeUnits += durationUnits;
    }
    samples.sort(
      (a, b) => a.presentationTimeUs.compareTo(b.presentationTimeUs),
    );

    return _Mp4VideoTrack(
      path: path,
      bytes: bytes,
      mkvCodecId: sampleDescription.mkvCodecId,
      codecPrivate: sampleDescription.codecPrivate,
      width: tkhd == null ? sampleDescription.width : _fixedWidth(tkhd),
      height: tkhd == null ? sampleDescription.height : _fixedHeight(tkhd),
      samples: samples,
    );
  }

  _SampleDescription _parseSampleDescription(_Mp4Box stsd) {
    final entryCount = _u32(stsd.contentStart + 4);
    if (entryCount <= 0) {
      throw DualCameraMkvException('MP4 video track missing stsd entry: $path');
    }
    final entryStart = stsd.contentStart + 8;
    final entrySize = _u32(entryStart);
    final entryType = _readAscii(entryStart + 4, 4);
    final entryEnd = entryStart + entrySize;
    final width = _u16(entryStart + 32);
    final height = _u16(entryStart + 34);
    final childStart = entryStart + 86;
    final codecBox = switch (entryType) {
      'avc1' || 'avc3' => _findChild(childStart, entryEnd, 'avcC'),
      'hvc1' || 'hev1' => _findChild(childStart, entryEnd, 'hvcC'),
      _ => null,
    };
    if (codecBox == null) {
      throw DualCameraMkvException(
        'Unsupported MP4 video codec $entryType in $path',
      );
    }
    final mkvCodecId = switch (entryType) {
      'avc1' || 'avc3' => 'V_MPEG4/ISO/AVC',
      'hvc1' || 'hev1' => 'V_MPEGH/ISO/HEVC',
      _ => throw DualCameraMkvException(
        'Unsupported MP4 video codec $entryType in $path',
      ),
    };
    return _SampleDescription(
      mkvCodecId: mkvCodecId,
      codecPrivate: Uint8List.sublistView(
        bytes,
        codecBox.contentStart,
        codecBox.end,
      ),
      width: width,
      height: height,
    );
  }

  int _parseMdhdTimescale(_Mp4Box mdhd) {
    final version = bytes[mdhd.contentStart];
    final offset = version == 1
        ? mdhd.contentStart + 20
        : mdhd.contentStart + 12;
    final timescale = _u32(offset);
    if (timescale <= 0) {
      throw DualCameraMkvException('Invalid MP4 timescale in $path');
    }
    return timescale;
  }

  List<int> _parseStts(_Mp4Box stts) {
    final entryCount = _u32(stts.contentStart + 4);
    var offset = stts.contentStart + 8;
    final durations = <int>[];
    for (var i = 0; i < entryCount; i++) {
      final count = _u32(offset);
      final delta = _u32(offset + 4);
      durations.addAll(List<int>.filled(count, delta));
      offset += 8;
    }
    return durations;
  }

  List<int> _parseCtts(_Mp4Box? ctts) {
    if (ctts == null) {
      return const [];
    }
    final version = bytes[ctts.contentStart];
    final entryCount = _u32(ctts.contentStart + 4);
    var offset = ctts.contentStart + 8;
    final offsets = <int>[];
    for (var i = 0; i < entryCount; i++) {
      final count = _u32(offset);
      final sampleOffset = version == 1 ? _i32(offset + 4) : _u32(offset + 4);
      offsets.addAll(List<int>.filled(count, sampleOffset));
      offset += 8;
    }
    return offsets;
  }

  List<int> _parseStsz(_Mp4Box stsz) {
    final sampleSize = _u32(stsz.contentStart + 4);
    final sampleCount = _u32(stsz.contentStart + 8);
    if (sampleSize > 0) {
      return List<int>.filled(sampleCount, sampleSize);
    }
    var offset = stsz.contentStart + 12;
    final sizes = <int>[];
    for (var i = 0; i < sampleCount; i++) {
      sizes.add(_u32(offset));
      offset += 4;
    }
    return sizes;
  }

  List<_SampleToChunk> _parseStsc(_Mp4Box stsc) {
    final entryCount = _u32(stsc.contentStart + 4);
    var offset = stsc.contentStart + 8;
    final entries = <_SampleToChunk>[];
    for (var i = 0; i < entryCount; i++) {
      entries.add(
        _SampleToChunk(
          firstChunk: _u32(offset),
          samplesPerChunk: _u32(offset + 4),
        ),
      );
      offset += 12;
    }
    return entries;
  }

  List<int> _parseChunkOffsets(_Mp4Box box) {
    final entryCount = _u32(box.contentStart + 4);
    var offset = box.contentStart + 8;
    final offsets = <int>[];
    for (var i = 0; i < entryCount; i++) {
      if (box.type == 'co64') {
        offsets.add(_u64(offset));
        offset += 8;
      } else {
        offsets.add(_u32(offset));
        offset += 4;
      }
    }
    return offsets;
  }

  Set<int>? _parseStss(_Mp4Box? stss) {
    if (stss == null) {
      return null;
    }
    final entryCount = _u32(stss.contentStart + 4);
    var offset = stss.contentStart + 8;
    final samples = <int>{};
    for (var i = 0; i < entryCount; i++) {
      samples.add(_u32(offset));
      offset += 4;
    }
    return samples;
  }

  List<int> _sampleOffsets({
    required List<int> sampleSizes,
    required List<int> chunkOffsets,
    required List<_SampleToChunk> sampleToChunks,
  }) {
    if (sampleToChunks.isEmpty || chunkOffsets.isEmpty) {
      return const [];
    }
    final offsets = <int>[];
    var sampleIndex = 0;
    var stscIndex = 0;
    for (var chunkIndex = 1; chunkIndex <= chunkOffsets.length; chunkIndex++) {
      if (stscIndex + 1 < sampleToChunks.length &&
          chunkIndex >= sampleToChunks[stscIndex + 1].firstChunk) {
        stscIndex += 1;
      }
      var sampleOffset = chunkOffsets[chunkIndex - 1];
      final samplesPerChunk = sampleToChunks[stscIndex].samplesPerChunk;
      for (
        var i = 0;
        i < samplesPerChunk && sampleIndex < sampleSizes.length;
        i++
      ) {
        offsets.add(sampleOffset);
        sampleOffset += sampleSizes[sampleIndex];
        sampleIndex += 1;
      }
    }
    return offsets;
  }

  _Mp4Box _requireChild(_Mp4Box parent, String type) {
    final child = _findChild(parent.contentStart, parent.end, type);
    if (child == null) {
      throw DualCameraMkvException('MP4 missing $type box in $path');
    }
    return child;
  }

  _Mp4Box? _findChild(int start, int end, String type) {
    for (final child in _children(start, end)) {
      if (child.type == type) {
        return child;
      }
    }
    return null;
  }

  Iterable<_Mp4Box> _children(int start, int end) sync* {
    var offset = start;
    while (offset + 8 <= end && offset + 8 <= bytes.length) {
      final size32 = _u32(offset);
      final type = _readAscii(offset + 4, 4);
      var headerSize = 8;
      var size = size32;
      if (size32 == 1) {
        size = _u64(offset + 8);
        headerSize = 16;
      } else if (size32 == 0) {
        size = end - offset;
      }
      if (size < headerSize ||
          offset + size > end ||
          offset + size > bytes.length) {
        break;
      }
      yield _Mp4Box(
        start: offset,
        contentStart: offset + headerSize,
        end: offset + size,
        type: type,
      );
      offset += size;
    }
  }

  int _fixedWidth(_Mp4Box tkhd) => _u32(tkhd.end - 8) >> 16;
  int _fixedHeight(_Mp4Box tkhd) => _u32(tkhd.end - 4) >> 16;

  String _readAscii(int offset, int length) {
    return String.fromCharCodes(bytes.sublist(offset, offset + length));
  }

  int _u16(int offset) => _data.getUint16(offset);
  int _u32(int offset) => _data.getUint32(offset);
  int _i32(int offset) => _data.getInt32(offset);
  int _u64(int offset) => _data.getUint64(offset);
}

class _Mp4Box {
  const _Mp4Box({
    required this.start,
    required this.contentStart,
    required this.end,
    required this.type,
  });

  final int start;
  final int contentStart;
  final int end;
  final String type;
}

class _SampleDescription {
  const _SampleDescription({
    required this.mkvCodecId,
    required this.codecPrivate,
    required this.width,
    required this.height,
  });

  final String mkvCodecId;
  final Uint8List codecPrivate;
  final int width;
  final int height;
}

class _SampleToChunk {
  const _SampleToChunk({
    required this.firstChunk,
    required this.samplesPerChunk,
  });

  final int firstChunk;
  final int samplesPerChunk;
}

class _MkvIds {
  static const ebml = 0x1A45DFA3;
  static const ebmlVersion = 0x4286;
  static const ebmlReadVersion = 0x42F7;
  static const ebmlMaxIdLength = 0x42F2;
  static const ebmlMaxSizeLength = 0x42F3;
  static const docType = 0x4282;
  static const docTypeVersion = 0x4287;
  static const docTypeReadVersion = 0x4285;
  static const segment = 0x18538067;
  static const info = 0x1549A966;
  static const timecodeScale = 0x2AD7B1;
  static const duration = 0x4489;
  static const muxingApp = 0x4D80;
  static const writingApp = 0x5741;
  static const tracks = 0x1654AE6B;
  static const trackEntry = 0xAE;
  static const trackNumber = 0xD7;
  static const trackUid = 0x73C5;
  static const trackType = 0x83;
  static const trackName = 0x536E;
  static const codecId = 0x86;
  static const codecPrivate = 0x63A2;
  static const defaultDuration = 0x23E383;
  static const video = 0xE0;
  static const pixelWidth = 0xB0;
  static const pixelHeight = 0xBA;
  static const cluster = 0x1F43B675;
  static const clusterTimecode = 0xE7;
  static const simpleBlock = 0xA3;
}

class _MkvWriter {
  static List<int> element(int id, List<int> data) {
    return [..._id(id), ..._size(data.length), ...data];
  }

  static List<int> bytesElement(int id, List<int> data) => element(id, data);

  static List<int> uintElement(int id, int value) {
    return element(id, _uint(value));
  }

  static List<int> stringElement(int id, String value) {
    return element(id, value.codeUnits);
  }

  static List<int> floatElement(int id, double value) {
    final data = ByteData(8)..setFloat64(0, value);
    return element(id, data.buffer.asUint8List());
  }

  static List<int> simpleBlock(_MuxSample event, int relativeTimecode) {
    final sample = event.sample;
    final data = event.track.bytes.sublist(
      sample.offset,
      sample.offset + sample.size,
    );
    final header = <int>[
      _trackNumber(event.trackNumber),
      (relativeTimecode >> 8) & 0xff,
      relativeTimecode & 0xff,
      sample.isKeyframe ? 0x80 : 0x00,
    ];
    return element(_MkvIds.simpleBlock, [...header, ...data]);
  }

  static List<int> join(Iterable<List<int>> chunks) {
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static List<int> id(int id) => _id(id);

  static List<int> unknownSize() => const [
    0x01,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
  ];

  static List<int> _id(int value) {
    final bytes = <int>[];
    var started = false;
    for (var shift = 24; shift >= 0; shift -= 8) {
      final byte = (value >> shift) & 0xff;
      if (byte != 0 || started || shift == 0) {
        started = true;
        bytes.add(byte);
      }
    }
    return bytes;
  }

  static List<int> _size(int value) {
    for (var length = 1; length <= 8; length++) {
      final maxValue = (1 << (7 * length)) - 2;
      if (value <= maxValue) {
        final encoded = value | (1 << (7 * length));
        final bytes = List<int>.filled(length, 0);
        for (var i = length - 1; i >= 0; i--) {
          bytes[i] = (encoded >> (8 * (length - 1 - i))) & 0xff;
        }
        return bytes;
      }
    }
    throw const DualCameraMkvException('EBML element too large.');
  }

  static List<int> _uint(int value) {
    if (value < 0) {
      throw const DualCameraMkvException('Negative unsigned EBML integer.');
    }
    final bytes = <int>[];
    var started = false;
    for (var shift = 56; shift >= 0; shift -= 8) {
      final byte = (value >> shift) & 0xff;
      if (byte != 0 || started || shift == 0) {
        started = true;
        bytes.add(byte);
      }
    }
    return bytes;
  }

  static int _trackNumber(int number) {
    if (number < 1 || number > 126) {
      throw const DualCameraMkvException('Unsupported MKV track number.');
    }
    return 0x80 | number;
  }
}
