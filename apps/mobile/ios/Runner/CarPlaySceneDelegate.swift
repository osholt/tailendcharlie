import CarPlay
import MapKit
import UIKit

/// Owns the navigation-app CarPlay scene. Navigation apps must use the
/// window-bearing delegate callback and place a `CPMapTemplate` at the root.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  CPMapTemplateDelegate
{
  private var mapTemplate: CPMapTemplate?
  private var mapViewController: CarPlayNavigationViewController?
  private var statusTemplate: CPListTemplate?
  private var navigationSession: CPNavigationSession?
  private var activeRouteID: String?
  private var activeManeuverKey: String?
  private var activeManeuver: CPManeuver?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController,
    to window: CPWindow
  ) {
    let mapViewController = CarPlayNavigationViewController()
    let mapTemplate = CPMapTemplate()
    let statusTemplate = CarPlayStatusTemplate.makeTemplate()

    self.mapTemplate = mapTemplate
    self.mapViewController = mapViewController
    self.statusTemplate = statusTemplate

    window.rootViewController = mapViewController
    mapTemplate.mapDelegate = self
    mapTemplate.automaticallyHidesNavigationBar = true
    mapTemplate.hidesButtonsWithNavigationBar = false
    mapTemplate.mapButtons = [recenterButton(), panButton(mapTemplate: mapTemplate)]
    mapTemplate.trailingNavigationBarButtons = [
      statusButton(interfaceController: interfaceController, template: statusTemplate),
      emergencyButton(),
    ]
    interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)
    (UIApplication.shared.delegate as? AppDelegate)?.carPlayDidConnect(self)
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController,
    from window: CPWindow
  ) {
    navigationSession?.cancelTrip()
    navigationSession = nil
    window.rootViewController = nil
    (UIApplication.shared.delegate as? AppDelegate)?.carPlayDidDisconnect(self)
  }

  func apply(snapshot: [String: Any]) {
    mapViewController?.apply(snapshot: snapshot)
    if let statusTemplate {
      CarPlayStatusTemplate.apply(snapshot: snapshot, to: statusTemplate)
    }
    updateNavigationSession(snapshot: snapshot)
  }

  @available(iOS 17.4, *)
  func mapTemplateShouldProvideNavigationMetadata(_ mapTemplate: CPMapTemplate) -> Bool {
    true
  }

  func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
    mapTemplate.leadingNavigationBarButtons = [
      CPBarButton(title: "Done") { _ in
        mapTemplate.dismissPanningInterface(animated: true)
      }
    ]
  }

  func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
    mapTemplate.leadingNavigationBarButtons = []
  }

  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    panWith direction: CPMapTemplate.PanDirection
  ) {
    mapViewController?.pan(direction: direction)
  }

  func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
    mapViewController?.beginPanGesture()
  }

  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didUpdatePanGestureWithTranslation translation: CGPoint,
    velocity: CGPoint
  ) {
    mapViewController?.updatePanGesture(translation: translation)
  }

  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didEndPanGestureWithVelocity velocity: CGPoint
  ) {
    mapViewController?.endPanGesture()
  }

  private func updateNavigationSession(snapshot: [String: Any]) {
    guard
      let mapTemplate,
      let routePoints = snapshot["routePoints"] as? [[String: Any]],
      let first = coordinate(from: routePoints.first),
      let last = coordinate(from: routePoints.last),
      routePoints.count >= 2
    else {
      navigationSession?.cancelTrip()
      navigationSession = nil
      activeRouteID = nil
      activeManeuverKey = nil
      activeManeuver = nil
      return
    }

    let routeName = nonEmptyString(snapshot["routeName"]) ?? "Current route"
    let routeID =
      nonEmptyString(snapshot["routeId"])
      ?? "\(routePoints.count):\(first.latitude),\(first.longitude):\(last.latitude),\(last.longitude)"
    if navigationSession == nil || routeID != activeRouteID {
      navigationSession?.cancelTrip()
      let origin = MKMapItem(placemark: MKPlacemark(coordinate: first))
      origin.name = "Ride start"
      let destination = MKMapItem(placemark: MKPlacemark(coordinate: last))
      destination.name = routeName
      let choice = CPRouteChoice(
        summaryVariants: [routeName],
        additionalInformationVariants: ["Group motorcycle route"],
        selectionSummaryVariants: [routeName]
      )
      let trip = CPTrip(origin: origin, destination: destination, routeChoices: [choice])
      navigationSession = mapTemplate.startNavigationSession(for: trip)
      activeRouteID = routeID
      activeManeuverKey = nil
      activeManeuver = nil
    }

    guard
      let navigationSession,
      let title = nonEmptyString(snapshot["guidanceTitle"])
    else {
      navigationSession?.upcomingManeuvers = []
      activeManeuverKey = nil
      activeManeuver = nil
      return
    }

    let distance = max(0, (snapshot["guidanceDistanceMeters"] as? NSNumber)?.doubleValue ?? 0)
    let roadName = nonEmptyString(snapshot["guidanceRoadName"])
    let maneuverKey = "\(title)|\(roadName ?? "")"
    let estimates = CPTravelEstimates(
      distanceRemaining: Measurement(value: distance, unit: UnitLength.meters),
      timeRemaining: -1
    )
    let maneuver: CPManeuver
    if activeManeuverKey == maneuverKey, let existing = activeManeuver {
      maneuver = existing
    } else {
      maneuver = CPManeuver()
      maneuver.instructionVariants = [title]
      maneuver.symbolImage = maneuverSymbol(for: title)
      maneuver.initialTravelEstimates = estimates
      if #available(iOS 17.4, *) {
        navigationSession.add([maneuver])
      }
      navigationSession.upcomingManeuvers = [maneuver]
      activeManeuverKey = maneuverKey
      activeManeuver = maneuver
    }
    if #available(iOS 17.4, *) {
      navigationSession.currentRoadNameVariants = roadName.map { [$0] } ?? []
    }
    navigationSession.updateEstimates(estimates, for: maneuver)
  }

  private func recenterButton() -> CPMapButton {
    let button = CPMapButton { [weak self] _ in
      self?.mapViewController?.recenter()
    }
    button.image = UIImage(systemName: "location.fill")
    return button
  }

  private func panButton(mapTemplate: CPMapTemplate) -> CPMapButton {
    let button = CPMapButton { _ in
      mapTemplate.showPanningInterface(animated: true)
    }
    button.image = UIImage(systemName: "move.3d")
    return button
  }

  private func statusButton(
    interfaceController: CPInterfaceController,
    template: CPListTemplate
  ) -> CPBarButton {
    CPBarButton(title: "Ride") { _ in
      interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
  }

  private func emergencyButton() -> CPBarButton {
    CPBarButton(title: "SOS") { _ in
      (UIApplication.shared.delegate as? AppDelegate)?.triggerCarPlayEmergency()
    }
  }

  private func coordinate(from raw: [String: Any]?) -> CLLocationCoordinate2D? {
    guard
      let raw,
      let latitude = (raw["latitude"] as? NSNumber)?.doubleValue,
      let longitude = (raw["longitude"] as? NSNumber)?.doubleValue,
      (-90 ... 90).contains(latitude),
      (-180 ... 180).contains(longitude)
    else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private func nonEmptyString(_ raw: Any?) -> String? {
    guard let value = raw as? String, !value.isEmpty else { return nil }
    return value
  }

  private func maneuverSymbol(for title: String) -> UIImage? {
    let lowercased = title.lowercased()
    if lowercased.contains("left") {
      return UIImage(systemName: "arrow.turn.up.left")
    }
    if lowercased.contains("right") {
      return UIImage(systemName: "arrow.turn.up.right")
    }
    if lowercased.contains("roundabout") {
      return UIImage(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
    }
    if lowercased.contains("u-turn") || lowercased.contains("uturn") {
      return UIImage(systemName: "arrow.uturn.up")
    }
    return UIImage(systemName: "arrow.up")
  }
}

/// Draws app-owned route and group-location content behind the CarPlay
/// templates. CarPlay owns the turn cards and controls; MapKit owns only the
/// map canvas.
private final class CarPlayNavigationViewController: UIViewController,
  MKMapViewDelegate
{
  private let mapView = MKMapView(frame: .zero)
  private var routeOverlay: MKPolyline?
  private var routeID: String?
  private var localCoordinate: CLLocationCoordinate2D?
  private var localHeading: CLLocationDirection?
  private var followsLocalRider = true
  private var panGestureStartCoordinate: CLLocationCoordinate2D?

  override func loadView() {
    mapView.delegate = self
    mapView.showsCompass = true
    mapView.pointOfInterestFilter = .excludingAll
    view = mapView
  }

  func apply(snapshot: [String: Any]) {
    let incomingRouteID = snapshot["routeId"] as? String
    let routeChanged = incomingRouteID != routeID || routeOverlay == nil
    if routeChanged {
      updateRoute(snapshot["routePoints"])
      routeID = incomingRouteID
    }
    updateRiders(snapshot["riders"])
    if localCoordinate != nil, followsLocalRider {
      recenter()
    } else if routeChanged {
      showCompleteRoute()
    }
  }

  func recenter() {
    followsLocalRider = true
    guard let coordinate = localCoordinate else {
      showCompleteRoute()
      return
    }
    let camera = MKMapCamera(
      lookingAtCenter: coordinate,
      fromDistance: 1_800,
      pitch: 25,
      heading: localHeading ?? 0
    )
    mapView.setCamera(camera, animated: true)
  }

  func pan(direction: CPMapTemplate.PanDirection) {
    followsLocalRider = false
    var center = MKMapPoint(mapView.centerCoordinate)
    let rect = mapView.visibleMapRect
    if direction.contains(.left) {
      center.x -= rect.size.width * 0.25
    }
    if direction.contains(.right) {
      center.x += rect.size.width * 0.25
    }
    if direction.contains(.up) {
      center.y -= rect.size.height * 0.25
    }
    if direction.contains(.down) {
      center.y += rect.size.height * 0.25
    }
    mapView.setCenter(center.coordinate, animated: true)
  }

  func beginPanGesture() {
    followsLocalRider = false
    panGestureStartCoordinate = mapView.centerCoordinate
  }

  func updatePanGesture(translation: CGPoint) {
    guard let start = panGestureStartCoordinate else { return }
    let startPoint = mapView.convert(start, toPointTo: mapView)
    let translatedPoint = CGPoint(
      x: startPoint.x - translation.x,
      y: startPoint.y - translation.y
    )
    mapView.centerCoordinate = mapView.convert(translatedPoint, toCoordinateFrom: mapView)
  }

  func endPanGesture() {
    panGestureStartCoordinate = nil
  }

  private func updateRoute(_ raw: Any?) {
    if let routeOverlay {
      mapView.removeOverlay(routeOverlay)
    }
    let points = (raw as? [[String: Any]] ?? []).compactMap(coordinate(from:))
    guard points.count >= 2 else {
      routeOverlay = nil
      return
    }
    let overlay = MKPolyline(coordinates: points, count: points.count)
    routeOverlay = overlay
    mapView.addOverlay(overlay, level: .aboveRoads)
  }

  private func updateRiders(_ raw: Any?) {
    mapView.removeAnnotations(mapView.annotations)
    localCoordinate = nil
    localHeading = nil
    let riders = raw as? [[String: Any]] ?? []
    for rider in riders {
      guard let coordinate = coordinate(from: rider) else { continue }
      let isLocal = (rider["isLocal"] as? NSNumber)?.boolValue ?? false
      let annotation = CarPlayRiderAnnotation(
        coordinate: coordinate,
        title: rider["label"] as? String ?? "Rider",
        subtitle: rider["role"] as? String,
        isLocal: isLocal,
        needsAttention: (rider["needsAttention"] as? NSNumber)?.boolValue ?? false
      )
      mapView.addAnnotation(annotation)
      if isLocal {
        localCoordinate = coordinate
        localHeading = (rider["headingDegrees"] as? NSNumber)?.doubleValue
      }
    }
  }

  private func showCompleteRoute() {
    guard let routeOverlay else { return }
    mapView.setVisibleMapRect(
      routeOverlay.boundingMapRect,
      edgePadding: UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
      animated: true
    )
  }

  private func coordinate(from raw: [String: Any]) -> CLLocationCoordinate2D? {
    guard
      let latitude = (raw["latitude"] as? NSNumber)?.doubleValue,
      let longitude = (raw["longitude"] as? NSNumber)?.doubleValue,
      (-90 ... 90).contains(latitude),
      (-180 ... 180).contains(longitude)
    else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  func mapView(
    _ mapView: MKMapView,
    rendererFor overlay: MKOverlay
  ) -> MKOverlayRenderer {
    guard let polyline = overlay as? MKPolyline else {
      return MKOverlayRenderer(overlay: overlay)
    }
    let renderer = MKPolylineRenderer(polyline: polyline)
    renderer.strokeColor = UIColor.systemYellow
    renderer.lineWidth = 7
    renderer.lineJoin = .round
    renderer.lineCap = .round
    return renderer
  }

  func mapView(
    _ mapView: MKMapView,
    viewFor annotation: MKAnnotation
  ) -> MKAnnotationView? {
    guard let rider = annotation as? CarPlayRiderAnnotation else { return nil }
    let reuseID = "CarPlayRider"
    let view =
      mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
      as? MKMarkerAnnotationView
      ?? MKMarkerAnnotationView(annotation: rider, reuseIdentifier: reuseID)
    view.annotation = rider
    view.canShowCallout = true
    view.markerTintColor = rider.needsAttention
      ? .systemOrange
      : rider.isLocal ? .systemBlue : .systemGray
    view.glyphText = rider.isLocal ? "You" : String(rider.title?.prefix(1) ?? "•")
    return view
  }

  func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
    let userIsMovingMap = mapView.subviews
      .compactMap(\.gestureRecognizers)
      .flatMap { $0 }
      .contains { $0.state == .began || $0.state == .changed }
    if userIsMovingMap {
      followsLocalRider = false
    }
  }
}

private final class CarPlayRiderAnnotation: NSObject, MKAnnotation {
  @objc dynamic var coordinate: CLLocationCoordinate2D
  let title: String?
  let subtitle: String?
  let isLocal: Bool
  let needsAttention: Bool

  init(
    coordinate: CLLocationCoordinate2D,
    title: String,
    subtitle: String?,
    isLocal: Bool,
    needsAttention: Bool
  ) {
    self.coordinate = coordinate
    self.title = title
    self.subtitle = subtitle
    self.isLocal = isLocal
    self.needsAttention = needsAttention
  }
}
