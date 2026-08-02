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
  private let tecBadge = CarPlayTecBadge()
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
    // Issue #295: without these the first thing a rider saw on plugging in was
    // MKMapView's default region - the whole United Kingdom - with nothing
    // drawn on it, because before a ride starts there is no rider position and
    // no route, so neither camera branch in `apply(snapshot:)` ever ran and
    // `setCamera`/`setVisibleMapRect` were never called at all. Handing the
    // camera to MapKit's own follow mode means the map is framed on the rider
    // from the first fix, ride or no ride, and the blue dot gives it something
    // to be framed on.
    mapView.showsUserLocation = true
    mapView.userTrackingMode = .follow
    view = mapView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Top-leading inside the safe area: CarPlay's own templates own the
    // navigation bar and the trailing map buttons, and the safe area is what
    // keeps this clear of both.
    tecBadge.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tecBadge)
    NSLayoutConstraint.activate([
      tecBadge.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: 12
      ),
      tecBadge.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: 12
      ),
    ])
  }

  func apply(snapshot: [String: Any]) {
    let incomingRouteID = snapshot["routeId"] as? String
    let routeChanged = incomingRouteID != routeID || routeOverlay == nil
    if routeChanged {
      updateRoute(snapshot["routePoints"])
      routeID = incomingRouteID
    }
    updateRiders(snapshot["riders"])
    tecBadge.apply(snapshot["tec"] as? [String: Any])
    // The ride's own marker for this rider carries their name and role and is
    // the one the group is drawn against. MapKit's blue dot is the stand-in
    // for it before a ride starts (#295), so exactly one of the two is ever
    // on the map.
    mapView.showsUserLocation = localCoordinate == nil
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
    // Taking the camera back off MapKit's follow mode, or it animates against
    // every camera this sets. The ride's own fix is preferred once there is
    // one: it carries the rider's heading and is the position the rest of the
    // group is being measured against.
    mapView.userTrackingMode = .none
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
    mapView.userTrackingMode = .none
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
    mapView.userTrackingMode = .none
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
    // MKUserLocation is MapKit's, not ours - removing it here would fight
    // `showsUserLocation` rather than clear a rider marker.
    mapView.removeAnnotations(
      mapView.annotations.filter { !($0 is MKUserLocation) }
    )
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
        isTec: (rider["isTec"] as? NSNumber)?.boolValue ?? false,
        needsAttention: (rider["needsAttention"] as? NSNumber)?.boolValue ?? false
      )
      mapView.addAnnotation(annotation)
      if isLocal {
        localCoordinate = coordinate
        localHeading = (rider["headingDegrees"] as? NSNumber)?.doubleValue
      }
    }
  }

  /// Frames the whole planned route, or - with no route to frame - hands the
  /// camera back to the rider rather than leaving it wherever it was.
  ///
  /// The bare `guard let routeOverlay else { return }` this replaces is half of
  /// #295: a route-less ride reached here, nothing happened, and the map stayed
  /// at MKMapView's country-level default with no way back.
  private func showCompleteRoute() {
    guard let routeOverlay else {
      mapView.userTrackingMode = .follow
      return
    }
    mapView.userTrackingMode = .none
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
    // The back-marker is picked out from the rest of the group. A leader
    // glancing at a head unit is looking for one rider in particular, and
    // reading initials off a moving map at speed is not a way to find them.
    view.markerTintColor = rider.needsAttention
      ? .systemOrange
      : rider.isLocal ? .systemBlue : rider.isTec ? .systemGreen : .systemGray
    view.glyphText = rider.isLocal
      ? "You"
      : rider.isTec ? "TEC" : String(rider.title?.prefix(1) ?? "•")
    return view
  }

  func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
    let userIsMovingMap = mapView.subviews
      .compactMap(\.gestureRecognizers)
      .flatMap { $0 }
      .contains { $0.state == .began || $0.state == .changed }
    if userIsMovingMap {
      followsLocalRider = false
      mapView.userTrackingMode = .none
    }
  }
}

private final class CarPlayRiderAnnotation: NSObject, MKAnnotation {
  @objc dynamic var coordinate: CLLocationCoordinate2D
  let title: String?
  let subtitle: String?
  let isLocal: Bool

  /// The one effective back-marker, already resolved by Dart. Two riders can
  /// carry the role in the journal at once (#128); exactly one arrives here
  /// flagged, so the map cannot draw two backs to one group.
  let isTec: Bool
  let needsAttention: Bool

  init(
    coordinate: CLLocationCoordinate2D,
    title: String,
    subtitle: String?,
    isLocal: Bool,
    isTec: Bool,
    needsAttention: Bool
  ) {
    self.coordinate = coordinate
    self.title = title
    self.subtitle = subtitle
    self.isLocal = isLocal
    self.isTec = isTec
    self.needsAttention = needsAttention
  }
}

/// The persistent back-marker readout on the CarPlay map canvas.
///
/// The ride-status list already carries the full sentence, but it is a template
/// a rider has to navigate to. This is the version that is simply *there* while
/// the map is up, which is the whole point on a screen nobody should be reading
/// for more than a moment.
///
/// Colour is never the only signal: the trend arrow is already in the text, and
/// the states differ in words as well as tint. Riders wear tinted visors in
/// direct sunlight, and some cannot tell the tints apart at all.
private final class CarPlayTecBadge: UIView {
  private let label = UILabel()

  init() {
    super.init(frame: .zero)
    isHidden = true
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    backgroundColor = UIColor.black.withAlphaComponent(0.65)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15, weight: .semibold)
    label.textColor = .white
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(_ tec: [String: Any]?) {
    // No TEC block at all means no ride is being projected yet, which is not
    // the same as a ride with no back-marker - that arrives with state "none"
    // and is shown, deliberately, as "No TEC".
    guard let tec, let headline = tec["headline"] as? String else {
      isHidden = true
      return
    }
    isHidden = false
    label.text = headline
    switch tec["state"] as? String {
    case "none":
      backgroundColor = UIColor.systemRed.withAlphaComponent(0.75)
    case "stale", "awaitingLocation":
      backgroundColor = UIColor.systemOrange.withAlphaComponent(0.75)
    default:
      backgroundColor = UIColor.black.withAlphaComponent(0.65)
    }
  }
}
