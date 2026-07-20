import CarPlay
import Flutter
import NearbyConnections
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nearbyChannel: FlutterMethodChannel?
  private var nearbyEventChannel: FlutterEventChannel?
  private var nearbyEventSink: FlutterEventSink?
  private var connectionManager: ConnectionManager?
  private var advertiser: Advertiser?
  private var discoverer: Discoverer?
  private var connectedPeers = Set<EndpointID>()
  private var pendingPeers = Set<EndpointID>()
  private var gpxImportChannel: FlutterMethodChannel?
  private var pendingGpxImport: (data: Data, fileName: String)?
  private var carPlayChannel: FlutterMethodChannel?
  private var latestCarPlaySnapshot: [String: Any]?
  weak var carPlayListTemplate: CPListTemplate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "me.osholt.ride_relay/nearby",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getCapabilities":
        result([
          "platform": "ios",
          "nativeBridgeReady": true,
          "nearbyApiLinked": true,
          "status": "hardwareValidationRequired",
        ])
      case "requestPermissions":
        // iOS presents Bluetooth/local-network consent when discovery starts.
        result(true)
      case "start":
        guard
          let arguments = call.arguments as? [String: Any],
          let serviceID = arguments["serviceId"] as? String,
          let endpointName = arguments["endpointName"] as? String
        else {
          result(FlutterError(code: "invalid_arguments", message: "Missing nearby configuration", details: nil))
          return
        }
        self.startNearby(serviceID: serviceID, endpointName: String(endpointName.prefix(32)), result: result)
      case "send":
        guard
          let arguments = call.arguments as? [String: Any],
          let typedData = arguments["bytes"] as? FlutterStandardTypedData,
          let peerIDs = arguments["peerIds"] as? [String],
          !peerIDs.isEmpty,
          let manager = self.connectionManager
        else {
          result(FlutterError(code: "invalid_arguments", message: "Bytes and peer IDs are required", details: nil))
          return
        }
        _ = manager.send(typedData.data, to: peerIDs) { error in
          if let error {
            result(FlutterError(code: "send_failed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      case "stop":
        self.stopNearby()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nearbyChannel = channel

    let eventChannel = FlutterEventChannel(
      name: "me.osholt.ride_relay/nearby_events",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    eventChannel.setStreamHandler(self)
    nearbyEventChannel = eventChannel

    let gpxChannel = FlutterMethodChannel(
      name: "me.osholt.ride_relay/gpx_import",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    gpxChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "consumePendingGpxImport" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let pending = self?.pendingGpxImport else {
        result(nil)
        return
      }
      self?.pendingGpxImport = nil
      result([
        "bytes": FlutterStandardTypedData(bytes: pending.data),
        "fileName": pending.fileName,
      ])
    }
    gpxImportChannel = gpxChannel

    let carPlayChannel = FlutterMethodChannel(
      name: "me.osholt.ride_relay/carplay",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    carPlayChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "updateSnapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let snapshot = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_arguments", message: "Snapshot must be a map", details: nil))
        return
      }
      self?.latestCarPlaySnapshot = snapshot
      if let template = self?.carPlayListTemplate {
        CarPlayStatusTemplate.apply(snapshot: snapshot, to: template)
      }
      result(nil)
    }
    self.carPlayChannel = carPlayChannel
  }

  /// Called by CarPlaySceneDelegate once the CarPlay scene's list template is
  /// ready. Applies whatever snapshot Dart already published - the CarPlay
  /// scene can connect well after the ride screen's first publish.
  func carPlayDidConnect(_ template: CPListTemplate) {
    carPlayListTemplate = template
    if let snapshot = latestCarPlaySnapshot {
      CarPlayStatusTemplate.apply(snapshot: snapshot, to: template)
    }
  }

  func carPlayDidDisconnect() {
    carPlayListTemplate = nil
  }

  func triggerCarPlayEmergency() {
    carPlayChannel?.invokeMethod("triggerEmergency", arguments: nil)
  }

  /// Called from SceneDelegate when the OS hands this app a file URL (Open
  /// in..., a share sheet, or a cold launch from one of those). Dart pulls
  /// this on its own schedule via consumePendingGpxImport rather than being
  /// pushed to live, since a cold-start URL arrives before Dart's engine -
  /// and therefore any method call handler - is guaranteed to exist yet.
  func handleIncomingGpx(url: URL) {
    let isSecurityScoped = url.startAccessingSecurityScopedResource()
    defer {
      if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
    }
    guard let data = try? Data(contentsOf: url) else { return }
    pendingGpxImport = (data: data, fileName: url.lastPathComponent)
  }

  private func startNearby(serviceID: String, endpointName: String, result: @escaping FlutterResult) {
    stopNearby()
    emitStatus("starting")
    let manager = ConnectionManager(serviceID: serviceID, strategy: .cluster)
    manager.delegate = self
    manager.enableBLEV2()
    let advertiser = Advertiser(connectionManager: manager)
    advertiser.delegate = self
    let discoverer = Discoverer(connectionManager: manager)
    discoverer.delegate = self
    connectionManager = manager
    self.advertiser = advertiser
    self.discoverer = discoverer

    let group = DispatchGroup()
    var startError: Error?
    group.enter()
    advertiser.startAdvertising(using: Data(endpointName.utf8)) { error in
      startError = startError ?? error
      group.leave()
    }
    group.enter()
    discoverer.startDiscovery { error in
      startError = startError ?? error
      group.leave()
    }
    group.notify(queue: .main) { [weak self] in
      if let startError {
        self?.stopNearby()
        self?.emitStatus("failed", message: startError.localizedDescription)
        result(FlutterError(code: "start_failed", message: startError.localizedDescription, details: nil))
      } else {
        self?.emitStatus("searching")
        result(nil)
      }
    }
  }

  private func stopNearby() {
    advertiser?.stopAdvertising()
    discoverer?.stopDiscovery()
    for peerID in connectedPeers {
      connectionManager?.disconnect(from: peerID)
    }
    advertiser = nil
    discoverer = nil
    connectionManager = nil
    connectedPeers.removeAll()
    pendingPeers.removeAll()
    emitStatus("stopped")
  }

  private func emitStatus(_ state: String, message: String? = nil) {
    nearbyEventSink?([
      "kind": "status",
      "state": state,
      "peerIds": Array(connectedPeers),
      "message": message as Any,
    ])
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    nearbyEventSink = events
    emitStatus(connectedPeers.isEmpty ? "stopped" : "connected")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    nearbyEventSink = nil
    return nil
  }
}

