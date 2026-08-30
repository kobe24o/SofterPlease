import 'dart:io';
import 'dart:typed_data';

final class PcmFrame {
  const PcmFrame({required this.bytes, required this.endsInSilence});

  final Uint8List bytes;
  final bool endsInSilence;
}

final class PcmSegment {
  const PcmSegment({
    required this.bytes,
    required this.startSample,
    required this.endSample,
  });

  final Uint8List bytes;
  final int startSample;
  final int endSample;

  int get durationSamples => endSample - startSample;
}

final class PcmSegmenter {
  PcmSegmenter({
    required this.sampleRate,
    this.targetSeconds = 60,
    this.maxSeconds = 66,
    this.boundaryLookbackSeconds = 12,
  })  : assert(sampleRate > 0),
        assert(targetSeconds > 0),
        assert(maxSeconds >= targetSeconds),
        assert(boundaryLookbackSeconds >= 0);

  final int sampleRate;
  final int targetSeconds;
  final int maxSeconds;
  final int boundaryLookbackSeconds;
  Uint8List _buffer = Uint8List(0);
  final List<int> _silenceBoundaries = [];
  int _startSample = 0;

  int get _targetSamples => sampleRate * targetSeconds;
  int get _maxSamples => sampleRate * maxSeconds;
  int get _lookbackSamples => sampleRate * boundaryLookbackSeconds;
  int get _bufferSamples => _buffer.length ~/ 2;

  List<PcmSegment> push(PcmFrame frame) {
    if (frame.bytes.isEmpty) return const [];
    if (frame.bytes.length.isOdd) {
      throw ArgumentError.value(
          frame.bytes.length, 'bytes', 'PCM must be 16-bit');
    }
    final merged = Uint8List(_buffer.length + frame.bytes.length);
    merged.setAll(0, _buffer);
    merged.setAll(_buffer.length, frame.bytes);
    _buffer = merged;
    if (frame.endsInSilence) _silenceBoundaries.add(_bufferSamples);
    return _emitReady();
  }

  List<PcmSegment> finish() {
    if (_buffer.isEmpty) return const [];
    return [_emit(_bufferSamples)];
  }

  List<PcmSegment> _emitReady() {
    final segments = <PcmSegment>[];
    while (_bufferSamples >= _targetSamples) {
      final lowerBound = _targetSamples - _lookbackSamples;
      final candidate = _silenceBoundaries
          .where((boundary) =>
              boundary >= lowerBound && boundary <= _bufferSamples)
          .fold<int?>(
              null,
              (latest, boundary) =>
                  latest == null || boundary > latest ? boundary : latest);
      if (candidate != null) {
        segments.add(_emit(candidate));
        continue;
      }
      if (_bufferSamples >= _maxSamples) {
        segments.add(_emit(_maxSamples));
        continue;
      }
      break;
    }
    return segments;
  }

  PcmSegment _emit(int sampleCount) {
    final byteCount = sampleCount * 2;
    final bytes = Uint8List.fromList(_buffer.sublist(0, byteCount));
    _buffer = Uint8List.fromList(_buffer.sublist(byteCount));
    final segment = PcmSegment(
      bytes: bytes,
      startSample: _startSample,
      endSample: _startSample + sampleCount,
    );
    _startSample += sampleCount;
    final remaining = <int>[];
    for (final boundary in _silenceBoundaries) {
      final next = boundary - sampleCount;
      if (next > 0) remaining.add(next);
    }
    _silenceBoundaries
      ..clear()
      ..addAll(remaining);
    return segment;
  }
}

/// Connects a stream of PCM frames to [PcmSegmenter].  The detector is kept
/// outside the segmenter so that the boundary policy remains deterministic and
/// easy to test, while the app can supply the on-device VAD implementation.
typedef PcmSilenceBoundaryDetector = bool Function(Uint8List bytes);

final class PcmRecordingSegmentCoordinator {
  PcmRecordingSegmentCoordinator({
    required PcmSegmenter segmenter,
    required PcmSilenceBoundaryDetector endsAtVadBoundary,
  })  : _segmenter = segmenter,
        _endsAtVadBoundary = endsAtVadBoundary;

  final PcmSegmenter _segmenter;
  final PcmSilenceBoundaryDetector _endsAtVadBoundary;

  List<PcmSegment> accept(Uint8List bytes) => _segmenter.push(PcmFrame(
        bytes: bytes,
        endsInSilence: _endsAtVadBoundary(bytes),
      ));

  List<PcmSegment> finish() => _segmenter.finish();
}

final class PcmWavWriter {
  static Future<File> write({
    required File file,
    required PcmSegment segment,
    required int sampleRate,
  }) async {
    final wav = Uint8List(44 + segment.bytes.length);
    final header = ByteData.sublistView(wav);
    wav.setAll(0, const [82, 73, 70, 70]);
    header.setUint32(4, 36 + segment.bytes.length, Endian.little);
    wav.setAll(8, const [87, 65, 86, 69, 102, 109, 116, 32]);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    wav.setAll(36, const [100, 97, 116, 97]);
    header.setUint32(40, segment.bytes.length, Endian.little);
    wav.setAll(44, segment.bytes);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(wav, flush: true);
    return file;
  }
}
