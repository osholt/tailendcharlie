import CarPlay
import CoreLocation
import MapLibre
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
  private weak var interfaceController: CPInterfaceController?

  /// The request the presented alert is asking about, so the same question is
  /// not raised twice and a question that has gone away takes its alert with
  /// it.
  private var presentedTecRequestID: String?

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
    self.interfaceController = interfaceController

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
    self.interfaceController = nil
    presentedTecRequestID = nil
    (UIApplication.shared.delegate as? AppDelegate)?.carPlayDidDisconnect(self)
  }

  func apply(snapshot: [String: Any]) {
    mapViewController?.apply(snapshot: snapshot)
    if let statusTemplate {
      CarPlayStatusTemplate.apply(snapshot: snapshot, to: statusTemplate)
    }
    updateNavigationSession(snapshot: snapshot)
    updateTecRoleRequest(snapshot["tecRequest"] as? [String: Any])
  }

  /// Raises, and takes down, the leader's "will you be Tail End Charlie?"
  /// question (#128).
  ///
  /// A two-action alert is the whole interaction: the role is a request the
  /// target answers, and asking it on the screen the rider is already looking
  /// at is the point. Once the request is answered, expires, is superseded or
  /// the target leaves, Dart stops publishing it and the alert comes down —
  /// leaving it up would be asking a rider to agree to something no longer on
  /// offer.
  private func updateTecRoleRequest(_ request: [String: Any]?) {
    guard
      let request,
      let requestID = request["requestId"] as? String,
      !requestID.isEmpty
    else {
      if presentedTecRequestID != nil {
        presentedTecRequestID = nil
        interfaceController?.dismissTemplate(animated: true, completion: nil)
      }
      return
    }
    guard requestID != presentedTecRequestID else { return }
    guard let interfaceController else { return }

    let answer: (Bool) -> Void = { [weak self] accepted in
      self?.presentedTecRequestID = nil
      interfaceController.dismissTemplate(animated: true, completion: nil)
      (UIApplication.shared.delegate as? AppDelegate)?
        .answerCarPlayTecRoleRequest(requestID: requestID, accepted: accepted)
    }
    let alert = CPAlertTemplate(
      titleVariants: [
        request["title"] as? String ?? "Be Tail End Charlie?",
        "Be Tail End Charlie?",
        "Ride at the back?",
      ],
      actions: [
        // Declining first would put the destructive answer under the thumb
        // that is reaching for the screen at a fuel stop.
        CPAlertAction(title: "Accept", style: .default) { _ in answer(true) },
        CPAlertAction(title: "Not now", style: .cancel) { _ in answer(false) },
      ]
    )
    presentedTecRequestID = requestID
    interfaceController.presentTemplate(alert, animated: true, completion: nil)
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
/// templates. CarPlay owns the turn cards and controls; this owns only the map
/// canvas.
///
/// MapLibre, not MapKit (#321). The head unit shares the phone's MapLibre style
/// and its ambient tile cache — same process, same cache — so a rider who loses
/// signal keeps the basemap they had a mile ago instead of watching the car
/// screen go grey, and the deliberate day/night styling measured in #107 and
/// #143 reaches the surface a rider actually looks at while moving.
private final class CarPlayNavigationViewController: UIViewController,
  MLNMapViewDelegate
{
  private var mapView: MLNMapView?
  private let tecBadge = CarPlayTecBadge()
  private var routeAnnotation: MLNPolyline?
  private var routeID: String?
  private var riderAnnotations: [CarPlayRiderAnnotation] = []
  private var localCoordinate: CLLocationCoordinate2D?
  private var localHeading: CLLocationDirection?
  private var followsLocalRider = true
  private var panGestureStartCoordinate: CLLocationCoordinate2D?

  /// The styles Dart published, and the one currently applied. Held because the
  /// car's day/night state can change at any time and the snapshot that carried
  /// the styles may be minutes old by then.
  private var lightStyleURL: URL?
  private var darkStyleURL: URL?
  private var appliedStyleURL: URL?

  /// The last snapshot, replayed once the style finishes loading. A style load
  /// clears every annotation with it, so route and riders have to go back on
  /// afterwards or the map comes back empty (#295 by a different route).
  private var latestSnapshot: [String: Any]?

  override func loadView() {
    // A plain view until Dart supplies a style. MLNMapView with no style URL
    // renders nothing useful and cannot be restyled cleanly afterwards, so the
    // map is built once the first snapshot names one.
    let container = UIView(frame: .zero)
    container.backgroundColor = .black
    view = container
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

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    guard
      traitCollection.userInterfaceStyle != previous?.userInterfaceStyle
    else { return }
    applyPreferredStyle()
  }

  func apply(snapshot: [String: Any]) {
    latestSnapshot = snapshot
    updateStyleURLs(snapshot["basemap"] as? [String: Any])
    guard let mapView else { return }
    let incomingRouteID = snapshot["routeId"] as? String
    let routeChanged = incomingRouteID != routeID || routeAnnotation == nil
    if routeChanged {
      updateRoute(snapshot["routePoints"])
      routeID = incomingRouteID
    }
    updateRiders(snapshot["riders"])
    tecBadge.apply(snapshot["tec"] as? [String: Any])
    // The ride's own marker for this rider carries their name and role and is
    // the one the group is drawn against. MapLibre's location dot is the
    // stand-in for it before a ride starts (#295), so exactly one of the two is
    // ever on the map.
    mapView.showsUserLocation = localCoordinate == nil
    if localCoordinate != nil, followsLocalRider {
      recenter()
    } else if routeChanged {
      showCompleteRoute()
    }
  }

  func recenter() {
    followsLocalRider = true
    guard let mapView else { return }
    guard let coordinate = localCoordinate else {
      showCompleteRoute()
      return
    }
    // Taking the camera back off MapLibre's follow mode, or it animates against
    // every camera this sets. The ride's own fix is preferred once there is one:
    // it carries the rider's heading and is the position the rest of the group
    // is being measured against.
    mapView.userTrackingMode = .none
    let camera = MLNMapCamera(
      lookingAtCenter: coordinate,
      altitude: 1_800,
      pitch: 25,
      heading: localHeading ?? 0
    )
    mapView.setCamera(camera, animated: true)
  }

  func pan(direction: CPMapTemplate.PanDirection) {
    followsLocalRider = false
    guard let mapView else { return }
    mapView.userTrackingMode = .none
    var point = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
    let step = CGPoint(x: mapView.bounds.width * 0.25, y: mapView.bounds.height * 0.25)
    if direction.contains(.left) { point.x -= step.x }
    if direction.contains(.right) { point.x += step.x }
    if direction.contains(.up) { point.y -= step.y }
    if direction.contains(.down) { point.y += step.y }
    mapView.setCenter(
      mapView.convert(point, toCoordinateFrom: mapView),
      animated: true
    )
  }

  func beginPanGesture() {
    followsLocalRider = false
    mapView?.userTrackingMode = .none
    panGestureStartCoordinate = mapView?.centerCoordinate
  }

  func updatePanGesture(translation: CGPoint) {
    guard let mapView, let start = panGestureStartCoordinate else { return }
    let startPoint = mapView.convert(start, toPointTo: mapView)
    let translated = CGPoint(
      x: startPoint.x - translation.x,
      y: startPoint.y - translation.y
    )
    mapView.setCenter(
      mapView.convert(translated, toCoordinateFrom: mapView),
      animated: false
    )
  }

  func endPanGesture() {
    panGestureStartCoordinate = nil
  }

  // MARK: - Style

  private func updateStyleURLs(_ basemap: [String: Any]?) {
    guard let basemap else { return }
    let light = (basemap["styleUrl"] as? String).flatMap(URL.init(string:))
    let dark = (basemap["darkStyleUrl"] as? String).flatMap(URL.init(string:))
    guard light != nil || dark != nil else { return }
    lightStyleURL = light ?? dark
    darkStyleURL = dark ?? light
    applyPreferredStyle()
  }

  private func applyPreferredStyle() {
    let preferred = traitCollection.userInterfaceStyle == .dark
      ? darkStyleURL
      : lightStyleURL
    guard let preferred, preferred != appliedStyleURL else { return }
    appliedStyleURL = preferred
    guard let mapView else {
      installMapView(styleURL: preferred)
      return
    }
    mapView.styleURL = preferred
  }

  private func installMapView(styleURL: URL) {
    let mapView = MLNMapView(frame: view.bounds, styleURL: styleURL)
    mapView.delegate = self
    mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    mapView.showsUserLocation = true
    mapView.userTrackingMode = .follow
    // CarPlay owns the bottom-trailing corner for its own map buttons, so
    // MapLibre's ornaments go to the other side rather than underneath them.
    // Attribution stays visible: it is a licence condition, not decoration.
    mapView.logoViewPosition = .bottomLeft
    mapView.attributionButtonPosition = .bottomLeft
    mapView.compassViewPosition = .topRight
    view.insertSubview(mapView, at: 0)
    self.mapView = mapView
    if let latestSnapshot { apply(snapshot: latestSnapshot) }
  }

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    // A style load takes the annotations with it. Put the ride back on.
    routeAnnotation = nil
    riderAnnotations = []
    routeID = nil
    if let latestSnapshot { apply(snapshot: latestSnapshot) }
  }

  // MARK: - Content

  private func updateRoute(_ raw: Any?) {
    guard let mapView else { return }
    if let routeAnnotation {
      mapView.removeAnnotation(routeAnnotation)
    }
    var points = (raw as? [[String: Any]] ?? []).compactMap(coordinate(from:))
    guard points.count >= 2 else {
      routeAnnotation = nil
      return
    }
    let polyline = MLNPolyline(coordinates: &points, count: UInt(points.count))
    routeAnnotation = polyline
    mapView.addAnnotation(polyline)
  }

  private func updateRiders(_ raw: Any?) {
    guard let mapView else { return }
    if !riderAnnotations.isEmpty {
      mapView.removeAnnotations(riderAnnotations)
      riderAnnotations = []
    }
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
      riderAnnotations.append(annotation)
      if isLocal {
        localCoordinate = coordinate
        localHeading = (rider["headingDegrees"] as? NSNumber)?.doubleValue
      }
    }
    if !riderAnnotations.isEmpty {
      mapView.addAnnotations(riderAnnotations)
    }
  }

  /// Frames the whole planned route, or - with no route to frame - hands the
  /// camera back to the rider rather than leaving it wherever it was.
  ///
  /// Returning silently with no route is half of #295: a route-less ride
  /// reached here, nothing happened, and the map stayed wherever it had been
  /// left with no way back.
  private func showCompleteRoute() {
    guard let mapView else { return }
    guard let routeAnnotation else {
      mapView.userTrackingMode = .follow
      return
    }
    mapView.userTrackingMode = .none
    mapView.setVisibleCoordinateBounds(
      routeAnnotation.overlayBounds,
      edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
      animated: true,
      completionHandler: nil
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

  // MARK: - MLNMapViewDelegate

  func mapView(
    _ mapView: MLNMapView,
    strokeColorForShapeAnnotation annotation: MLNShape
  ) -> UIColor {
    annotation is MLNPolyline ? .systemYellow : .clear
  }

  func mapView(
    _ mapView: MLNMapView,
    lineWidthForPolylineAnnotation annotation: MLNPolyline
  ) -> CGFloat {
    7
  }

  func mapView(
    _ mapView: MLNMapView,
    viewFor annotation: MLNAnnotation
  ) -> MLNAnnotationView? {
    guard let rider = annotation as? CarPlayRiderAnnotation else { return nil }
    let reuseID = "CarPlayRider"
    let view =
      mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
      as? CarPlayRiderAnnotationView
      ?? CarPlayRiderAnnotationView(reuseIdentifier: reuseID)
    view.apply(rider)
    return view
  }

  func mapView(
    _ mapView: MLNMapView,
    regionWillChangeWith reason: MLNCameraChangeReason,
    animated: Bool
  ) {
    // MapLibre names the reason, so a rider taking the map over is detected
    // outright rather than inferred from gesture-recogniser state the way the
    // MapKit implementation had to.
    let gestures: MLNCameraChangeReason = [
      .gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn,
      .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt,
    ]
    if !reason.intersection(gestures).isEmpty {
      followsLocalRider = false
      mapView.userTrackingMode = .none
    }
  }
}

private final class CarPlayRiderAnnotation: NSObject, MLNAnnotation {
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

/// One rider on the CarPlay map.
///
/// A filled pill carrying a word rather than a bare coloured dot: the
/// back-marker is the rider a leader is looking *for*, and picking one dot out
/// of a group through a visor at speed is not a way to find them.
private final class CarPlayRiderAnnotationView: MLNAnnotationView {
  private let label = UILabel()

  init(reuseIdentifier: String) {
    super.init(reuseIdentifier: reuseIdentifier)
    isEnabled = false
    layer.cornerRadius = 11
    layer.cornerCurve = .continuous
    layer.borderWidth = 2
    layer.borderColor = UIColor.white.cgColor
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .heavy)
    label.textColor = .white
    label.textAlignment = .center
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(_ rider: CarPlayRiderAnnotation) {
    label.text = rider.isLocal
      ? "You"
      : rider.isTec ? "TEC" : String(rider.title?.prefix(1) ?? "•")
    backgroundColor = rider.needsAttention
      ? .systemOrange
      : rider.isLocal ? .systemBlue : rider.isTec ? .systemGreen : .systemGray
    let width = max(30, label.intrinsicContentSize.width + 14)
    frame = CGRect(x: 0, y: 0, width: width, height: 22)
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
