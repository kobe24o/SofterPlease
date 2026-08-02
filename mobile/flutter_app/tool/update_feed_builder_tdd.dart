import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:softerplease/update/signed_update_feed.dart';
import 'update_feed_builder.dart';

Future<void> main() async {
  final algorithm = Ed25519();
  final pair = await algorithm.newKeyPair();
  final pairData = await pair.extract();
  final publicKey = await pair.extractPublicKey();
  final envelope = await buildSignedUpdateEnvelope(
    manifest: <String, Object>{'version': '2.2.5', 'build_number': 8},
    privateKeyBytes: pairData.bytes,
  );
  final payload = await SignedUpdateFeed.verifyEnvelope(
    utf8.encode(envelope),
    publicKey: publicKey,
  );
  final manifest = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
  if (manifest['version'] != '2.2.5' || manifest['build_number'] != 8) {
    throw StateError('signed envelope payload changed unexpectedly');
  }
}
