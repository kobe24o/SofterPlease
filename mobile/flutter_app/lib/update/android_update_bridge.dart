import 'dart:io';

import 'package:flutter/services.dart';

import 'update_manifest.dart';

final class AndroidUpdateBridge {
  static const _channel = MethodChannel('com.softerplease.app/update');

  static Future<void> install(File file, UpdateManifest manifest) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('当前平台不支持 APK 更新');
    }
    final info = await _channel.invokeMapMethod<String, dynamic>(
      'inspectApk',
      {'path': file.path},
    );
    if (info == null ||
        info['packageName'] != manifest.packageName ||
        info['versionCode'] != manifest.buildNumber ||
        info['certificateSha256'] != manifest.signingCertificateSha256) {
      throw StateError('下载的 APK 身份校验失败');
    }
    final allowed =
        await _channel.invokeMethod<bool>('canRequestPackageInstalls');
    if (allowed != true) {
      await _channel.invokeMethod<void>('openInstallPermission');
      throw StateError('请允许此应用安装更新后再重试');
    }
    await _channel.invokeMethod<void>('installApk', {'path': file.path});
  }
}
