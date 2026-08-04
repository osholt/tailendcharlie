import CryptoKit
import Flutter
import Security

/// Owns the protocol-2 installation keys. Private key bytes never cross the
/// Flutter channel; callers can only request public metadata, a signature, or
/// an X25519 shared secret.
final class InstallationIdentityBridge {
  static let channelName = "me.osholt.ride_relay/installation_identity"
  private static let identityLock = NSLock()
  private static var createdThisProcessKeyID: String?

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    Self.identityLock.lock()
    defer { Self.identityLock.unlock() }

    do {
      switch call.method {
      case "getOrCreate":
        let arguments = call.arguments as? [String: Any]
        let expectedKeyID = arguments?["expectedKeyId"] as? String
        result(try getOrCreate(expectedKeyID: expectedKeyID))
      case "sign":
        guard
          let arguments = call.arguments as? [String: Any],
          let expectedKeyID = arguments["keyId"] as? String,
          let data = (arguments["data"] as? FlutterStandardTypedData)?.data
        else {
          throw IdentityBridgeError.invalidArguments
        }
        let material = try requireIdentity(keyID: expectedKeyID)
        let signature = try material.signingPrivateKey.signature(for: data)
        result(FlutterStandardTypedData(bytes: signature))
      case "deriveSharedSecret":
        guard
          let arguments = call.arguments as? [String: Any],
          let expectedKeyID = arguments["keyId"] as? String,
          let peerBytes = (arguments["peerPublicKey"] as? FlutterStandardTypedData)?.data,
          peerBytes.count == 32
        else {
          throw IdentityBridgeError.invalidArguments
        }
        let material = try requireIdentity(keyID: expectedKeyID)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerBytes)
        let secret = try material.agreementPrivateKey.sharedSecretFromKeyAgreement(with: peer)
        result(FlutterStandardTypedData(bytes: secret.withUnsafeBytes { Data($0) }))
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as IdentityBridgeError {
      result(error.flutterError)
    } catch {
      result(
        FlutterError(
          code: "identity_operation_failed",
          message: "The installation identity operation failed.",
          details: nil
        )
      )
    }
  }

  private func getOrCreate(expectedKeyID: String?) throws -> [String: Any] {
    let loaded = loadStoredIdentity()

    switch loaded {
    case .valid(let material):
      let publicIdentity = PublicInstallationIdentity(material: material)
      if let expectedKeyID {
        if expectedKeyID == publicIdentity.keyID {
          return publicIdentity.channelValue(lifecycleEvent: "reused", identityChanged: false)
        }
        return try replaceIdentity(lifecycleEvent: "key_mismatch")
      }

      // A second Flutter engine can race the first bootstrap before Dart has
      // persisted the public record. Reuse only an identity made in this
      // process; a cold-start Keychain item without its public record is the
      // reinstall/database-mismatch case and must rotate.
      if Self.createdThisProcessKeyID == publicIdentity.keyID {
        return publicIdentity.channelValue(lifecycleEvent: "reused", identityChanged: false)
      }
      return try replaceIdentity(lifecycleEvent: "public_record_missing")
    case .missing:
      return try createIdentity(
        lifecycleEvent: expectedKeyID == nil ? "created" : "secure_material_missing",
        identityChanged: expectedKeyID != nil
      )
    case .corrupt:
      return try replaceIdentity(lifecycleEvent: "corrupt_secure_material")
    case .temporarilyUnavailable:
      throw IdentityBridgeError.secureStorageUnavailable
    }
  }

  private func replaceIdentity(lifecycleEvent: String) throws -> [String: Any] {
    try deleteStoredIdentity()
    return try createIdentity(lifecycleEvent: lifecycleEvent, identityChanged: true)
  }

  private func createIdentity(
    lifecycleEvent: String,
    identityChanged: Bool
  ) throws -> [String: Any] {
    let material = IdentityMaterial(
      signingPrivateKey: Curve25519.Signing.PrivateKey(),
      agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey()
    )
    try store(material)
    let publicIdentity = PublicInstallationIdentity(material: material)
    Self.createdThisProcessKeyID = publicIdentity.keyID
    return publicIdentity.channelValue(
      lifecycleEvent: lifecycleEvent,
      identityChanged: identityChanged
    )
  }

  private func requireIdentity(keyID: String) throws -> IdentityMaterial {
    let loaded = loadStoredIdentity()
    if case .temporarilyUnavailable = loaded {
      throw IdentityBridgeError.secureStorageUnavailable
    }
    guard case .valid(let material) = loaded else {
      throw IdentityBridgeError.identityUnavailable
    }
    guard PublicInstallationIdentity(material: material).keyID == keyID else {
      throw IdentityBridgeError.keyMismatch
    }
    return material
  }

