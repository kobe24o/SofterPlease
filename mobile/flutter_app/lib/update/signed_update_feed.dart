import 'dart:convert';

import 'package:cryptography/cryptography.dart';

final class SignedUpdateFeed {
  const SignedUpdateFeed._();

  static Future<List<int>> verifyEnvelope(
    List<int> rawEnvelope, {
    required SimplePublicKey publicKey,
  }) async {
    final decoded = jsonDecode(utf8.decode(rawEnvelope));
    if (decoded is! Map || decoded['protocol'] != 1) {
      throw const FormatException('不支持的更新清单协议');
    }
    final payload = _base64Field(decoded, 'payload');
    final signature = _base64Field(decoded, 'signature');
    if (payload.isEmpty || signature.length != 64) {
      throw const FormatException('更新清单签名格式无效');
    }
    final verified = await Ed25519().verify(
      payload,
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!verified) {
      throw const FormatException('更新清单签名校验失败');
    }
    return payload;
  }

  static List<int> _base64Field(Map<dynamic, dynamic> json, String name) {
    final value = json[name];
    if (value is! String || value.isEmpty) {
      throw FormatException('更新清单缺少 $name');
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw FormatException('更新清单 $name 不是有效 Base64');
    }
  }
}
