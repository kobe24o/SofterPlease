import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'model_pack.dart';

final class LocalRecognitionResult {
  const LocalRecognitionResult({required this.text, required this.emotion});

  final String text;
  final String emotion;
}

final class LocalSpeechAnalysis {
  const LocalSpeechAnalysis({
    required this.transcript,
    required this.emotionLabel,
    required this.emotionValue,
    required this.speakerLabel,
    required this.speechSegmentCount,
  });

  final String transcript;
  final String emotionLabel;
  final int emotionValue;
  final String speakerLabel;
  final int speechSegmentCount;

  factory LocalSpeechAnalysis.fromRecognitionResults(
    List<LocalRecognitionResult> results, {
    required int speakerCount,
  }) {
    final transcript = results
        .map((item) => item.text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n');
    final labels = results
        .map((item) => _emotionInfo(item.emotion))
        .where((item) => item.label != '中性')
        .toList(growable: false);
    final emotion = labels.isEmpty ? const _EmotionInfo('中性', 0) : labels.last;
    return LocalSpeechAnalysis(
      transcript: transcript,
      emotionLabel: emotion.label,
      emotionValue: emotion.value,
      speakerLabel: speakerCount > 0 ? '检测到 $speakerCount 位说话人' : '未检测到可用声纹',
      speechSegmentCount: results.length,
    );
  }
}

final class LocalSpeechAnalyzer {
  static bool _bindingsReady = false;

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
            results.add(LocalRecognitionResult(
              text: result.text,
              emotion: result.emotion,
            ));
          } finally {
            stream.free();
          }

          final embedding = _speakerEmbedding(
            speakerExtractor,
            segment.samples,
            wave.sampleRate,
          );
          if (embedding != null) _addToCluster(clusters, embedding);
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

  static void _addToCluster(
    List<_SpeakerCluster> clusters,
    Float32List embedding,
  ) {
    _SpeakerCluster? nearest;
    var nearestScore = -1.0;
    for (final cluster in clusters) {
      final score = _cosineSimilarity(cluster.centroid, embedding);
      if (score > nearestScore) {
        nearest = cluster;
        nearestScore = score;
      }
    }
    if (nearest != null && nearestScore >= 0.60) {
      nearest.add(embedding);
      return;
    }
    clusters.add(_SpeakerCluster(embedding));
  }

  static double _cosineSimilarity(Float32List left, Float32List right) {
    if (left.length != right.length || left.isEmpty) return -1;
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var index = 0; index < left.length; index++) {
      dot += left[index] * right[index];
      leftNorm += left[index] * left[index];
      rightNorm += right[index] * right[index];
    }
    if (leftNorm == 0 || rightNorm == 0) return -1;
    return dot / (sqrt(leftNorm) * sqrt(rightNorm));
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
