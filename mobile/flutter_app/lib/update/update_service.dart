import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'signed_update_feed.dart';
import 'update_manifest.dart';

const _defaultFeedSources = <String>[
  'https://fastly.jsdelivr.net/gh/kobe24o/SofterPlease@update-feed/updates/latest.json',
  'https://raw.githubusercontent.com/kobe24o/SofterPlease/update-feed/updates/latest.json',
];

const _defaultPublicKeyBase64 =
    String.fromEnvironment('UPDATE_PUBLIC_KEY_BASE64');

typedef FetchUpdateFeed = Future<List<int>> Function(Uri source);

final class UpdateCheckResult {
  const UpdateCheckResult.current()
      : manifest = null,
        error = null;
  const UpdateCheckResult.available(this.manifest) : error = null;
  const UpdateCheckResult.unavailable(this.error) : manifest = null;

  final UpdateManifest? manifest;
  final String? error;
  bool get hasUpdate => manifest != null;
}

final class UpdateService {
  UpdateService({
    Dio? dio,
    List<Uri>? feedSources,
    String? publicKeyBase64,
    FetchUpdateFeed? fetchFeed,
  })  : _dio = dio ?? Dio(),
        _feedSources = feedSources ??
            _defaultFeedSources.map(Uri.parse).toList(growable: false),
        _publicKeyBase64 = publicKeyBase64 ?? _defaultPublicKeyBase64,
        _fetchFeed = fetchFeed;

  final Dio _dio;
  final List<Uri> _feedSources;
  final String _publicKeyBase64;
  final FetchUpdateFeed? _fetchFeed;

  Future<UpdateCheckResult> check({required int currentBuildNumber}) async {
    if (_publicKeyBase64.isEmpty) {
      return const UpdateCheckResult.unavailable('更新签名尚未配置');
    }
    final publicKey = _readPublicKey();
    final failures = <String>[];
    var sawValidManifest = false;
    for (final source in _feedSources) {
      try {
        final payload = await SignedUpdateFeed.verifyEnvelope(
          await _readFeed(source),
          publicKey: publicKey,
        );
        final decoded = jsonDecode(utf8.decode(payload));
        if (decoded is! Map) throw const FormatException('更新清单不是对象');
        final manifest = UpdateManifest.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (!manifest.isInstallable) {
          throw const FormatException('更新包身份信息不完整');
        }
        sawValidManifest = true;
        if (manifest.isNewerThan(currentBuildNumber: currentBuildNumber)) {
          return UpdateCheckResult.available(manifest);
        }
      } catch (error) {
        failures.add(error.toString());
      }
    }
    if (sawValidManifest) return const UpdateCheckResult.current();
    return UpdateCheckResult.unavailable('检查更新失败：${failures.join('；')}');
  }

  Future<File> download(UpdateManifest manifest) async {
    final root = await getTemporaryDirectory();
    final directory = Directory('${root.path}${Platform.pathSeparator}updates');
    await directory.create(recursive: true);
    final destination =
        File('${directory.path}${Platform.pathSeparator}${manifest.fileName}');
    final partial = File('${destination.path}.part');
    Object? lastError;
    for (final url in manifest.downloadUrls) {
      try {
        await _deleteIfExists(partial);
        await _dio.download(url.toString(), partial.path);
        await _verifyHash(partial, manifest.sha256);
        if (await destination.exists()) await destination.delete();
        return partial.rename(destination.path);
      } catch (error) {
        lastError = error;
      }
    }
    await _deleteIfExists(partial);
    throw StateError('更新下载或校验失败：$lastError');
  }

  SimplePublicKey _readPublicKey() {
    try {
      final bytes = base64Decode(_publicKeyBase64);
      if (bytes.length != 32) throw const FormatException();
      return SimplePublicKey(bytes, type: KeyPairType.ed25519);
    } on FormatException {
      throw StateError('更新公钥配置无效');
    }
  }

  Future<List<int>> _readFeed(Uri source) async {
    final fetchFeed = _fetchFeed;
    if (fetchFeed != null) return fetchFeed(source);
    final response = await _dio.get<List<int>>(
      source.toString(),
      options: Options(responseType: ResponseType.bytes),
    );
    return List<int>.from(response.data ?? const []);
  }

  Future<void> _verifyHash(File file, String expected) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final digest = await sink.hash();
    final actual = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (actual != expected) {
      await _deleteIfExists(file);
      throw const FormatException('更新包 SHA-256 校验失败');
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }
}
