import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import '../lib/update/signed_update_feed.dart';

Future<void> main() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final payload = utf8.encode('{"build_number":5}');
  final signature = await algorithm.sign(payload, keyPair: keyPair);
  final envelope = utf8.encode(jsonEncode({
    'protocol': 1,
    'payload': base64Encode(payload),
    'signature': base64Encode(signature.bytes),
  }));

  final verified = await SignedUpdateFeed.verifyEnvelope(
    envelope,
    publicKey: publicKey,
  );

  if (utf8.decode(verified) != '{"build_number":5}') {
    throw StateError('verified update payload was not returned');
  }
}
