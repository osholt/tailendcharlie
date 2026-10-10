import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'installation_identity.dart';

abstract interface class InstallationIdentityPlatformBridge {
  Future<Map<Object?, Object?>> getOrCreate({String? expectedKeyId});

  Future<Uint8List> sign({required String keyId, required Uint8List data});

  Future<Uint8List> deriveSharedSecret({
    required String keyId,
    required Uint8List peerPublicKey,
  });
}

final class NativeInstallationIdentityBridge
    implements InstallationIdentityPlatformBridge {
  const NativeInstallationIdentityBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'me.osholt.ride_relay/installation_identity';
  final MethodChannel _channel;

  @override
  Future<Map<Object?, Object?>> getOrCreate({String? expectedKeyId}) async {
    final value = await _channel.invokeMethod<Object?>('getOrCreate', {
      'expectedKeyId': expectedKeyId,
    });
    if (value is! Map) {
      throw const FormatException('Native identity response was not a map.');
    }
    return Map<Object?, Object?>.from(value);
  }

  @override
  Future<Uint8List> sign({
    required String keyId,
    required Uint8List data,
  }) async {
    final value = await _channel.invokeMethod<Object?>('sign', {
      'keyId': keyId,
      'data': data,
    });
    if (value is! Uint8List || value.length != 64) {
      throw const FormatException('Native Ed25519 signature was invalid.');
    }
    return Uint8List.fromList(value);
  }

  @override
  Future<Uint8List> deriveSharedSecret({
    required String keyId,
    required Uint8List peerPublicKey,
  }) async {
    if (peerPublicKey.length != 32) {
      throw const FormatException('X25519 peer public key must be 32 bytes.');
    }
    final value = await _channel.invokeMethod<Object?>('deriveSharedSecret', {
      'keyId': keyId,
      'peerPublicKey': peerPublicKey,
    });
    if (value is! Uint8List || value.length != 32) {
      throw const FormatException('Native X25519 shared secret was invalid.');
    }
    return Uint8List.fromList(value);
  }
}

abstract interface class InstallationIdentityMetadataStore {
  Future<InstallationIdentityPublicRecord?> load();

  Future<void> save(InstallationIdentityPublicRecord record);

  Future<void> delete();
}

final class SharedPreferencesInstallationIdentityMetadataStore
    implements InstallationIdentityMetadataStore {
  const SharedPreferencesInstallationIdentityMetadataStore();

  static const _key = 'ride_relay_protocol2_identity_public_v1';

  @override
  Future<InstallationIdentityPublicRecord?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_key);
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) throw const FormatException();
      return InstallationIdentityPublicRecord.fromJson(
        Map<String, Object?>.from(value),
      );
    } on Object {
      await preferences.remove(_key);
      return null;
    }
  }

  @override
  Future<void> save(InstallationIdentityPublicRecord record) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(_key, jsonEncode(record.toJson()))) {
      throw StateError(
        'The installation identity public record was not saved.',
      );
    }
  }

  @override
  Future<void> delete() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key);
  }
}

/// Coordinates the ordinary public record with the native private identity.
///
/// This service is intentionally not wired into protocol 1. Protocol-2
/// negotiation will call it only after the rest of the migration gate lands.
final class InstallationIdentityRepository {
  InstallationIdentityRepository({
    InstallationIdentityPlatformBridge? bridge,
    InstallationIdentityMetadataStore? metadataStore,
  }) : _bridge = bridge ?? const NativeInstallationIdentityBridge(),
       _metadataStore =
           metadataStore ??
           const SharedPreferencesInstallationIdentityMetadataStore();

  final InstallationIdentityPlatformBridge _bridge;
  final InstallationIdentityMetadataStore _metadataStore;
  Future<InstallationIdentity>? _pendingLoad;

  Future<InstallationIdentity> getOrCreate() {
    final pending = _pendingLoad;
    if (pending != null) return pending;
    final future = _loadIdentityAndClear();
    _pendingLoad = future;
    return future;
  }

  Future<InstallationIdentity> _loadIdentityAndClear() async {
    try {
      return await _loadIdentity();
    } finally {
      _pendingLoad = null;
    }
  }

  Future<InstallationIdentity> _loadIdentity() async {
    final publicRecord = await _metadataStore.load();
    final value = await _bridge.getOrCreate(expectedKeyId: publicRecord?.keyId);
    final identity = InstallationIdentity.fromChannelValue(value);
    await _metadataStore.save(identity.publicRecord);
    return identity;
  }

  Future<Uint8List> sign(InstallationIdentity identity, Uint8List data) =>
      _bridge.sign(keyId: identity.keyId, data: data);

  Future<Uint8List> deriveSharedSecret(
    InstallationIdentity identity,
    Uint8List peerPublicKey,
  ) => _bridge.deriveSharedSecret(
    keyId: identity.keyId,
    peerPublicKey: peerPublicKey,
  );
}
