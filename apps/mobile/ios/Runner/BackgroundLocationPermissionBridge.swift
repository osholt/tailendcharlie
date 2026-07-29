import CoreLocation
import Flutter

/// Promotes an explicit active-ride location choice from While Using to Always.
///
/// geolocator cannot perform this second iOS permission step when both usage
/// descriptions are present: a repeated request simply reports While Using.
/// Keeping the promotion in a small bridge makes the consent point explicit and
/// leaves the GPS stream itself owned by geolocator.
final class BackgroundLocationPermissionBridge: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var pendingResult: FlutterResult?
  private var timeout: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    manager.delegate = self
    let channel = FlutterMethodChannel(
      name: "me.osholt.ride_relay/background_location",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "requestAlways" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.requestAlways(result: result)
    }
  }

  private func requestAlways(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "request_in_progress",
          message: "A background location request is already open.",
          details: nil
        )
      )
      return
    }
    switch manager.authorizationStatus {
    case .authorizedAlways, .denied, .restricted:
      result(statusName(manager.authorizationStatus))
    case .notDetermined, .authorizedWhenInUse:
      pendingResult = result
      manager.requestAlwaysAuthorization()
      let timeout = DispatchWorkItem { [weak self] in
        self?.finishPendingRequest()
      }
      self.timeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    @unknown default:
      result("denied")
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard pendingResult != nil, manager.authorizationStatus != .notDetermined else {
      return
    }
    finishPendingRequest()
  }

  private func finishPendingRequest() {
    guard let result = pendingResult else { return }
    pendingResult = nil
    timeout?.cancel()
    timeout = nil
    result(statusName(manager.authorizationStatus))
  }

  private func statusName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedAlways:
      return "always"
    case .authorizedWhenInUse:
      return "whileInUse"
    case .denied, .restricted:
      return "deniedForever"
    case .notDetermined:
      return "denied"
    @unknown default:
      return "denied"
    }
  }
}
