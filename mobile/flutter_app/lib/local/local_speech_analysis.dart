import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'conversation_models.dart';
import 'model_pack.dart';

final class LocalRecognitionResult {
  const LocalRecognitionResult({
    required this.text,
    required this.emotion,
    this.startMilliseconds = 0,
    this.endMilliseconds = 0,
    this.sessionCluster = 0,
    this.embedding,
  });

  final String text;
  final String emotion;
  final int startMilliseconds;
  final int endMilliseconds;
  final int sessionCluster;
  final Float32List? embedding;
}

final class LocalSpeechAnalysis {
  const LocalSpeechAnalysis({
    required this.transcript,
    required this.emotionLabel,
    required this.emotionValue,
    required this.speakerLabel,
    required this.speechSegmentCount,
    required this.utterances,
  });

  final String transcript;
  final String emotionLabel;
  final int emotionValue;
  final String speakerLabel;
  final int speechSegmentCount;
  final List<LocalUtterance> utterances;

  factory LocalSpeechAnalysis.fromRecognitionResults(
    List<LocalRecognitionResult> results, {
    required int speakerCount,
  }) {
    final utterances = results.indexed.map((entry) {
      final index = entry.$1;
      final item = entry.$2;
      final emotion = _emotionInfo(item.emotion);
      final cluster = item.sessionCluster;
      return LocalUtterance(
        id: 'utterance-${index + 1}',
        startMilliseconds: item.startMilliseconds,
        endMilliseconds: item.endMilliseconds,
        transcript: item.text.trim(),
        rawEmotion: item.emotion,
        emotionLabel: emotion.label,
        emotionValue: emotion.value,
        sessionCluster: cluster,
        speakerLabel: cluster > 0 ? '待确认说话人 $cluster' : '未知说话人',
        embedding: item.embedding,
      );
    }).toList(growable: false);
    final transcript = utterances
        .map((item) => item.transcript)
        .where((text) => text.isNotEmpty)
        .join('\n');
    final emphasized = utterances
        .where((item) => item.emotionLabel != '中性')
        .toList(growable: false);
    final emotion = emphasized.isEmpty
        ? const _EmotionInfo('中性', 0)
        : _EmotionInfo(
            emphasized.last.emotionLabel,
            emphasized.last.emotionValue,
          );
    return LocalSpeechAnalysis(
      transcript: transcript,
      emotionLabel: emotion.label,
      emotionValue: emotion.value,
      speakerLabel: speakerCount > 0 ? '检测到 $speakerCount 位说话人' : '未检测到可用声纹',
      speechSegmentCount: utterances.length,
      utterances: utterances,
    );
  }
}

final class LocalSpeechAnalyzer {
  static bool _bindingsReady = false;

  /// Creates a lightweight VAD gate for recording-time cut points.  Completed
  /// VAD segments are emitted only after a real silence boundary, so the PCM
  /// segmenter can avoid splitting in the middle of a sentence.
  StreamingVadBoundaryDetector createStreamingVad(
    LocalModelPack modelPack,
  ) {
    if (!modelPack.isInstalled) {
      throw StateError('本地语音模型尚未安装');
    }
    _ensureBindings();
    return StreamingVadBoundaryDetector(modelPath: modelPack.vadPath);
  }

