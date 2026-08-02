import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'update_feed_builder.dart';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final required = <String>[
    'apk',
    'version',
    'build-number',
    'certificate-sha256',
    'output',
  ];
  for (final name in required) {
    if ((options[name] ?? '').isEmpty) {
      throw ArgumentError('缺少参数 --$name');
    }
  }
  final privateKeyBase64 =
      Platform.environment['UPDATE_MANIFEST_PRIVATE_KEY_BASE64'] ?? '';
  if (privateKeyBase64.isEmpty) {
    throw StateError('未配置 UPDATE_MANIFEST_PRIVATE_KEY_BASE64');
  }

  final apk = File(options['apk']!);
  if (!await apk.exists()) throw ArgumentError('APK 不存在：${apk.path}');
  final buildNumber = int.tryParse(options['build-number']!);
  if (buildNumber == null || buildNumber <= 0) {
    throw ArgumentError('--build-number 必须为正整数');
  }
  final certificate = options['certificate-sha256']!.toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(certificate)) {
    throw ArgumentError('--certificate-sha256 必须为 SHA-256 十六进制摘要');
  }

  final hash = await Sha256().hash(await apk.readAsBytes());
  final sha256 =
      hash.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final version = options['version']!;
  final manifest = <String, Object>{
    'version': version,
    'build_number': buildNumber,
    'platform': 'android',
    'sha256': sha256,
    'download_urls': <String>[
      'https://ghfast.top/https://github.com/kobe24o/SofterPlease/releases/download/v$version/app-release.apk',
      'https://github.com/kobe24o/SofterPlease/releases/download/v$version/app-release.apk',
    ],
    'notes': 'SofterPlease v$version',
    'file_name': 'app-release.apk',
    'package_name': 'com.softerplease.app',
    'signing_certificate_sha256': certificate,
  };
  final envelope = await buildSignedUpdateEnvelope(
    manifest: manifest,
    privateKeyBytes: base64Decode(privateKeyBase64),
  );
  final output = File(options['output']!);
  await output.parent.create(recursive: true);
  await output.writeAsString('$envelope\n', flush: true);
}

Map<String, String> _parseArguments(List<String> arguments) {
  final result = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    if (!arguments[index].startsWith('--') || index + 1 >= arguments.length) {
      throw ArgumentError('参数必须为 --名称 值');
    }
    result[arguments[index].substring(2)] = arguments[index + 1];
  }
  return result;
}
