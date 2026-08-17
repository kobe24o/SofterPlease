import 'dart:io';

import 'package:flutter/services.dart';

import 'model_pack.dart';

final class BundledModelInstaller {
  static const _channel = MethodChannel('com.softerplease.app/model_assets');

  static Future<LocalModelPack> installIfNeeded(Directory documents) async {
    final existing = await LocalModelPack.inspect(documents);
    if (existing.isInstalled) return existing;
    if (!Platform.isAndroid) return existing;
    await _channel
        .invokeMethod<void>('installModels', {'rootPath': existing.root.path});
    return LocalModelPack.inspect(documents);
  }
}