  private func loadStoredIdentity() -> StoredIdentityLoadResult {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: KeychainRecord.service,
      kSecAttrAccount: KeychainRecord.account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return .missing }
    if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
      return .temporarilyUnavailable
    }
    guard status == errSecSuccess, let data = item as? Data else { return .corrupt }

    do {
      let record = try JSONDecoder().decode(KeychainRecord.self, from: data)
      guard record.schemaVersion == 1,
        record.signingPrivateKey.count == 32,
        record.agreementPrivateKey.count == 32
      else {
        return .corrupt
      }
      let material = IdentityMaterial(
        signingPrivateKey: try Curve25519.Signing.PrivateKey(
          rawRepresentation: record.signingPrivateKey
        ),
        agreementPrivateKey: try Curve25519.KeyAgreement.PrivateKey(
          rawRepresentation: record.agreementPrivateKey
        )
      )
      // Constructing the public identity also proves both private keys can be
      // used and their public encodings have the expected size.
      _ = PublicInstallationIdentity(material: material)
      return .valid(material)
    } catch {
      return .corrupt
    }
  }

  private func store(_ material: IdentityMaterial) throws {
    let record = KeychainRecord(
      schemaVersion: 1,
      signingPrivateKey: material.signingPrivateKey.rawRepresentation,
      agreementPrivateKey: material.agreementPrivateKey.rawRepresentation
    )
    let encoded = try JSONEncoder().encode(record)
    let attributes: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: KeychainRecord.service,
      kSecAttrAccount: KeychainRecord.account,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable: false,
      kSecValueData: encoded,
    ]
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else { throw IdentityBridgeError.secureStorageFailed }
  }

  private func deleteStoredIdentity() throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: KeychainRecord.service,
      kSecAttrAccount: KeychainRecord.account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw IdentityBridgeError.secureStorageFailed
    }
  }
}

private struct IdentityMaterial {
  let signingPrivateKey: Curve25519.Signing.PrivateKey
  let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
}

private enum StoredIdentityLoadResult {
  case missing
  case valid(IdentityMaterial)
  case corrupt
  case temporarilyUnavailable
}

private struct KeychainRecord: Codable {
  static let service = "app.tailendcharlie.protocol2.identity"
  static let account = "installation-identity-v1"

  let schemaVersion: Int
  let signingPrivateKey: Data
  let agreementPrivateKey: Data
}

private struct PublicInstallationIdentity {
  let keyID: String
  let fingerprint: String
  let signingPublicKey: Data
  let agreementPublicKey: Data

  init(material: IdentityMaterial) {
    signingPublicKey = material.signingPrivateKey.publicKey.rawRepresentation
    agreementPublicKey = material.agreementPrivateKey.publicKey.rawRepresentation
    keyID = Self.identifier(
      prefix: "p2k1_",
      label: "tailendcharlie.protocol2.signing-key-id.v1",
      publicKey: signingPublicKey,
      byteCount: 16
    )
    fingerprint = Self.identifier(
      prefix: "ifp1_",
      label: "tailendcharlie.installation-fingerprint.v1",
      publicKey: signingPublicKey,
      byteCount: 32
    )
  }

  func channelValue(lifecycleEvent: String, identityChanged: Bool) -> [String: Any] {
    [
      "schemaVersion": 1,
      "keyId": keyID,
      "installationFingerprint": fingerprint,
      "signingPublicKey": FlutterStandardTypedData(bytes: signingPublicKey),
      "encryptionPublicKey": FlutterStandardTypedData(bytes: agreementPublicKey),
      "storageProtection": "keychain_after_first_unlock_this_device_only",
      "hardwareBacked": false,
      "wrappedKeyFallback": true,
      "lifecycleEvent": lifecycleEvent,
      "identityChanged": identityChanged,
    ]
  }

  private static func identifier(
    prefix: String,
    label: String,
    publicKey: Data,
    byteCount: Int
  ) -> String {
    var input = Data(label.utf8)
    input.append(0)
    input.append(publicKey)
    let digest = Data(SHA256.hash(data: input)).prefix(byteCount)
    return prefix + Data(digest).base64URLEncodedString()
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private enum IdentityBridgeError: Error {
  case invalidArguments
  case identityUnavailable
  case keyMismatch
  case secureStorageFailed
  case secureStorageUnavailable

  var flutterError: FlutterError {
    switch self {
    case .invalidArguments:
      FlutterError(
        code: "invalid_arguments",
        message: "The installation identity request is invalid.",
        details: nil
      )
    case .identityUnavailable:
      FlutterError(
        code: "identity_unavailable",
        message: "The private installation identity is missing or corrupt.",
        details: nil
      )
    case .keyMismatch:
      FlutterError(
        code: "identity_key_mismatch",
        message: "The requested key does not match this installation identity.",
        details: nil
      )
    case .secureStorageFailed:
      FlutterError(
        code: "secure_storage_failed",
        message: "The installation identity could not be stored securely.",
        details: nil
      )
    case .secureStorageUnavailable:
      FlutterError(
        code: "secure_storage_unavailable",
        message: "Unlock the device before using its installation identity.",
        details: nil
      )
    }
  }
}
