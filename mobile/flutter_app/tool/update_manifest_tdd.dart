import 'package:softerplease/update/update_manifest.dart';

void main() {
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
  if (!manifest.isNewerThan(currentBuildNumber: 4)) {
    throw StateError('newer release must be offered');
  }
  if (!manifest.preferredDownloadUrl.startsWith('https://ghfast.top/')) {
    throw StateError('the accelerated mirror must keep priority');
  }
  if (manifest.isInstallable) {
    throw StateError('a manifest without APK identity must not be installable');
  }

  try {
    UpdateManifest.fromJson({
      'version': '2.2.2',
      'build_number': 5,
      'platform': 'android',
      'sha256': 'invalid',
      'download_urls': ['http://example.com/update.apk'],
    });
    throw StateError('insecure manifests must be rejected');
  } on FormatException {
    // Expected.
  }
}
