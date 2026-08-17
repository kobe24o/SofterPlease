import 'package:softerplease/local/local_speech_analysis.dart';

void main() {
  final analysis = LocalSpeechAnalysis.fromRecognitionResults(
    const [
      LocalRecognitionResult(text: '你好', emotion: 'NEUTRAL'),
      LocalRecognitionResult(text: '我们慢慢说', emotion: 'HAPPY'),
    ],
    speakerCount: 2,
  );

  if (analysis.transcript != '你好\n我们慢慢说') {
    throw StateError('Expected preserved line-separated transcript');
  }
  if (analysis.emotionLabel != '积极') {
    throw StateError('Expected the strongest non-neutral emotion label');
  }
  if (analysis.speakerLabel != '检测到 2 位说话人') {
    throw StateError('Expected local speaker count label');
  }
}
