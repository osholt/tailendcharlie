import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/security/installation_identity.dart';
import 'package:ride_relay/security/installation_identity_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InstallationIdentity', () {
    test('accepts only public, versioned identity metadata', () {
      final identity = InstallationIdentity.fromChannelValue(_identityValue());

      expect(identity.keyId, startsWith('p2k1_'));
      expect(identity.installationFingerprint, startsWith('ifp1_'));
      expect(identity.signingPublicKey, hasLength(32));
      expect(identity.encryptionPublicKey, hasLength(32));
      expect(identity.requiresReinvitation, isFalse);
    });

    test('rejects any native response containing private material', () {
      final value = _identityValue()..['signingPrivateKey'] = Uint8List(32);

      expect(
        () => InstallationIdentity.fromChannelValue(value),
        throwsFormatException,
      );
    });

    test('rejects a key ID that does not match the signing public key', () {
      final value = _identityValue();
      value['signingPublicKey'] = Uint8List(32);

      expect(
        () => InstallationIdentity.fromChannelValue(value),
        throwsFormatException,
      );
    });
  });

  group('InstallationIdentityRepository', () {
    test(
      'creates and persists the public record, then reopens by key ID',
      () async {
        final bridge = _FakeBridge();
        final store = _MemoryMetadataStore();
        final repository = InstallationIdentityRepository(
          bridge: bridge,
          metadataStore: store,
        );

        final first = await repository.getOrCreate();
        final reopened = await repository.getOrCreate();

        expect(first.keyId, reopened.keyId);
        expect(bridge.expectedKeyIds, [null, first.keyId]);
        expect(store.record?.keyId, first.keyId);
      },
    );

    test('coalesces concurrent first use into one native generation', () async {
      final bridge = _FakeBridge(delay: const Duration(milliseconds: 10));
      final repository = InstallationIdentityRepository(
        bridge: bridge,
        metadataStore: _MemoryMetadataStore(),
      );

      final identities = await Future.wait([
        repository.getOrCreate(),
        repository.getOrCreate(),
        repository.getOrCreate(),
      ]);

      expect(bridge.expectedKeyIds, [null]);
      expect(identities.map((value) => value.keyId).toSet(), hasLength(1));
    });

    test('surfaces native rotation as requiring a new invitation', () async {
      final previous = InstallationIdentityPublicRecord.fromJson(
        _publicRecordJson(),
      );
      final store = _MemoryMetadataStore(previous);
      final bridge = _FakeBridge(
        response: _identityValue(
          keySeed: 9,
          lifecycleEvent: 'secure_material_missing',
          identityChanged: true,
        ),
      );
      final repository = InstallationIdentityRepository(
        bridge: bridge,
        metadataStore: store,
      );

      final identity = await repository.getOrCreate();

      expect(bridge.expectedKeyIds, [previous.keyId]);
      expect(identity.requiresReinvitation, isTrue);
      expect(identity.lifecycleEvent, 'secure_material_missing');
      expect(store.record?.keyId, identity.keyId);
      expect(store.record?.keyId, isNot(previous.keyId));
    });

    test(
      'forwards signing and agreement without exposing private keys',
      () async {
        final bridge = _FakeBridge();
        final repository = InstallationIdentityRepository(
          bridge: bridge,
          metadataStore: _MemoryMetadataStore(),
        );
        final identity = await repository.getOrCreate();

        expect(
          await repository.sign(identity, Uint8List.fromList([1, 2, 3])),
          hasLength(64),
        );
        expect(
          await repository.deriveSharedSecret(identity, Uint8List(32)),
          hasLength(32),
        );
        expect(bridge.operationKeyIds, [identity.keyId, identity.keyId]);
      },
    );
  });

  group('SharedPreferencesInstallationIdentityMetadataStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round trips public metadata only', () async {
      const store = SharedPreferencesInstallationIdentityMetadataStore();
      final record = InstallationIdentityPublicRecord.fromJson(
        _publicRecordJson(),
      );

      await store.save(record);
      final restored = await store.load();

      expect(restored?.keyId, record.keyId);
      final preferences = await SharedPreferences.getInstance();
      final encoded = preferences.getString(
        'ride_relay_protocol2_identity_public_v1',
      );
      expect(encoded, isNot(contains('private')));
    });

    test(
      'deletes a corrupt public record so native code rotates safely',
      () async {
        SharedPreferences.setMockInitialValues({
          'ride_relay_protocol2_identity_public_v1': '{bad json',
        });
        const store = SharedPreferencesInstallationIdentityMetadataStore();

        expect(await store.load(), isNull);
        final preferences = await SharedPreferences.getInstance();
        expect(
          preferences.containsKey('ride_relay_protocol2_identity_public_v1'),
          isFalse,
        );
      },
    );
  });

  testWidgets('method channel exposes only bounded operations', (tester) async {
    const channel = MethodChannel(
      'me.osholt.ride_relay/installation_identity.test',
    );
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'getOrCreate' => _identityValue(),
        'sign' => Uint8List(64),
        'deriveSharedSecret' => Uint8List(32),
        _ => null,
      };
    });
    const bridge = NativeInstallationIdentityBridge(channel: channel);

    final value = await bridge.getOrCreate(expectedKeyId: null);
    final identity = InstallationIdentity.fromChannelValue(value);
    await bridge.sign(keyId: identity.keyId, data: Uint8List(1));
    await bridge.deriveSharedSecret(
      keyId: identity.keyId,
      peerPublicKey: Uint8List(32),
    );

    expect(calls.map((call) => call.method), [
      'getOrCreate',
      'sign',
      'deriveSharedSecret',
    ]);
    expect(
      calls.expand((call) => (call.arguments as Map).keys),
      isNot(contains('privateKey')),
    );
  });
}

