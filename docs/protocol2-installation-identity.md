# Protocol-2 installation identity

Status: implemented behind the protocol-2 migration gate for issue #332. It is
not used by protocol 1, published to the relay, or evidence that protocol 2 is
ready for public rides.

## Public identity

Each installation has independent Ed25519 signing and X25519 recipient keys.
The native bridge exposes only:

- the two 32-byte public keys;
- `p2k1_` plus the first 16 bytes of
  `SHA-256("tailendcharlie.protocol2.signing-key-id.v1" || 0x00 ||
  signing_public_key)`;
- `ifp1_` plus all 32 bytes of
  `SHA-256("tailendcharlie.installation-fingerprint.v1" || 0x00 ||
  signing_public_key)`; and
- honest storage-protection and lifecycle metadata.

Both digests use unpadded base64url. Ordinary ride, relay and watcher records
must use a separate ride-scoped rider ID; the installation fingerprint is not
an analytics or routing identifier.

The only private-key operations exposed to Dart are Ed25519 signing and X25519
key agreement. The bridge accepts the expected key ID on every operation and
fails closed if the stored key no longer matches.

## iOS storage

CryptoKit's Curve25519 keys have no native `SecKey` Keychain representation.
Their raw private representations are therefore stored as a generic-password
Keychain item with:

- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so an active ride can use
  the keys in the background after the first device unlock;
- synchronisation disabled; and
- an app-specific service and account.

This is the documented Keychain-protected blob fallback, not a Secure Enclave
or non-exportable-key claim. The bytes are never logged, backed up, returned by
the Flutter channel or written to the app database.

## Android storage

On Android 12 and later the bridge first attempts to generate both Ed25519 and
X25519 directly inside `AndroidKeyStore`. It accepts that path only if both
keys can be generated and pass an Ed25519 signature plus an X25519 agreement
self-test. A partially supported pair is deleted.

Android's documented Keystore algorithm set does not guarantee either curve.
The portable fallback therefore:

1. generates both curve keys with Bouncy Castle's low-level Ed25519/X25519
   implementations;
2. concatenates the versioned private material only in process memory;
3. encrypts it with AES-256-GCM under an app-scoped, non-exportable
   `AndroidKeyStore` AES key; and
4. stores only the IV and authenticated ciphertext in private app storage.

The bridge reports whether that AES wrapper is hardware-backed. A software
Keystore result remains protected by the platform boundary but is not
described as hardware-backed.

## Reinstall and mismatch behaviour

The app stores a second, non-secret public record in ordinary app preferences.
On each open, its key ID is passed to native storage:

- matching public and private records reopen the same identity;
- a missing, corrupt or different private record rotates the identity;
- a native identity with no public record on a cold launch also rotates, which
  handles iOS Keychain material that happened to survive uninstall; and
- simultaneous first use in one process is coalesced without a second rotate.

Rotation returns `identityChanged: true` and a bounded lifecycle reason. The
future protocol-2 membership layer must invalidate local membership and require
a new invitation whenever that flag is true. No cloud restore or hidden
identity recovery is attempted.

## Evidence still required

Automated tests cover public-record create/reopen, concurrent first use,
missing/corrupt metadata, key mismatch, bounded channel data, signature length
and shared-secret length. Before #332 can close, record physical evidence for:

1. oldest supported iOS: create, force quit/reopen, first-unlock background
   signing, device lock and app reinstall;
2. oldest supported Android: create, force stop/reopen, background signing,
   clear app data and reinstall;
3. one Android device reporting a hardware-backed AES wrapper and one device
   reporting the software-backed fallback, if representative hardware is
   available; and
4. concurrent cold-start access from the main and background Flutter engines.

Never paste key blobs, signatures over real ride data, or unredacted identity
records into an issue or test log. Record only key-ID continuity/change,
storage-protection labels, operation success and OS/device model.
