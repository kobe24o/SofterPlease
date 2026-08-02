class UpdateManifest {
  UpdateManifest({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.sha256,
    required this.downloadUrls,
    required this.notes,
    required this.fileName,
    required this.packageName,
    required this.signingCertificateSha256,
  });

  final String version;
  final int buildNumber;
  final String platform;
  final String sha256;
  final List<Uri> downloadUrls;
  final String notes;
  final String fileName;
  final String packageName;
  final String signingCertificateSha256;

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version']?.toString().trim() ?? '';
    final buildNumber = json['build_number'];
    final platform = json['platform']?.toString().trim() ?? '';
    final sha256 = json['sha256']?.toString().trim().toLowerCase() ?? '';
    final rawUrls = json['download_urls'];
    final notes = json['notes']?.toString().trim() ?? '';
    final fileName = json['file_name']?.toString().trim() ?? '';
    final packageName = json['package_name']?.toString().trim() ?? '';
    final certificate =
        json['signing_certificate_sha256']?.toString().trim().toLowerCase() ??
            '';

    if (version.isEmpty || buildNumber is! num || buildNumber.toInt() <= 0) {
      throw const FormatException('更新清单缺少版本信息');
    }
    if (platform != 'android') {
      throw const FormatException('更新清单平台不匹配');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('更新清单缺少有效 SHA-256');
    }
    if (rawUrls is! List) {
      throw const FormatException('更新清单缺少下载地址');
    }
    final urls = rawUrls
        .map((value) => Uri.tryParse(value.toString().trim()))
        .whereType<Uri>()
        .where((uri) => uri.scheme == 'https' && uri.host.isNotEmpty)
        .toList(growable: false);
    if (urls.isEmpty) {
      throw const FormatException('更新清单没有安全下载地址');
    }

    return UpdateManifest(
      version: version,
      buildNumber: buildNumber.toInt(),
      platform: platform,
      sha256: sha256,
      downloadUrls: urls,
      notes: notes,
      fileName: fileName,
      packageName: packageName,
      signingCertificateSha256: certificate,
    );
  }

  bool isNewerThan({required int currentBuildNumber}) =>
      buildNumber > currentBuildNumber;

  String get preferredDownloadUrl => downloadUrls.first.toString();

  bool get isInstallable =>
      fileName.endsWith('.apk') &&
      packageName.isNotEmpty &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(signingCertificateSha256);
}
