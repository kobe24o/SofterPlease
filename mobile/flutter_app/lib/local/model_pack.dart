import 'dart:io';

final class LocalModelPack {
  const LocalModelPack._({
    required this.root,
    required this.isInstalled,
    required this.message,
  });

  final Directory root;
  final bool isInstalled;
  final String message;

  String get senseVoicePath =>
      '${root.path}${Platform.pathSeparator}sensevoice${Platform.pathSeparator}model.int8.onnx';
  String get senseVoiceTokensPath =>
      '${root.path}${Platform.pathSeparator}sensevoice${Platform.pathSeparator}tokens.txt';
  String get vadPath =>
      '${root.path}${Platform.pathSeparator}vad${Platform.pathSeparator}ten-vad.int8.onnx';
  String get speakerPath =>
      '${root.path}${Platform.pathSeparator}speaker${Platform.pathSeparator}model.onnx';

  static Future<LocalModelPack> inspect(Directory documentsDirectory) async {
    final root =
        Directory('${documentsDirectory.path}${Platform.pathSeparator}models');
    final required = <String>[
      '${root.path}${Platform.pathSeparator}sensevoice${Platform.pathSeparator}model.int8.onnx',
      '${root.path}${Platform.pathSeparator}sensevoice${Platform.pathSeparator}tokens.txt',
      '${root.path}${Platform.pathSeparator}vad${Platform.pathSeparator}ten-vad.int8.onnx',
      '${root.path}${Platform.pathSeparator}speaker${Platform.pathSeparator}model.onnx',
    ];
    final installed =
        await Future.wait(required.map((path) => File(path).exists()));
    if (installed.every((value) => value)) {
      return LocalModelPack._(
          root: root, isInstalled: true, message: '本地语音模型已就绪');
    }
    return LocalModelPack._(
      root: root,
      isInstalled: false,
      message: '尚未安装本地模型包。请在“我的”页面导入 SenseVoice、Ten-VAD 和说话人模型。',
    );
  }
}
