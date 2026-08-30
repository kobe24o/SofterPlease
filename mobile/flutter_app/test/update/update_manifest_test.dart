import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:softerplease/update/update_service.dart';
import 'package:softerplease/update/update_manifest.dart';

void main() {
  test('accepts a newer Android update from the first allowed mirror', () {
    final manifest = UpdateManifest.fromJson({
      'version': '2.2.2',
      'build_number': 5,
      'platform': 'android',
      'sha256': 'a' * 64,
      'download_urls': [
        'https://ghfast.top/https://github.com/kobe24o/SofterPlease/releases/download/v2.2.2/softerplease.apk',
        'https://github.com/kobe24o/SofterPlease/releases/download/v2.2.2/softerplease.apk',
      ],
      'notes': '修复录音稳定性',
    });

    expect(manifest.isNewerThan(currentBuildNumber: 4), isTrue);
    expect(
      manifest.preferredDownloadUrl,
      'https://ghfast.top/https://github.com/kobe24o/SofterPlease/releases/download/v2.2.2/softerplease.apk',
    );
  });

  test('rejects insecure or malformed Android update manifests', () {
    expect(
      () => UpdateManifest.fromJson({
        'version': '2.2.2',
        'build_number': 5,
        'platform': 'android',
        'sha256': 'not-a-sha256',
        'download_urls': ['http://example.com/update.apk'],
      }),
      throwsFormatException,
    );
  });

  test('checks the next source when an earlier signed feed is stale', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final stale = await _signedFeed(algorithm, keyPair, buildNumber: 16);
    final newer = await _signedFeed(algorithm, keyPair, buildNumber: 17);
    final sources = [
      Uri.parse('https://cdn.example.test/latest.json'),
      Uri.parse('https://github.example.test/latest.json'),
    ];

    final result = await UpdateService(
      feedSources: sources,
      publicKeyBase64: base64Encode(publicKey.bytes),
      fetchFeed: (source) async =>
          source.host.startsWith('cdn') ? stale : newer,
    ).check(currentBuildNumber: 16);

    expect(result.hasUpdate, isTrue);
    expect(result.manifest?.buildNumber, 17);
  });
}

Future<List<int>> _signedFeed(
  Ed25519 algorithm,
  KeyPair keyPair, {
  required int buildNumber,
}) async {
  final payload = utf8.encode(jsonEncode({
    'version': '2.${buildNumber - 14}.0',
    'build_number': buildNumber,
    'platform': 'android',
    'sha256': 'a' * 64,
    'download_urls': ['https://github.example.test/app-release.apk'],
    'notes': 'test',
    'file_name': 'app-release.apk',
    'package_name': 'com.softerplease.app',
    'signing_certificate_sha256': 'b' * 64,
  }));
  final signature = await algorithm.sign(payload, keyPair: keyPair);
  return utf8.encode(jsonEncode({
    'protocol': 1,
    'payload': base64Encode(payload),
    'signature': base64Encode(signature.bytes),
  }));
}