Map<Object?, Object?> _identityValue({
  int keySeed = 1,
  String lifecycleEvent = 'created',
  bool identityChanged = false,
}) {
  final signingPublicKey = Uint8List.fromList(
    List<int>.generate(32, (index) => (keySeed + index) & 0xff),
  );
  return {
    'schemaVersion': 1,
    'keyId': _identifier(
      'p2k1_',
      'tailendcharlie.protocol2.signing-key-id.v1',
      signingPublicKey,
      16,
    ),
    'installationFingerprint': _identifier(
      'ifp1_',
      'tailendcharlie.installation-fingerprint.v1',
      signingPublicKey,
      32,
    ),
    'signingPublicKey': signingPublicKey,
    'encryptionPublicKey': Uint8List.fromList(
      List<int>.generate(32, (index) => (keySeed + index + 32) & 0xff),
    ),
    'storageProtection': 'test_secure_storage',
    'hardwareBacked': false,
    'wrappedKeyFallback': true,
    'lifecycleEvent': lifecycleEvent,
    'identityChanged': identityChanged,
  };
}

Map<String, Object?> _publicRecordJson() {
  final identity = InstallationIdentity.fromChannelValue(_identityValue());
  return identity.publicRecord.toJson();
}

String _identifier(
  String prefix,
  String label,
  Uint8List publicKey,
  int byteCount,
) {
  final digest = sha256
      .convert([...label.codeUnits, 0, ...publicKey])
      .bytes
      .take(byteCount)
      .toList(growable: false);
  return '$prefix${base64UrlEncode(digest).replaceAll('=', '')}';
}

final class _FakeBridge implements InstallationIdentityPlatformBridge {
  _FakeBridge({Map<Object?, Object?>? response, this.delay = Duration.zero})
    : response = response ?? _identityValue();

  final Map<Object?, Object?> response;
  final Duration delay;
  final List<String?> expectedKeyIds = [];
  final List<String> operationKeyIds = [];

  @override
  Future<Map<Object?, Object?>> getOrCreate({String? expectedKeyId}) async {
    expectedKeyIds.add(expectedKeyId);
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    return Map<Object?, Object?>.from(response);
  }

  @override
  Future<Uint8List> sign({
    required String keyId,
    required Uint8List data,
  }) async {
    operationKeyIds.add(keyId);
    return Uint8List(64);
  }

  @override
  Future<Uint8List> deriveSharedSecret({
    required String keyId,
    required Uint8List peerPublicKey,
  }) async {
    operationKeyIds.add(keyId);
    return Uint8List(32);
  }
}

final class _MemoryMetadataStore implements InstallationIdentityMetadataStore {
  _MemoryMetadataStore([this.record]);

  InstallationIdentityPublicRecord? record;

  @override
  Future<void> delete() async => record = null;

  @override
  Future<InstallationIdentityPublicRecord?> load() async => record;

  @override
  Future<void> save(InstallationIdentityPublicRecord value) async {
    record = value;
  }
}
