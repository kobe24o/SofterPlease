import 'dart:io';

import 'package:softerplease/local/model_pack.dart';

Future<void> main() async {
  final root =
      await Directory.systemTemp.createTemp('softerplease-model-pack-');
  try {
    final absent = await LocalModelPack.inspect(root);
    if (absent.isInstalled) {
      throw StateError('empty model pack was accepted');
    }
    for (final path in <String>[
      absent.senseVoicePath,
      absent.senseVoiceTokensPath,
      absent.vadPath,
      absent.speakerPath,
    ]) {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(const [0]);
    }
    final installed = await LocalModelPack.inspect(root);
    if (!installed.isInstalled) {
      throw StateError('complete model pack was rejected');
    }
  } finally {
    await root.delete(recursive: true);
  }
}