  Future<LocalSpeechAnalysis> analyze({
    required String audioPath,
    required LocalModelPack modelPack,
  }) async {
    if (!modelPack.isInstalled) {
      throw StateError('本地语音模型尚未安装');
    }
    if (!File(audioPath).existsSync()) {
      throw StateError('本地录音文件不存在');
    }
    _ensureBindings();

    final wave = readWave(audioPath);
    if (wave.sampleRate != 16000 || wave.samples.isEmpty) {
      throw StateError('仅支持 16 kHz 单声道 WAV 录音');
    }

    final recognizer = OfflineRecognizer(
      OfflineRecognizerConfig(
        model: OfflineModelConfig(
          senseVoice: OfflineSenseVoiceModelConfig(
            model: modelPack.senseVoicePath,
            language: 'zh',
            useInverseTextNormalization: true,
          ),
          tokens: modelPack.senseVoiceTokensPath,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
      ),
    );
    final vad = VoiceActivityDetector(
      config: VadModelConfig(
        tenVad: TenVadModelConfig(
          model: modelPack.vadPath,
          threshold: 0.5,
          minSilenceDuration: 0.35,
          minSpeechDuration: 0.25,
          maxSpeechDuration: 15,
        ),
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    final speakerExtractor = SpeakerEmbeddingExtractor(
      config: SpeakerEmbeddingExtractorConfig(
        model: modelPack.speakerPath,
        numThreads: 1,
        debug: false,
      ),
    );

    try {
      final results = <LocalRecognitionResult>[];
      final clusters = <_SpeakerCluster>[];

      void consumeSegments() {
        while (!vad.isEmpty()) {
          final segment = vad.front();
          vad.pop();
          if (segment.samples.length < 4000) continue;
          final stream = recognizer.createStream();
          try {
            stream.acceptWaveform(
              samples: segment.samples,
              sampleRate: wave.sampleRate,
            );
            recognizer.decode(stream);
            final result = recognizer.getResult(stream);
            final embedding = _speakerEmbedding(
              speakerExtractor,
              segment.samples,
              wave.sampleRate,
            );
            final cluster =
                embedding == null ? 0 : _addToCluster(clusters, embedding);
            results.add(LocalRecognitionResult(
              text: result.text,
              emotion: result.emotion,
              startMilliseconds:
                  (segment.start * 1000 / wave.sampleRate).round(),
              endMilliseconds: ((segment.start + segment.samples.length) *
                      1000 /
                      wave.sampleRate)
                  .round(),
              sessionCluster: cluster,
              embedding: embedding,
            ));
          } finally {
            stream.free();
          }
        }
      }

      const chunkSamples = 1600;
      for (var start = 0; start < wave.samples.length; start += chunkSamples) {
        final end = (start + chunkSamples).clamp(0, wave.samples.length);
        vad.acceptWaveform(wave.samples.sublist(start, end));
        consumeSegments();
      }
      vad.flush();
      consumeSegments();
      return LocalSpeechAnalysis.fromRecognitionResults(
        results,
        speakerCount: clusters.length,
      );
    } finally {
      speakerExtractor.free();
      vad.free();
      recognizer.free();
    }
  }

  static void _ensureBindings() {
    if (_bindingsReady) return;
    initBindings();
    _bindingsReady = true;
  }

  static Float32List? _speakerEmbedding(
    SpeakerEmbeddingExtractor extractor,
    Float32List samples,
    int sampleRate,
  ) {
    final stream = extractor.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      if (!extractor.isReady(stream)) return null;
      final embedding = extractor.compute(stream);
      return embedding.isEmpty ? null : embedding;
    } finally {
      stream.free();
    }
  }

  static int _addToCluster(
    List<_SpeakerCluster> clusters,
    Float32List embedding,
  ) {
    _SpeakerCluster? nearest;
    var nearestScore = -1.0;
    for (final cluster in clusters) {
      final score =
          SpeakerMatcher.cosineSimilarity(cluster.centroid, embedding);
      if (score > nearestScore) {
        nearest = cluster;
        nearestScore = score;
      }
    }
    if (nearest != null && nearestScore >= 0.60) {
      nearest.add(embedding);
      return clusters.indexOf(nearest) + 1;
    }
    clusters.add(_SpeakerCluster(embedding));
    return clusters.length;
  }
}

final class StreamingVadBoundaryDetector {
  StreamingVadBoundaryDetector({required String modelPath})
      : _vad = VoiceActivityDetector(
          config: VadModelConfig(
            tenVad: TenVadModelConfig(
              model: modelPath,
              threshold: 0.5,
              minSilenceDuration: 0.35,
              minSpeechDuration: 0.25,
              // This only finds natural endpoints. The recorder owns the
              // 66-second safety cap, so VAD itself must not force a split.
              maxSpeechDuration: 90,
            ),
            numThreads: 1,
            debug: false,
          ),
          bufferSizeInSeconds: 100,
        );

  final VoiceActivityDetector _vad;
  bool _disposed = false;

  bool acceptPcm16(Uint8List bytes) {
    if (_disposed || bytes.isEmpty || bytes.length.isOdd) return false;
    final raw = ByteData.sublistView(bytes);
    final samples = Float32List(bytes.length ~/ 2);
    for (var index = 0; index < samples.length; index++) {
      samples[index] = raw.getInt16(index * 2, Endian.little) / 32768;
    }
    _vad.acceptWaveform(samples);
    var endedAtSilence = false;
    while (!_vad.isEmpty()) {
      _vad.pop();
      endedAtSilence = true;
    }
    return endedAtSilence;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _vad.free();
  }
}

final class _SpeakerCluster {
  _SpeakerCluster(Float32List embedding)
      : centroid = Float32List.fromList(embedding);

  final Float32List centroid;
  var _count = 1;

  void add(Float32List embedding) {
    for (var index = 0; index < centroid.length; index++) {
      centroid[index] =
          (centroid[index] * _count + embedding[index]) / (_count + 1);
    }
    _count++;
  }
}

final class _EmotionInfo {
  const _EmotionInfo(this.label, this.value);

  final String label;
  final int value;
}

_EmotionInfo _emotionInfo(String raw) {
  final emotion = raw.toUpperCase();
  if (emotion.contains('HAPPY') || emotion.contains('SURPRISE')) {
    return const _EmotionInfo('积极', 1);
  }
  if (emotion.contains('ANGRY') ||
      emotion.contains('SAD') ||
      emotion.contains('FEAR') ||
      emotion.contains('DISGUST')) {
    return const _EmotionInfo('消极', -1);
  }
  return const _EmotionInfo('中性', 0);
}