extension AppDelegate: DiscovererDelegate {
  func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
    guard !connectedPeers.contains(endpointID), pendingPeers.insert(endpointID).inserted else { return }
    discoverer.requestConnection(to: endpointID, using: Data("Tail End Charlie".utf8)) { [weak self] error in
      if let error {
        self?.pendingPeers.remove(endpointID)
        self?.emitStatus("searching", message: "Connection request failed: \(error.localizedDescription)")
      }
    }
  }

  func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
    pendingPeers.remove(endpointID)
  }
}

extension AppDelegate: AdvertiserDelegate {
  func advertiser(
    _ advertiser: Advertiser,
    didReceiveConnectionRequestFrom endpointID: EndpointID,
    with context: Data,
    connectionRequestHandler: @escaping (Bool) -> Void
  ) {
    pendingPeers.insert(endpointID)
    connectionRequestHandler(true)
  }
}

extension AppDelegate: ConnectionManagerDelegate {
  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive verificationCode: String,
    from endpointID: EndpointID,
    verificationHandler: @escaping (Bool) -> Void
  ) {
    // Development alpha: app-layer ride-secret HMAC authenticates every frame.
    // Hardware validation must revisit user-visible Nearby token verification.
    verificationHandler(true)
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive data: Data,
    withID payloadID: PayloadID,
    from endpointID: EndpointID
  ) {
    nearbyEventSink?([
      "kind": "packet",
      "peerId": endpointID,
      "bytes": FlutterStandardTypedData(bytes: data),
    ])
  }

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceive stream: InputStream,
    withID payloadID: PayloadID,
    from endpointID: EndpointID,
    cancellationToken token: CancellationToken
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didStartReceivingResourceWithID payloadID: PayloadID,
    from endpointID: EndpointID,
    at localURL: URL,
    withName name: String,
    cancellationToken token: CancellationToken
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didReceiveTransferUpdate update: TransferUpdate,
    from endpointID: EndpointID,
    forPayload payloadID: PayloadID
  ) {}

  func connectionManager(
    _ connectionManager: ConnectionManager,
    didChangeTo state: ConnectionState,
    for endpointID: EndpointID
  ) {
    switch state {
    case .connected:
      pendingPeers.remove(endpointID)
      connectedPeers.insert(endpointID)
      emitStatus("connected")
    case .disconnected:
      pendingPeers.remove(endpointID)
      connectedPeers.remove(endpointID)
      emitStatus(connectedPeers.isEmpty ? "searching" : "connected")
    case .rejected:
      pendingPeers.remove(endpointID)
      emitStatus("searching", message: "Nearby connection rejected")
    case .connecting:
      break
    }
  }
}
