import 'package:flutter_test/flutter_test.dart';
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
}
