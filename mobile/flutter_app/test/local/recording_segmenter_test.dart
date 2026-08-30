import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/local/recording_segmenter.dart';

void main() {
  test('prefers the latest VAD silence near the 60-second target', () {
    final segmenter = PcmSegmenter(
      sampleRate: 10,
      targetSeconds: 6,
      maxSeconds: 7,
      boundaryLookbackSeconds: 2,
    );
    final original = _pcmSamples(60);
    final emitted = <PcmSegment>[];
    for (var sample = 0; sample < 60; sample++) {
      emitted.addAll(segmenter.push(PcmFrame(
        bytes: original.sublist(sample * 2, sample * 2 + 2),
        endsInSilence: sample == 57,
      )));
    }
    emitted.addAll(segmenter.finish());

    expect(emitted.first.endSample, 58);
    expect(_join(emitted), original);
  });

  test('forces a bounded segment when VAD finds no silence', () {
    final segmenter = PcmSegmenter(
      sampleRate: 10,
      targetSeconds: 6,
      maxSeconds: 7,
      boundaryLookbackSeconds: 2,
    );
    final original = _pcmSamples(70);
    final emitted = <PcmSegment>[];
    for (var sample = 0; sample < 70; sample++) {
      emitted.addAll(segmenter.push(PcmFrame(
        bytes: original.sublist(sample * 2, sample * 2 + 2),
        endsInSilence: false,
      )));
    }

    expect(emitted.single.durationSamples, 70);
    expect(_join(emitted), original);
  });

  test('flushes the remaining tail exactly once when recording stops', () {
    final segmenter = PcmSegmenter(
      sampleRate: 10,
      targetSeconds: 6,
      maxSeconds: 7,
      boundaryLookbackSeconds: 2,
    );
    final original = _pcmSamples(5);
    for (var sample = 0; sample < 5; sample++) {
      segmenter.push(PcmFrame(
        bytes: original.sublist(sample * 2, sample * 2 + 2),
        endsInSilence: false,
      ));
    }

    final emitted = segmenter.finish();

    expect(emitted.single.durationSamples, 5);
    expect(_join(emitted), original);
    expect(segmenter.finish(), isEmpty);
  });

  test('uses the supplied VAD gate when routing stream frames', () {
    final coordinator = PcmRecordingSegmentCoordinator(
      segmenter: PcmSegmenter(
        sampleRate: 10,
        targetSeconds: 6,
        maxSeconds: 7,
        boundaryLookbackSeconds: 2,
      ),
      endsAtVadBoundary: (bytes) => bytes.first == 9,
    );
    expect(coordinator.accept(_pcmSamples(60)), isEmpty);

    final withBoundary = coordinator.accept(Uint8List.fromList([9, 0]));
    expect(withBoundary.single.durationSamples, 61);
  });
}

Uint8List _pcmSamples(int count) => Uint8List.fromList(
      List<int>.generate(count * 2, (index) => index % 251),
    );

Uint8List _join(Iterable<PcmSegment> segments) => Uint8List.fromList(
      segments.expand((segment) => segment.bytes).toList(growable: false),
    );
