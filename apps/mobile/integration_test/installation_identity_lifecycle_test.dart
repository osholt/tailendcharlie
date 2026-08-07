// Simulator/device harness for protocol-2 installation identity (#332).
//
// Run on each target platform with:
//
//   flutter test integration_test/installation_identity_lifecycle_test.dart \
//     -d <device-id>
//
// This intentionally prints no keys, signatures, shared secrets or stable
// fingerprints. Physical lock/background/reinstall evidence remains manual.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ride_relay/security/installation_identity_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('creates, operates and reopens the native identity', (
    tester,
  ) async {
    final firstRepository = InstallationIdentityRepository();
    final first = await firstRepository.getOrCreate();

    final signature = await firstRepository.sign(
      first,
      Uint8List.fromList('tailendcharlie identity integration test'.codeUnits),
    );
    final sharedSecret = await firstRepository.deriveSharedSecret(
      first,
      _hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'),
    );
    final reopened = await InstallationIdentityRepository().getOrCreate();

    expect(signature, hasLength(64));
    expect(sharedSecret, hasLength(32));
    expect(reopened.keyId, first.keyId);
    expect(reopened.lifecycleEvent, 'reused');
    expect(reopened.identityChanged, isFalse);
    expect(
      first.storageProtection,
      anyOf(
        'keychain_after_first_unlock_this_device_only',
        'android_keystore_non_exportable_curve25519',
        'android_keystore_hardware_wrapped_curve25519',
        'android_keystore_software_wrapped_curve25519',
      ),
    );
    debugPrint(
      'IDENTITY EVIDENCE storage=${first.storageProtection} '
      'hardware=${first.hardwareBacked} '
      'wrappedFallback=${first.wrappedKeyFallback} '
      'reopen=${reopened.lifecycleEvent}',
    );
  });
}

Uint8List _hex(String value) => Uint8List.fromList([
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
]);
