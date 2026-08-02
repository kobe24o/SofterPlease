import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Creates the signed envelope consumed by the Android update client.
///
/// The payload is deliberately encoded once before signing: clients verify the
/// exact bytes rather than a re-serialized JSON object.
Future<String> buildSignedUpdateEnvelope({
  required Map<String, Object> manifest,
  required List<int> privateKeyBytes,
}) async {
  if (privateKeyBytes.length != 32) {
    throw const FormatException('Ed25519 私钥必须是 32 字节');
  }
  final payload = utf8.encode(jsonEncode(manifest));
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(privateKeyBytes);
  final signature = await algorithm.sign(payload, keyPair: keyPair);
  return jsonEncode({
    'protocol': 1,
    'payload': base64Encode(payload),
    'signature': base64Encode(signature.bytes),
  });
}
