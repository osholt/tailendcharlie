import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Public half of the protocol-2 identity for one app installation.
///
/// Private keys never enter Dart. [identityChanged] tells the future protocol-2
/// membership layer that old certificates must not be reused and the rider
/// must be invited again.
final class InstallationIdentity {
  InstallationIdentity({
    required this.keyId,
    required this.installationFingerprint,
    required Uint8List signingPublicKey,
    required Uint8List encryptionPublicKey,
    required this.storageProtection,
    required this.hardwareBacked,
    required this.wrappedKeyFallback,
    required this.lifecycleEvent,
    required this.identityChanged,
  }) : signingPublicKey = Uint8List.fromList(signingPublicKey),
       encryptionPublicKey = Uint8List.fromList(encryptionPublicKey);

  static final _keyIdPattern = RegExp(r'^p2k1_[A-Za-z0-9_-]{22}$');
  static final _fingerprintPattern = RegExp(r'^ifp1_[A-Za-z0-9_-]{43}$');

  final String keyId;
  final String installationFingerprint;
  final Uint8List signingPublicKey;
  final Uint8List encryptionPublicKey;
  final String storageProtection;
  final bool hardwareBacked;
  final bool wrappedKeyFallback;
  final String lifecycleEvent;
  final bool identityChanged;

  bool get requiresReinvitation => identityChanged;

  factory InstallationIdentity.fromChannelValue(Map<Object?, Object?> value) {
    const forbiddenPrivateFields = {
      'privateKey',
      'signingPrivateKey',
      'encryptionPrivateKey',
      'agreementPrivateKey',
      'wrappedPrivateMaterial',
    };
    if (value.keys.any(forbiddenPrivateFields.contains)) {
      throw const FormatException(
        'The native identity bridge exposed private key material.',
      );
    }
    if (value['schemaVersion'] != 1) {
      throw const FormatException('Unsupported installation identity schema.');
    }

    final keyId = value['keyId'];
    final fingerprint = value['installationFingerprint'];
    final signingPublicKey = value['signingPublicKey'];
    final encryptionPublicKey = value['encryptionPublicKey'];
    final storageProtection = value['storageProtection'];
    final hardwareBacked = value['hardwareBacked'];
    final wrappedKeyFallback = value['wrappedKeyFallback'];
    final lifecycleEvent = value['lifecycleEvent'];
    final identityChanged = value['identityChanged'];
    if (keyId is! String || !_keyIdPattern.hasMatch(keyId)) {
      throw const FormatException('Invalid installation signing key ID.');
    }
    if (fingerprint is! String || !_fingerprintPattern.hasMatch(fingerprint)) {
      throw const FormatException('Invalid installation fingerprint.');
    }
    if (signingPublicKey is! Uint8List || signingPublicKey.length != 32) {
      throw const FormatException('Invalid Ed25519 public key.');
    }
    if (encryptionPublicKey is! Uint8List || encryptionPublicKey.length != 32) {
      throw const FormatException('Invalid X25519 public key.');
    }
    if (keyId !=
            _identifier(
              prefix: 'p2k1_',
              label: 'tailendcharlie.protocol2.signing-key-id.v1',
              publicKey: signingPublicKey,
              byteCount: 16,
            ) ||
        fingerprint !=
            _identifier(
              prefix: 'ifp1_',
              label: 'tailendcharlie.installation-fingerprint.v1',
              publicKey: signingPublicKey,
              byteCount: 32,
            )) {
      throw const FormatException(
        'Installation identity digest does not match its public key.',
      );
    }
    if (storageProtection is! String || storageProtection.isEmpty) {
      throw const FormatException('Invalid secure-storage description.');
    }
    if (hardwareBacked is! bool ||
        wrappedKeyFallback is! bool ||
        lifecycleEvent is! String ||
        lifecycleEvent.isEmpty ||
        identityChanged is! bool) {
      throw const FormatException('Invalid installation identity metadata.');
    }
    return InstallationIdentity(
      keyId: keyId,
      installationFingerprint: fingerprint,
      signingPublicKey: signingPublicKey,
      encryptionPublicKey: encryptionPublicKey,
      storageProtection: storageProtection,
      hardwareBacked: hardwareBacked,
      wrappedKeyFallback: wrappedKeyFallback,
      lifecycleEvent: lifecycleEvent,
      identityChanged: identityChanged,
    );
  }

  InstallationIdentityPublicRecord get publicRecord =>
      InstallationIdentityPublicRecord(
        keyId: keyId,
        installationFingerprint: installationFingerprint,
        signingPublicKey: signingPublicKey,
        encryptionPublicKey: encryptionPublicKey,
      );

  static String _identifier({
    required String prefix,
    required String label,
    required Uint8List publicKey,
    required int byteCount,
  }) {
    final digest = sha256
        .convert([...utf8.encode(label), 0, ...publicKey])
        .bytes
        .take(byteCount)
        .toList(growable: false);
    return '$prefix${base64UrlEncode(digest).replaceAll('=', '')}';
  }
}

/// Non-secret local record used to detect a database/private-key mismatch.
final class InstallationIdentityPublicRecord {
  InstallationIdentityPublicRecord({
    required this.keyId,
    required this.installationFingerprint,
    required Uint8List signingPublicKey,
    required Uint8List encryptionPublicKey,
  }) : signingPublicKey = Uint8List.fromList(signingPublicKey),
       encryptionPublicKey = Uint8List.fromList(encryptionPublicKey);

  final String keyId;
  final String installationFingerprint;
  final Uint8List signingPublicKey;
  final Uint8List encryptionPublicKey;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'keyId': keyId,
    'installationFingerprint': installationFingerprint,
    'signingPublicKey': base64UrlEncode(signingPublicKey).replaceAll('=', ''),
    'encryptionPublicKey': base64UrlEncode(
      encryptionPublicKey,
    ).replaceAll('=', ''),
  };

  factory InstallationIdentityPublicRecord.fromJson(
    Map<String, Object?> value,
  ) {
    if (value['schemaVersion'] != 1 ||
        value['keyId'] is! String ||
        value['installationFingerprint'] is! String ||
        value['signingPublicKey'] is! String ||
        value['encryptionPublicKey'] is! String) {
      throw const FormatException('Invalid identity public record.');
    }
    final signingPublicKey = _decodeKey(value['signingPublicKey']! as String);
    final encryptionPublicKey = _decodeKey(
      value['encryptionPublicKey']! as String,
    );
    // Reuse the channel parser as the single strict format boundary.
    final identity = InstallationIdentity.fromChannelValue({
      'schemaVersion': 1,
      'keyId': value['keyId'],
      'installationFingerprint': value['installationFingerprint'],
      'signingPublicKey': signingPublicKey,
      'encryptionPublicKey': encryptionPublicKey,
      'storageProtection': 'local_public_record',
      'hardwareBacked': false,
      'wrappedKeyFallback': false,
      'lifecycleEvent': 'stored',
      'identityChanged': false,
    });
    return identity.publicRecord;
  }

  static Uint8List _decodeKey(String value) {
    try {
      return Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
    } on FormatException {
      throw const FormatException('Invalid identity public key encoding.');
    }
  }
}
