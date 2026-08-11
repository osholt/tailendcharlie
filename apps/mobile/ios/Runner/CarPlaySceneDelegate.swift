import CarPlay
import CoreLocation
import Flutter
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
  private var rideStartPrompt: [String: Any]?
  private var isShowingPanningInterface = false
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
    mapTemplate.guidanceBackgroundColor = CarPlayPalette.cardFill
    mapTemplate.mapButtons = [
      recenterButton(),
      panButton(mapTemplate: mapTemplate),
      reportButton(),
      emergencyButton(),
    ]
    mapTemplate.trailingNavigationBarButtons = [
      statusButton(interfaceController: interfaceController, template: statusTemplate),
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
    updateRideStart(snapshot["rideStart"] as? [String: Any])
  }

  func apply(viewport: [String: Any]) {
    mapViewController?.apply(viewport: viewport)
  }

  func apply(mapStyle: [String: Any]) {
    mapViewController?.apply(mapStyle: mapStyle)
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
    isShowingPanningInterface = true
    mapTemplate.leadingNavigationBarButtons = [
      CPBarButton(title: "Done") { _ in
        mapTemplate.dismissPanningInterface(animated: true)
      }
    ]
  }

  func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
    isShowingPanningInterface = false
    updateLeadingNavigationButtons()
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

  /// Keep the phone's turn/marker symbol visible beside the instruction. The
  /// default layout is allowed to discard it when the card gets tight, which
  /// made marker mode look like ordinary navigation on smaller head units.
  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    displayStyleFor maneuver: CPManeuver
  ) -> CPManeuverDisplayStyle {
    .leadingSymbol
  }

  private func updateNavigationSession(snapshot: [String: Any]) {
    let marker = snapshot["marker"] as? [String: Any]
    let guidanceTitle = nonEmptyString(marker?["title"])
      ?? nonEmptyString(snapshot["guidanceTitle"])
    let terminalGuidance = marker == nil
      && guidanceTitle?.lowercased().contains("no more turns") == true
    guard
      let guidanceTitle,
      !terminalGuidance,
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

    guard let navigationSession else { return }
    let title = guidanceTitle

    let markerDetail = nonEmptyString(marker?["detail"])
    let roadName = markerDetail ?? nonEmptyString(snapshot["guidanceRoadName"])
    let isMarkerMode = marker != nil
    let distance = max(0, (snapshot["guidanceDistanceMeters"] as? NSNumber)?.doubleValue ?? 0)
    let markerStage = nonEmptyString(marker?["stage"])
    // The key deliberately excludes the distance (#443).
    //
    // It used to include `displayTitle`, which carries the formatted distance —
    // so every position fix produced a new key, a new CPManeuver, and CarPlay
    // animated the card again. The rider saw the banner wiping constantly rather
    // than on each new direction.
    //
    // The distance now travels as a travel estimate instead, which is the API
    // CarPlay expects to change continuously, and is also what the instrument
    // cluster reads — it showed "— km" because nothing ever set it (#447).
    let maneuverKey = "\(isMarkerMode)|\(markerStage ?? "")|\(title)|\(roadName ?? "")"
    let maneuver: CPManeuver
    if activeManeuverKey == maneuverKey, let existing = activeManeuver {
      maneuver = existing
    } else {
      maneuver = CPManeuver()
      // The instruction alone. The distance used to be prefixed here, which
      // was fine only because the manoeuvre was rebuilt on every fix — now that
      // it is built once, a baked-in distance would freeze at its first value.
      // CarPlay renders the distance from the travel estimate below.
      maneuver.instructionVariants = [title]
      let symbol = isMarkerMode
        ? markerSymbol(for: markerStage)
        : maneuverSymbol(for: title)
      maneuver.symbolImage = symbol
      maneuver.dashboardSymbolImage = symbol
      maneuver.cardBackgroundColor = CarPlayPalette.cardFill
      if #available(iOS 17.4, *) {
        maneuver.maneuverType = isMarkerMode ? .noTurn : maneuverType(for: title)
        maneuver.roadFollowingManeuverVariants = roadName.map { [$0] }
        navigationSession.add([maneuver])
      }
      navigationSession.upcomingManeuvers = [maneuver]
      activeManeuverKey = maneuverKey
      activeManeuver = maneuver
    }
    // Every update, not only a new manoeuvre: this is the number the card and the
    // instrument cluster count down, and it is in the rider's own units so the
    // car agrees with the phone (#447).
    if distance > 0, !isMarkerMode {
      let usesMiles = (snapshot["distanceUnit"] as? String) == "miles"
      let remaining = usesMiles
        ? Measurement(value: distance / 1_609.344, unit: UnitLength.miles)
        : Measurement(value: distance, unit: UnitLength.meters)
      navigationSession.updateTravelEstimates(
        CPTravelEstimates(distanceRemaining: remaining, timeRemaining: 0),
        for: maneuver
      )
    }
    if #available(iOS 17.4, *) {
      navigationSession.currentRoadNameVariants = roadName.map { [$0] } ?? []
    }
  }

  private func markerSymbol(for stage: String?) -> UIImage? {
    switch stage {
    case "tecApproaching": return navigationSymbol(named: "shield.lefthalf.filled")
    case "readyToRideOff": return navigationSymbol(named: "play.fill")
    default: return navigationSymbol(named: "arrow.triangle.branch")
    }
  }

  @available(iOS 17.4, *)
  private func maneuverType(for title: String) -> CPManeuverType {
    let lowercased = title.lowercased()
    if lowercased.contains("keep left") { return .keepLeft }
    if lowercased.contains("keep right") { return .keepRight }
    if lowercased.contains("slight left") { return .slightLeftTurn }
    if lowercased.contains("slight right") { return .slightRightTurn }
    if lowercased.contains("destination") || lowercased.contains("arrive") {
      return .arriveAtDestination
    }
    // Roundabout before left/right (#447). "Roundabout, 2nd exit, right" matched
    // `right` first and was handed to the cluster as a plain right turn, so the
    // car drew a different junction from the phone.
    if lowercased.contains("roundabout") { return .enterRoundabout }
    if lowercased.contains("left") { return .leftTurn }
    if lowercased.contains("right") { return .rightTurn }
    if lowercased.contains("u-turn") || lowercased.contains("uturn") {
      return .uTurn
    }
    return .straightAhead
  }

  private func recenterButton() -> CPMapButton {
    let button = CPMapButton { [weak self] _ in
      self?.mapViewController?.recenter()
    }
    button.image = mapButtonImage(
      named: "location.north.fill",
      color: CarPlayPalette.actionInk,
      accessibilityLabel: "Follow my location"
    )
    return button
  }

  private func panButton(mapTemplate: CPMapTemplate) -> CPMapButton {
    let button = CPMapButton { _ in
      mapTemplate.showPanningInterface(animated: true)
    }
    button.image = mapButtonImage(
      named: "arrow.up.and.down.and.arrow.left.and.right",
      color: CarPlayPalette.actionInk,
      accessibilityLabel: "Pan map"
    )
    return button
  }

  private func reportButton() -> CPMapButton {
    let button = CPMapButton { [weak self] _ in
      self?.presentReportActions()
    }
    button.image = mapButtonImage(
      named: "bell.badge.fill",
      color: CarPlayPalette.reportAccent,
      accessibilityLabel: "Report alert"
    )
    return button
  }

  private func emergencyButton() -> CPMapButton {
    let button = CPMapButton { [weak self] _ in
      self?.presentEmergencyConfirmation()
    }
    button.image = mapButtonImage(
      named: "sos.circle.fill",
      color: CarPlayPalette.emergencyFill,
      accessibilityLabel: "SOS"
    )
    return button
  }

  /// Uses the same glyph colour language as the phone's landscape action row.
  /// `CPMapButton` supplies CarPlay's system-sized target; preserving the
  /// symbol's original colour keeps REPORT yellow and SOS red instead of
  /// flattening every action into the same blue control.
  private func mapButtonImage(
    named systemName: String,
    color: UIColor,
    accessibilityLabel: String
  ) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
    let image = UIImage(systemName: systemName, withConfiguration: configuration)?
      .withTintColor(color, renderingMode: .alwaysOriginal)
    image?.accessibilityLabel = accessibilityLabel
    return image
  }

  private func statusButton(
    interfaceController: CPInterfaceController,
    template: CPListTemplate
  ) -> CPBarButton {
    CPBarButton(title: "Ride") { _ in
      interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
  }

  /// Projects only the last pre-departure decision. Creation, joining, route
  /// selection and first-time permissions stay on the phone; Dart does not send
  /// this block unless the local rider owns a prepared, unstarted session.
  private func updateRideStart(_ prompt: [String: Any]?) {
    rideStartPrompt = prompt
    updateLeadingNavigationButtons()
  }

  private func updateLeadingNavigationButtons() {
    guard let mapTemplate, !isShowingPanningInterface else { return }
    let enabled = (rideStartPrompt?["enabled"] as? NSNumber)?.boolValue ?? false
    mapTemplate.leadingNavigationBarButtons = enabled ? [startRideButton()] : []
  }

  private func startRideButton() -> CPBarButton {
    CPBarButton(title: "Start") { [weak self] _ in
      self?.presentStartRideConfirmation()
    }
  }

  private func presentStartRideConfirmation() {
    guard
      let interfaceController,
      let prompt = rideStartPrompt,
      (prompt["enabled"] as? NSNumber)?.boolValue == true
    else { return }

    let detail = nonEmptyString(prompt["detail"])
    let warning = nonEmptyString(prompt["warning"])
    let message = [detail, warning].compactMap { $0 }.joined(separator: "\n\n")
    let sheet = CPActionSheetTemplate(
      title: "Start prepared ride?",
      message: message.isEmpty ? nil : message,
      actions: [
        CPAlertAction(title: "Start ride", style: .default) { [weak self] _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
          // Hide the action immediately. Dart will either publish the active
          // ride or re-offer it if revalidation rejects the stale snapshot.
          self?.rideStartPrompt = nil
          self?.updateLeadingNavigationButtons()
          (UIApplication.shared.delegate as? AppDelegate)?.startPreparedRideFromCarPlay()
        },
        CPAlertAction(title: "Cancel", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
        },
      ]
    )
    interfaceController.presentTemplate(sheet, animated: true, completion: nil)
  }

  private func presentReportActions() {
    guard let interfaceController else { return }
    let report: (String) -> Void = { type in
      interfaceController.dismissTemplate(animated: true, completion: nil)
      (UIApplication.shared.delegate as? AppDelegate)?
        .reportCarPlayHazard(type: type)
    }
    let sheet = CPActionSheetTemplate(
      title: "Report to group",
      message: "Uses your current position",
      actions: [
        CPAlertAction(title: "Speed camera", style: .default) { _ in
          report("speedCamera")
        },
        CPAlertAction(title: "Police", style: .default) { _ in
          report("policeActivity")
        },
        CPAlertAction(title: "Road hazard", style: .default) { _ in
          report("other")
        },
        CPAlertAction(title: "Cancel", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
        },
      ]
    )
    interfaceController.presentTemplate(sheet, animated: true, completion: nil)
  }

  private func presentEmergencyConfirmation() {
    guard let interfaceController else { return }
    let alert = CPAlertTemplate(
      titleVariants: ["Send SOS to the group?", "Send SOS?"],
      actions: [
        CPAlertAction(title: "Send SOS", style: .destructive) { _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
          (UIApplication.shared.delegate as? AppDelegate)?.triggerCarPlayEmergency()
        },
        CPAlertAction(title: "Cancel", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
        },
      ]
    )
    interfaceController.presentTemplate(alert, animated: true, completion: nil)
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
    if lowercased.contains("keep left") || lowercased.contains("slight left") {
      return navigationSymbol(named: "arrow.up.left")
    }
    if lowercased.contains("keep right") || lowercased.contains("slight right") {
      return navigationSymbol(named: "arrow.up.right")
    }
    if lowercased.contains("destination") || lowercased.contains("arrive") {
      return navigationSymbol(named: "flag.checkered")
    }
    if lowercased.contains("left") {
      return navigationSymbol(named: "arrow.turn.up.left")
    }
    if lowercased.contains("right") {
      return navigationSymbol(named: "arrow.turn.up.right")
    }
    if lowercased.contains("roundabout") {
      return navigationSymbol(named: "arrow.clockwise.circle")
    }
    if lowercased.contains("u-turn") || lowercased.contains("uturn") {
      return navigationSymbol(named: "arrow.uturn.up")
    }
    return navigationSymbol(named: "arrow.up")
  }

  private func navigationSymbol(named name: String) -> UIImage? {
    UIImage(
      systemName: name,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
    )
  }
}
/// The app's own map palette, mirrored for the CarPlay canvas.
///
/// Every value here is `RouteTrailStyle` in
/// `apps/mobile/lib/features/map/route_trail_style.dart`, and the reasoning for
/// each lives there rather than being restated: these are measured contrast
/// choices from #107, #133 and #143, not decoration. System colours were used
/// while the canvas was being stood up and were wrong on every count — the
/// route was `systemYellow`, which #107 rejected outright because it disappears
/// into the `#FFEEAA` trunk-road fill it is drawn on.
///
/// Two in particular are easy to "correct" back into a bug:
///
/// * **Glyph ink is dark, not white.** Every badge fill is deliberately light so
///   it can be found on a dark basemap, which makes a white glyph the one ink on
///   the map with nothing behind it — 1.53:1 on caution yellow. Dark reverses it
///   to 4.74:1 at worst.
/// * **Every line gets an opaque casing under it.** The casing is what keeps a
///   route readable where it crosses a light road fill.
private enum CarPlayPalette {
  static let casing = UIColor(red: 0x10 / 255, green: 0x15 / 255, blue: 0x1C / 255, alpha: 1)
  static let markerGlyph = casing
  static let routeAhead = UIColor(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255, alpha: 1)
  static let travelled = UIColor(red: 0xFF / 255, green: 0x7A / 255, blue: 0x1A / 255, alpha: 1)
  static let ownRider = UIColor(red: 0x2F / 255, green: 0x80 / 255, blue: 0xED / 255, alpha: 1)
  static let tailEndCharlie = UIColor(red: 0x68 / 255, green: 0xA9 / 255, blue: 0xFF / 255, alpha: 1)
  static let rider = UIColor(red: 0x6E / 255, green: 0xD8 / 255, blue: 0x9A / 255, alpha: 1)
  static let alerting = UIColor(red: 0xFF / 255, green: 0x5D / 255, blue: 0x73 / 255, alpha: 1)

  /// The ride chrome's card fill and its label ink, from the phone's TEC card.
  static let cardFill = UIColor(red: 0x25 / 255, green: 0x2E / 255, blue: 0x39 / 255, alpha: 0.90)
  static let cardLabel = UIColor(red: 0xB7 / 255, green: 0xC2 / 255, blue: 0xCF / 255, alpha: 1)
  static let cardTitle = UIColor.white
  static let actionInk = UIColor(red: 0xE4 / 255, green: 0xE9 / 255, blue: 0xEF / 255, alpha: 1)
  static let reportAccent = UIColor(red: 0xFF / 255, green: 0xD2 / 255, blue: 0x4A / 255, alpha: 1)
  static let emergencyFill = UIColor(red: 0xD9 / 255, green: 0x30 / 255, blue: 0x4F / 255, alpha: 1)

  /// `RouteLineStyle.routeAhead`: 6pt line on a 10pt casing.
  static let routeWidth: CGFloat = 6
  static let routeCasingWidth: CGFloat = 10

  /// `RouteLineStyle.travelled`: 5pt line on a 9pt casing.
  static let travelledWidth: CGFloat = 5
  static let travelledCasingWidth: CGFloat = 9
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
  private let speedBadge = CarPlaySpeedLimitBadge()
  private let groupMiniMap = CarPlayGroupMiniMapView()
  private var routeSource: MLNShapeSource?
  private var travelledRouteAnnotation: MLNPolyline?
  private var travelledRouteCasingAnnotation: MLNPolyline?
  private var routeCoordinates: [CLLocationCoordinate2D] = []
  private var routeID: String?
  private var routeProjectionKey: String?
  private var riderAnnotations: [CarPlayRiderAnnotation] = []
  private var localCoordinate: CLLocationCoordinate2D?
  private var localHeading: CLLocationDirection?
  private var followsLocalRider = true
  private var snapshotWantsRiderFollow = false
  private var panGestureStartCoordinate: CLLocationCoordinate2D?
  private var hasFramedFirstFix = false

  /// The styles Dart published, the exact style selected on the phone, and the
  /// one currently applied. CarPlay's trait remains a fallback until Dart has
  /// supplied the phone selection; after that both screens change together.
  private var lightStyleURL: URL?
  private var darkStyleURL: URL?
  private var appliedStyleURL: URL?
  private var phoneStyleURL: URL?
  private var phoneStyleJSON: String?
  private var appliedStyleJSON: String?

  /// The last snapshot, replayed once the style finishes loading. A style load
  /// clears every annotation with it, so route and riders have to go back on
  /// afterwards or the map comes back empty (#295 by a different route).
  private var latestSnapshot: [String: Any]?
  private var latestViewport: [String: Any]?

  /// Used only until Dart's first snapshot names a style, which it does on the
  /// first ride-state change. Without it a rider who plugs in before starting a
  /// ride gets a black rectangle — #295 all over again, since the projected
  /// snapshot is published from the ride shell and there is nothing to publish
  /// before a ride. Kept in step with `BasemapConfiguration`'s own defaults;
  /// Dart's value always wins the moment it arrives.
  private static let fallbackStyleURLs = (
    light: URL(string: "https://tiles.openfreemap.org/styles/liberty"),
    dark: URL(string: "https://tiles.openfreemap.org/styles/dark")
  )

  override func loadView() {
    // A plain view first: MLNMapView with no style URL renders nothing useful
    // and does not restyle cleanly afterwards, so the map is installed once a
    // style is known — from Dart if it has published one, otherwise the
    // fallback, so the canvas is never blank.
    let container = UIView(frame: .zero)
    container.backgroundColor = .black
    view = container
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    guard lightStyleURL == nil, darkStyleURL == nil else { return }
    lightStyleURL = Self.fallbackStyleURLs.light
    darkStyleURL = Self.fallbackStyleURLs.dark
    applyPreferredStyle()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Top-leading inside the safe area: CarPlay's own templates own the
    // navigation bar and the trailing map buttons, and the safe area is what
    // keeps this clear of both.
    tecBadge.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tecBadge)
    speedBadge.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(speedBadge)
    groupMiniMap.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(groupMiniMap)
    NSLayoutConstraint.activate([
      tecBadge.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: 12
      ),
      tecBadge.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: 12
      ),
      speedBadge.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -52
      ),
      speedBadge.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: 10
      ),
      groupMiniMap.widthAnchor.constraint(equalToConstant: 110),
      groupMiniMap.heightAnchor.constraint(equalToConstant: 70),
      groupMiniMap.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -12
      ),
      groupMiniMap.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -14
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
    let progress = (snapshot["routeProgressMeters"] as? NSNumber)?.doubleValue ?? 0
    let routeKey = "\(incomingRouteID ?? "none"):\(Int(progress / 2))"
    let routeChanged =
      routeKey != routeProjectionKey
      || routeSource == nil
    if routeChanged {
      updateRoute(
        snapshot["routePoints"],
        remaining: snapshot["remainingRoutePoints"],
        travelled: snapshot["riddenRoutePoints"]
      )
      routeID = incomingRouteID
      routeProjectionKey = routeKey
    }
    updateRiders(snapshot)
    groupMiniMap.apply(
      snapshot: snapshot,
      styleURL: preferredStyleURL,
      styleJSON: phoneStyleJSON
    )
    tecBadge.apply(snapshot["tec"] as? [String: Any])
    speedBadge.apply(snapshot["speed"] as? [String: Any])
    let requestedRiderFollow =
      (snapshot["followRider"] as? NSNumber)?.boolValue ?? false
    let cameraModeChanged = requestedRiderFollow != snapshotWantsRiderFollow
    snapshotWantsRiderFollow = requestedRiderFollow
    if cameraModeChanged {
      // A ride starting is the one automatic transition back into follow mode.
      // Subsequent snapshots preserve a deliberate pan until the rider taps
      // recenter, while waiting-to-start remains a route overview like the
      // phone map.
      followsLocalRider = requestedRiderFollow
    }
    // The ride's own marker carries the exact identity symbol and colour the
    // rider chose on the phone. Do not replace it with MapLibre's unrelated
    // blue location dot while snapshots settle.
    mapView.showsUserLocation = false
    if requestedRiderFollow, localCoordinate != nil, followsLocalRider {
      recenter()
    } else if routeChanged || cameraModeChanged {
      showCompleteRoute()
    }
  }

  /// Applies the camera the phone actually commanded, rather than independently
  /// planning a second navigation camera on the head unit. The target already
  /// includes the phone's look-ahead; only the zoom is adjusted for CarPlay's
  /// different viewport height so both screens cover the same ground distance.
  func apply(viewport: [String: Any]) {
    latestViewport = viewport
    if
      let rawStyleURL = viewport["mapStyleUrl"] as? String,
      let styleURL = URL(string: rawStyleURL)
    {
      phoneStyleURL = styleURL
      applyPreferredStyle()
    }
    guard snapshotWantsRiderFollow, followsLocalRider else { return }
    applyPhoneViewport(animated: true)
  }

  /// Uses the resolved style document from the phone, not another fetch of the
  /// URL it originally came from. The phone may be rendering a normalised,
  /// cached or dark-mode-repainted document, so loading the URL again can give
  /// CarPlay visibly different roads, labels and tiles.
  func apply(mapStyle: [String: Any]) {
    guard
      let styleJSON = mapStyle["styleJson"] as? String,
      !styleJSON.isEmpty
    else { return }
    phoneStyleJSON = styleJSON
    if
      let rawURL = mapStyle["fallbackStyleUrl"] as? String,
      let fallbackURL = URL(string: rawURL)
    {
      phoneStyleURL = fallbackURL
    }
    applyPreferredStyle()
    if let latestSnapshot {
      groupMiniMap.apply(
        snapshot: latestSnapshot,
        styleURL: preferredStyleURL,
        styleJSON: phoneStyleJSON,
        force: true
      )
    }
  }

  func recenter() {
    followsLocalRider = true
    if snapshotWantsRiderFollow, latestViewport != nil {
      applyPhoneViewport(animated: true)
      return
    }
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
    let selected =
      (basemap["selectedStyleUrl"] as? String).flatMap(URL.init(string:))
    guard light != nil || dark != nil else { return }
    lightStyleURL = light ?? dark
    darkStyleURL = dark ?? light
    phoneStyleURL = selected
    if let styleJSON = basemap["styleJson"] as? String, !styleJSON.isEmpty {
      phoneStyleJSON = styleJSON
    }
    applyPreferredStyle()
  }

  private func applyPreferredStyle() {
    if let preferredJSON = phoneStyleJSON {
      guard preferredJSON != appliedStyleJSON else { return }
      appliedStyleJSON = preferredJSON
      appliedStyleURL = nil
      guard let mapView else {
        installMapView(styleJSON: preferredJSON)
        return
      }
      mapView.styleJSON = preferredJSON
      return
    }
    let preferred = phoneStyleURL
      ?? (traitCollection.userInterfaceStyle == .dark ? darkStyleURL : lightStyleURL)
    guard let preferred, preferred != appliedStyleURL else { return }
    appliedStyleURL = preferred
    appliedStyleJSON = nil
    guard let mapView else {
      installMapView(styleURL: preferred)
      return
    }
    mapView.styleURL = preferred
  }

  private var preferredStyleURL: URL? {
    phoneStyleURL
      ?? (traitCollection.userInterfaceStyle == .dark ? darkStyleURL : lightStyleURL)
  }

  private func installMapView(styleURL: URL) {
    let mapView = MLNMapView(frame: view.bounds, styleURL: styleURL)
    configure(mapView)
  }

  private func installMapView(styleJSON: String) {
    let mapView = MLNMapView(frame: view.bounds, styleJSON: styleJSON)
    configure(mapView)
  }

  private func configure(_ mapView: MLNMapView) {
    mapView.delegate = self
    mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // The phone's own rider badge is projected below. A second system location
    // dot has different styling and briefly duplicates the rider while the
    // first group snapshot arrives.
    mapView.showsUserLocation = false
    mapView.userTrackingMode = .none
    // The logo goes, as it does on every phone surface (`logoEnabled: false`);
    // the attribution button stays, because that is a licence condition rather
    // than decoration. CarPlay owns the bottom-trailing corner for its own map
    // buttons, so what remains sits on the other side.
    mapView.logoView.isHidden = true
    mapView.attributionButtonPosition = .bottomLeft
    mapView.compassViewPosition = .topRight
    view.insertSubview(mapView, at: 0)
    self.mapView = mapView
    if let latestSnapshot { apply(snapshot: latestSnapshot) }
    if let latestViewport { apply(viewport: latestViewport) }
  }

  private func applyPhoneViewport(animated: Bool) {
    guard
      let mapView,
      mapView.bounds.height > 0,
      let viewport = latestViewport,
      let latitude = (viewport["latitude"] as? NSNumber)?.doubleValue,
      let longitude = (viewport["longitude"] as? NSNumber)?.doubleValue,
      let phoneZoom = (viewport["zoom"] as? NSNumber)?.doubleValue,
      let phoneHeight = (viewport["sourceViewportHeightPixels"] as? NSNumber)?.doubleValue,
      phoneHeight > 0,
      latitude.isFinite,
      longitude.isFinite,
      phoneZoom.isFinite,
      (-90 ... 90).contains(latitude),
      (-180 ... 180).contains(longitude)
    else { return }

    let heightRatio = Double(mapView.bounds.height) / phoneHeight
    guard heightRatio.isFinite, heightRatio > 0 else { return }
    let adjustedZoom = phoneZoom + log2(heightRatio)
    let rawTilt = (viewport["tilt"] as? NSNumber)?.doubleValue ?? 0
    let tilt = min(60, max(0, rawTilt))
    let bearing = (viewport["bearing"] as? NSNumber)?.doubleValue ?? 0
    guard adjustedZoom.isFinite, tilt.isFinite, bearing.isFinite else { return }

    // MapLibre's zoom is the scale of 512 px Web Mercator tiles. Convert that
    // scale back to the MLNMapCamera altitude API while preserving the phone's
    // pitch and look-ahead target.
    let latitudeRadians = latitude * .pi / 180
    let metresPerPoint =
      78_271.516_964_020_48 * abs(cos(latitudeRadians)) / pow(2, adjustedZoom)
    let fieldOfView = 0.643_501_108_793_284_4
    let cameraToCenterDistance =
      Double(mapView.bounds.height) * 0.5 / tan(fieldOfView * 0.5)
    let altitude = cameraToCenterDistance * metresPerPoint * cos(tilt * .pi / 180)
    guard altitude.isFinite, altitude > 0 else { return }

    mapView.userTrackingMode = .none
    let camera = MLNMapCamera(
      lookingAtCenter: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      altitude: altitude,
      pitch: tilt,
      heading: bearing
    )
    mapView.setCamera(camera, animated: animated)
  }

  /// MapKit's follow mode picks an altitude for you; MapLibre's only recentres
  /// and keeps whatever zoom the map already had. Left alone that framed the
  /// head unit on the whole world and then politely centred the whole world on
  /// the rider. Setting the zoom up front is worse still - with no fix yet the
  /// default centre is null island, so the canvas is featureless grey - so the
  /// driving zoom is taken on the first fix instead, once and only once.
  func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
    guard
      !hasFramedFirstFix,
      let coordinate = userLocation?.location?.coordinate,
      CLLocationCoordinate2DIsValid(coordinate)
    else { return }
    hasFramedFirstFix = true
    guard followsLocalRider, localCoordinate == nil else { return }
    mapView.setCenter(coordinate, zoomLevel: 14, animated: true)
  }

  func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
    // A style load takes the annotations with it. Put the ride back on.
    var previousAnnotations = riderAnnotations.map { $0 as MLNAnnotation }
    for annotation in [
      travelledRouteCasingAnnotation,
      travelledRouteAnnotation,
    ].compactMap({ $0 }) {
      previousAnnotations.append(annotation)
    }
    if !previousAnnotations.isEmpty {
      // MapLibre normally clears these during the style swap. Removing the
      // retained objects as well closes the short timing window where a
      // snapshot lands between the swap and this callback and would otherwise
      // leave two local-rider badges on the CarPlay map.
      mapView.removeAnnotations(previousAnnotations)
    }
    routeSource = nil
    travelledRouteAnnotation = nil
    travelledRouteCasingAnnotation = nil
    riderAnnotations = []
    routeID = nil
    routeProjectionKey = nil
    if let latestSnapshot { apply(snapshot: latestSnapshot) }
    if let latestViewport { apply(viewport: latestViewport) }
  }

  // MARK: - Content

  private func updateRoute(_ raw: Any?, remaining: Any?, travelled: Any?) {
    guard let mapView else { return }
    for existing in [
      travelledRouteCasingAnnotation,
      travelledRouteAnnotation,
    ].compactMap({ $0 }) {
      mapView.removeAnnotation(existing)
    }
    var allPoints = (raw as? [[String: Any]] ?? []).compactMap(coordinate(from:))
    guard allPoints.count >= 2 else {
      routeCoordinates = []
      routeSource?.shape = nil
      travelledRouteAnnotation = nil
      travelledRouteCasingAnnotation = nil
      return
    }
    routeCoordinates = allPoints
    var remainingPoints =
      (remaining as? [[String: Any]] ?? []).compactMap(coordinate(from:))
    var travelledPoints =
      (travelled as? [[String: Any]] ?? []).compactMap(coordinate(from:))
    if remainingPoints.count < 2 && travelledPoints.count < 2 {
      remainingPoints = allPoints
    }
    updateRemainingRoute(remainingPoints)

    var annotations: [MLNPolyline] = []
    if travelledPoints.count >= 2 {
      let casing = MLNPolyline(
        coordinates: &travelledPoints,
        count: UInt(travelledPoints.count)
      )
      let polyline = MLNPolyline(
        coordinates: &travelledPoints,
        count: UInt(travelledPoints.count)
      )
      travelledRouteCasingAnnotation = casing
      travelledRouteAnnotation = polyline
      annotations.append(contentsOf: [casing, polyline])
    } else {
      travelledRouteCasingAnnotation = nil
      travelledRouteAnnotation = nil
    }
    if !annotations.isEmpty { mapView.addAnnotations(annotations) }
  }

  /// The phone's route ahead is a long dash, not a solid line. Shape
  /// annotations have no dash property, so this one part of the route uses two
  /// MapLibre style layers over a shared source: an aligned dashed casing and
  /// the aligned green stroke above it. Travelled geometry remains a solid
  /// annotation and therefore keeps the same draw order as the phone.
  private func updateRemainingRoute(_ points: [CLLocationCoordinate2D]) {
    guard let mapView, let style = mapView.style else { return }
    let sourceIdentifier = "tailendcharlie-route-ahead-source"
    let casingIdentifier = "tailendcharlie-route-ahead-casing"
    let lineIdentifier = "tailendcharlie-route-ahead-line"
    let source: MLNShapeSource
    if let routeSource {
      source = routeSource
    } else if
      let existing = style.source(withIdentifier: sourceIdentifier)
        as? MLNShapeSource
    {
      routeSource = existing
      source = existing
    } else {
      let created = MLNShapeSource(
        identifier: sourceIdentifier,
        shape: nil,
        options: nil
      )
      style.addSource(created)
      routeSource = created
      source = created
    }

    if style.layer(withIdentifier: casingIdentifier) == nil {
      let casing = MLNLineStyleLayer(
        identifier: casingIdentifier,
        source: source
      )
      casing.lineColor = NSExpression(forConstantValue: CarPlayPalette.casing)
      casing.lineWidth = NSExpression(
        forConstantValue: CarPlayPalette.routeCasingWidth
      )
      casing.lineDashPattern = NSExpression(forConstantValue: [2.2, 1.1])
      casing.lineCap = NSExpression(forConstantValue: "round")
      casing.lineJoin = NSExpression(forConstantValue: "round")
      style.addLayer(casing)
    }

    if style.layer(withIdentifier: lineIdentifier) == nil {
      let line = MLNLineStyleLayer(
        identifier: lineIdentifier,
        source: source
      )
      line.lineColor = NSExpression(forConstantValue: CarPlayPalette.routeAhead)
      line.lineWidth = NSExpression(forConstantValue: CarPlayPalette.routeWidth)
      line.lineDashPattern = NSExpression(
        forConstantValue: [22.0 / 6.0, 11.0 / 6.0]
      )
      line.lineCap = NSExpression(forConstantValue: "round")
      line.lineJoin = NSExpression(forConstantValue: "round")
      style.addLayer(line)
    }

    guard points.count >= 2 else {
      source.shape = nil
      return
    }
    var coordinates = points
    source.shape = MLNPolyline(
      coordinates: &coordinates,
      count: UInt(coordinates.count)
    )
  }

  private func updateRiders(_ snapshot: [String: Any]) {
    guard let mapView else { return }
    if !riderAnnotations.isEmpty {
      mapView.removeAnnotations(riderAnnotations)
      riderAnnotations = []
    }
    localCoordinate = nil
    localHeading = nil
    var riders = snapshot["riders"] as? [[String: Any]] ?? []
    if let projectedLocal = snapshot["localRider"] as? [String: Any] {
      let localID = projectedLocal["riderId"] as? String
      if
        let index = riders.firstIndex(where: {
          ($0["riderId"] as? String) == localID
        })
      {
        riders[index].merge(projectedLocal) { _, localValue in localValue }
      } else {
        riders.append(projectedLocal)
      }
    }
    for rider in riders {
      guard let coordinate = coordinate(from: rider) else { continue }
      let isLocal = (rider["isLocal"] as? NSNumber)?.boolValue ?? false
      let annotation = CarPlayRiderAnnotation(
        coordinate: coordinate,
        title: rider["label"] as? String ?? "Rider",
        subtitle: rider["role"] as? String,
        isLocal: isLocal,
        isTec: (rider["isTec"] as? NSNumber)?.boolValue ?? false,
        needsAttention: (rider["needsAttention"] as? NSNumber)?.boolValue ?? false,
        riderSymbol: rider["riderSymbol"] as? String ?? "motorcycle",
        motorcycleStyle: rider["motorcycleStyle"] as? String ?? "adventureTourer",
        riderColor: rider["riderColor"] as? String ?? "green"
      )
      riderAnnotations.append(annotation)
      if isLocal {
        localCoordinate = coordinate
        localHeading = (rider["headingDegrees"] as? NSNumber)?.doubleValue
      }
    }
    if
      localCoordinate == nil,
      let projectedPosition = snapshot["localPosition"] as? [String: Any],
      let coordinate = coordinate(from: projectedPosition)
    {
      localCoordinate = coordinate
      localHeading = (projectedPosition["headingDegrees"] as? NSNumber)?.doubleValue
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
    guard routeCoordinates.count >= 2 else {
      mapView.userTrackingMode = .none
      if let localCoordinate {
        mapView.setCenter(localCoordinate, zoomLevel: 14, animated: true)
      }
      return
    }
    mapView.userTrackingMode = .none
    // Fit the route's actual coordinates. `MLNPolyline.overlayBounds` can
    // still report the style's default world-sized bounds while an annotation
    // is being installed during the CarPlay scene's first layout; using it is
    // what reduced a 17.5 km demo route to a tiny mark on a UK-wide map.
    var coordinates = routeCoordinates
    mapView.setVisibleCoordinates(
      &coordinates,
      count: UInt(coordinates.count),
      edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
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

  // MARK: - MLNMapViewDelegate

  func mapView(
    _ mapView: MLNMapView,
    strokeColorForShapeAnnotation annotation: MLNShape
  ) -> UIColor {
    if annotation === travelledRouteCasingAnnotation { return CarPlayPalette.casing }
    if annotation === travelledRouteAnnotation { return CarPlayPalette.travelled }
    return .clear
  }

  func mapView(
    _ mapView: MLNMapView,
    lineWidthForPolylineAnnotation annotation: MLNPolyline
  ) -> CGFloat {
    if annotation === travelledRouteCasingAnnotation {
      return CarPlayPalette.travelledCasingWidth
    }
    if annotation === travelledRouteAnnotation { return CarPlayPalette.travelledWidth }
    return CarPlayPalette.routeWidth
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
  let riderSymbol: String
  let motorcycleStyle: String
  let riderColor: String

  init(
    coordinate: CLLocationCoordinate2D,
    title: String,
    subtitle: String?,
    isLocal: Bool,
    isTec: Bool,
    needsAttention: Bool,
    riderSymbol: String,
    motorcycleStyle: String,
    riderColor: String
  ) {
    self.coordinate = coordinate
    self.title = title
    self.subtitle = subtitle
    self.isLocal = isLocal
    self.isTec = isTec
    self.needsAttention = needsAttention
    self.riderSymbol = riderSymbol
    self.motorcycleStyle = motorcycleStyle
    self.riderColor = riderColor
  }
}

/// One rider on the CarPlay map.
///
/// This is deliberately the same circular identity badge as the phone: chosen
/// colour plus chosen bike, initials or emoji. Local identity is no longer
/// replaced by a CarPlay-only blue "You" pill, and role never replaces the
/// colour a rider selected for every other surface.
private final class CarPlayRiderAnnotationView: MLNAnnotationView {
  private let label = UILabel()
  private let imageView = UIImageView()

  init(reuseIdentifier: String) {
    super.init(reuseIdentifier: reuseIdentifier)
    isEnabled = false
    frame = CGRect(x: 0, y: 0, width: 38, height: 38)
    layer.cornerRadius = 19
    layer.cornerCurve = .continuous
    layer.borderWidth = 2
    layer.borderColor = CarPlayPalette.casing.cgColor
    label.font = .systemFont(ofSize: 30, weight: .heavy)
    label.textColor = CarPlayPalette.markerGlyph
    label.textAlignment = .center
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.45
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = CarPlayPalette.markerGlyph
    addSubview(label)
    addSubview(imageView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds.insetBy(dx: 2.5, dy: 2.5)
    imageView.frame = bounds.insetBy(dx: 7, dy: 7)
  }

  func apply(_ rider: CarPlayRiderAnnotation) {
    frame = CGRect(x: 0, y: 0, width: 38, height: 38)
    layer.cornerRadius = 19
    backgroundColor = identityColor(named: rider.riderColor)
    layer.borderColor = CarPlayPalette.casing.cgColor
    label.text = nil
    label.attributedText = nil
    imageView.image = nil

    if rider.riderSymbol == "initials" {
      let initials = riderInitials(rider.title ?? "")
      label.attributedText = NSAttributedString(
        string: initials,
        attributes: [.kern: -0.8]
      )
      label.font = .systemFont(ofSize: 30, weight: .black)
    } else if rider.riderSymbol.hasPrefix("emoji:") {
      label.text = String(rider.riderSymbol.dropFirst("emoji:".count))
      label.font = .systemFont(ofSize: 21)
    } else {
      imageView.image = motorcycleImage(for: rider.motorcycleStyle)
    }
    setNeedsLayout()
  }

  private func riderInitials(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0.isWhitespace })
    guard let first = words.first else { return "?" }
    if words.count == 1 { return String(first.prefix(2)).uppercased() }
    return "\(first.prefix(1))\(words.last!.prefix(1))".uppercased()
  }

  private func identityColor(named name: String) -> UIColor {
    switch name {
    case "orange": return UIColor(red: 0xFF / 255, green: 0x9F / 255, blue: 0x5A / 255, alpha: 1)
    case "yellow": return UIColor(red: 0xE8 / 255, green: 0xD2 / 255, blue: 0x4C / 255, alpha: 1)
    case "teal": return UIColor(red: 0x4F / 255, green: 0xC7 / 255, blue: 0xC7 / 255, alpha: 1)
    case "pink": return UIColor(red: 0xE8 / 255, green: 0x7F / 255, blue: 0xC0 / 255, alpha: 1)
    case "cyan": return UIColor(red: 0x5A / 255, green: 0xC8 / 255, blue: 0xFA / 255, alpha: 1)
    case "amber": return UIColor(red: 0xD9 / 255, green: 0xA4 / 255, blue: 0x41 / 255, alpha: 1)
    case "crimson": return UIColor(red: 0xD9 / 255, green: 0x60 / 255, blue: 0x7A / 255, alpha: 1)
    default: return CarPlayPalette.rider
    }
  }

  private func motorcycleImage(for style: String) -> UIImage? {
    let fileName = Self.motorcycleFiles[style] ?? "00_adventure_tourer"
    let asset = "assets/icons/motorcycles/\(fileName).png"
    let key = FlutterDartProject.lookupKey(forAsset: asset)
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
      return UIImage(systemName: "motorcycle.fill")?.withRenderingMode(.alwaysTemplate)
    }
    return UIImage(contentsOfFile: path)?.withRenderingMode(.alwaysTemplate)
  }

  private static let motorcycleFiles = [
    "adventureTourer": "00_adventure_tourer",
    "roadster": "01_roadster",
    "dualSport": "02_dual_sport",
    "sportNaked": "03_sport_naked",
    "cruiserClassic": "04_cruiser_classic",
    "standardTwin": "05_standard_twin",
    "cafeRacer": "06_cafe_racer",
    "dirtBike": "07_dirt_bike",
    "fullTourer": "08_full_tourer",
    "cruiserBagger": "09_cruiser_bagger",
    "scrambler": "10_scrambler",
    "sportTouring": "11_sport_touring",
    "scooter": "12_scooter",
    "sidecarRig": "13_sidecar_rig",
    "streetFighter": "14_street_fighter",
  ]
}

/// A low-frequency overview of the whole group while the main map stays in the
/// phone's navigation viewport. It uses MapLibre's snapshotter instead of a
/// second live renderer: the tiles still come from the phone's exact resolved
/// style and shared cache, but a long ride does not pay to animate two maps at
/// every GPS fix.
private final class CarPlayGroupMiniMapView: UIView {
  private struct Rider {
    let coordinate: CLLocationCoordinate2D
    let color: UIColor
    let isLocal: Bool
    let isTec: Bool
  }

  private let imageView = UIImageView()
  private let caption = UILabel()
  private var snapshotter: MLNMapSnapshotter?
  private var lastRenderedAt: Date?
  private var lastStyleJSON: String?
  private var cachedStyleURL: URL?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isHidden = true
    isUserInteractionEnabled = false
    backgroundColor = CarPlayPalette.cardFill
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    layer.borderWidth = 1.5
    layer.borderColor = CarPlayPalette.casing.cgColor
    clipsToBounds = true

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    addSubview(imageView)

    caption.translatesAutoresizingMaskIntoConstraints = false
    caption.font = .systemFont(ofSize: 11, weight: .bold)
    caption.textColor = CarPlayPalette.cardTitle
    caption.backgroundColor = CarPlayPalette.cardFill
    caption.layer.cornerRadius = 6
    caption.layer.cornerCurve = .continuous
    caption.clipsToBounds = true
    caption.textAlignment = .center
    addSubview(caption)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      caption.heightAnchor.constraint(equalToConstant: 19),
      caption.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(
    snapshot: [String: Any],
    styleURL: URL?,
    styleJSON: String?,
    force: Bool = false
  ) {
    let riders = projectedRiders(from: snapshot)
    var route = (snapshot["remainingRoutePoints"] as? [[String: Any]] ?? [])
      .compactMap(Self.coordinate(from:))
    if route.count < 2 {
      route = (snapshot["routePoints"] as? [[String: Any]] ?? [])
        .compactMap(Self.coordinate(from:))
    }
    guard !riders.isEmpty else {
      isHidden = true
      snapshotter?.cancel()
      snapshotter = nil
      return
    }

    isHidden = false
    let riderWord = riders.count == 1 ? "rider" : "riders"
    caption.text = "  Group · \(riders.count) \(riderWord)  "
    accessibilityLabel = "Group overview, \(riders.count) \(riderWord)"

    let now = Date()
    if !force,
      snapshotter != nil
        || lastRenderedAt.map({ now.timeIntervalSince($0) < 3 }) == true
    {
      return
    }
    if force {
      snapshotter?.cancel()
      snapshotter = nil
      lastRenderedAt = nil
    }
    guard let resolvedStyleURL = resolvedStyleURL(json: styleJSON, fallback: styleURL)
    else { return }

    let bounds = Self.groupBounds(for: riders.map(\.coordinate))
    let camera = MLNMapCamera(
      lookingAtCenter: CLLocationCoordinate2D(
        latitude: (bounds.sw.latitude + bounds.ne.latitude) / 2,
        longitude: (bounds.sw.longitude + bounds.ne.longitude) / 2
      ),
      altitude: 2_000,
      pitch: 0,
      heading: 0
    )
    let options = MLNMapSnapshotOptions(
      styleURL: resolvedStyleURL,
      camera: camera,
      size: CGSize(width: 110, height: 70)
    )
    options.coordinateBounds = bounds
    options.showsLogo = false
    options.showsAttribution = false
    options.scale = min(2, UIScreen.main.scale)

    let snapshotter = MLNMapSnapshotter(options: options)
    self.snapshotter = snapshotter
    snapshotter.start(
      overlayHandler: { overlay in
        Self.draw(route: route, riders: riders, on: overlay)
      },
      completionHandler: { [weak self, weak snapshotter] snapshot, _ in
        guard let self, self.snapshotter === snapshotter else { return }
        self.snapshotter = nil
        self.lastRenderedAt = Date()
        if let image = snapshot?.image {
          self.imageView.image = image
        }
      }
    )
  }

  private func resolvedStyleURL(json: String?, fallback: URL?) -> URL? {
    guard let json, !json.isEmpty else { return fallback }
    if json == lastStyleJSON, let cachedStyleURL { return cachedStyleURL }
    guard
      let directory = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    else { return fallback }
    let file = directory.appendingPathComponent("carplay-group-map-style.json")
    do {
      try Data(json.utf8).write(to: file, options: .atomic)
      lastStyleJSON = json
      cachedStyleURL = file
      return file
    } catch {
      return fallback
    }
  }

  private func projectedRiders(from snapshot: [String: Any]) -> [Rider] {
    var rawRiders = snapshot["riders"] as? [[String: Any]] ?? []
    if let local = snapshot["localRider"] as? [String: Any] {
      let localID = local["riderId"] as? String
      if
        let index = rawRiders.firstIndex(where: {
          ($0["riderId"] as? String) == localID
        })
      {
        rawRiders[index].merge(local) { _, localValue in localValue }
      } else {
        rawRiders.append(local)
      }
    }
    return rawRiders.compactMap { raw in
      guard let coordinate = Self.coordinate(from: raw) else { return nil }
      return Rider(
        coordinate: coordinate,
        color: Self.identityColor(named: raw["riderColor"] as? String),
        isLocal: (raw["isLocal"] as? NSNumber)?.boolValue ?? false,
        isTec: (raw["isTec"] as? NSNumber)?.boolValue ?? false
      )
    }
  }

  private static func groupBounds(
    for coordinates: [CLLocationCoordinate2D]
  ) -> MLNCoordinateBounds {
    let latitudes = coordinates.map(\.latitude)
    let longitudes = coordinates.map(\.longitude)
    let minimumLatitude = latitudes.min() ?? 0
    let maximumLatitude = latitudes.max() ?? 0
    let minimumLongitude = longitudes.min() ?? 0
    let maximumLongitude = longitudes.max() ?? 0
    let latitudeSpan = max(0.004, maximumLatitude - minimumLatitude)
    let middleLatitude = (minimumLatitude + maximumLatitude) / 2
    let longitudeScale = max(0.25, abs(cos(middleLatitude * .pi / 180)))
    let longitudeSpan = max(0.004 / longitudeScale, maximumLongitude - minimumLongitude)
    let latitudePadding = latitudeSpan * 0.38
    let longitudePadding = longitudeSpan * 0.38
    return MLNCoordinateBoundsMake(
      CLLocationCoordinate2D(
        latitude: max(-90, minimumLatitude - latitudePadding),
        longitude: max(-180, minimumLongitude - longitudePadding)
      ),
      CLLocationCoordinate2D(
        latitude: min(90, maximumLatitude + latitudePadding),
        longitude: min(180, maximumLongitude + longitudePadding)
      )
    )
  }

  private static func draw(
    route: [CLLocationCoordinate2D],
    riders: [Rider],
    on overlay: MLNMapSnapshotOverlay
  ) {
    let context = overlay.context
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: CGRect(x: 0, y: 0, width: 110, height: 70))

    if route.count >= 2 {
      let points = route.map(overlay.point(for:))
      context.setLineCap(.round)
      context.setLineJoin(.round)
      addPath(points, to: context)
      context.setStrokeColor(CarPlayPalette.casing.cgColor)
      context.setLineWidth(6)
      context.setLineDash(phase: 0, lengths: [7, 4])
      context.strokePath()
      addPath(points, to: context)
      context.setStrokeColor(CarPlayPalette.routeAhead.cgColor)
      context.setLineWidth(3.5)
      context.setLineDash(phase: 0, lengths: [7, 4])
      context.strokePath()
    }

    context.setLineDash(phase: 0, lengths: [])
    for rider in riders {
      let point = overlay.point(for: rider.coordinate)
      let radius: CGFloat = rider.isLocal ? 7 : 6
      let rect = CGRect(
        x: point.x - radius,
        y: point.y - radius,
        width: radius * 2,
        height: radius * 2
      )
      if rider.isTec {
        context.setStrokeColor(CarPlayPalette.tailEndCharlie.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect.insetBy(dx: -3, dy: -3))
      }
      context.setFillColor(rider.color.cgColor)
      context.fillEllipse(in: rect)
      context.setStrokeColor(
        (rider.isLocal ? UIColor.white : CarPlayPalette.casing).cgColor
      )
      context.setLineWidth(rider.isLocal ? 2.5 : 2)
      context.strokeEllipse(in: rect)
    }
  }

  private static func addPath(_ points: [CGPoint], to context: CGContext) {
    guard let first = points.first else { return }
    context.beginPath()
    context.move(to: first)
    for point in points.dropFirst() { context.addLine(to: point) }
  }

  private static func coordinate(from raw: [String: Any]) -> CLLocationCoordinate2D? {
    guard
      let latitude = (raw["latitude"] as? NSNumber)?.doubleValue,
      let longitude = (raw["longitude"] as? NSNumber)?.doubleValue,
      (-90 ... 90).contains(latitude),
      (-180 ... 180).contains(longitude)
    else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private static func identityColor(named name: String?) -> UIColor {
    switch name {
    case "orange": return UIColor(red: 1, green: 0x9F / 255, blue: 0x5A / 255, alpha: 1)
    case "yellow": return UIColor(red: 0xE8 / 255, green: 0xD2 / 255, blue: 0x4C / 255, alpha: 1)
    case "teal": return UIColor(red: 0x4F / 255, green: 0xC7 / 255, blue: 0xC7 / 255, alpha: 1)
    case "pink": return UIColor(red: 0xE8 / 255, green: 0x7F / 255, blue: 0xC0 / 255, alpha: 1)
    case "cyan": return UIColor(red: 0x5A / 255, green: 0xC8 / 255, blue: 0xFA / 255, alpha: 1)
    case "amber": return UIColor(red: 0xD9 / 255, green: 0xA4 / 255, blue: 0x41 / 255, alpha: 1)
    case "crimson": return UIColor(red: 0xD9 / 255, green: 0x60 / 255, blue: 0x7A / 255, alpha: 1)
    default: return CarPlayPalette.rider
    }
  }
}

/// The phone's landscape speed-limit sign and current-speed readout, scaled for
/// CarPlay's shorter map canvas. The upper number is always the mapped UK mph
/// limit and the number below is always GPS speed in mph, just as on the phone.
private final class CarPlaySpeedLimitBadge: UIView {
  private let sign = UIView()
  private let limitLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let speedLabel = UILabel()

  init() {
    super.init(frame: .zero)
    isHidden = true
    isUserInteractionEnabled = false

    sign.translatesAutoresizingMaskIntoConstraints = false
    sign.backgroundColor = .white
    sign.layer.cornerRadius = 17
    sign.layer.borderWidth = 4
    sign.layer.shadowColor = UIColor.black.cgColor
    sign.layer.shadowOpacity = 0.4
    sign.layer.shadowRadius = 4
    sign.layer.shadowOffset = CGSize(width: 0, height: 2)
    addSubview(sign)

    limitLabel.translatesAutoresizingMaskIntoConstraints = false
    limitLabel.font = .systemFont(ofSize: 18, weight: .black)
    limitLabel.textColor = UIColor(
      red: 0x11 / 255,
      green: 0x11 / 255,
      blue: 0x11 / 255,
      alpha: 1
    )
    limitLabel.textAlignment = .center
    limitLabel.adjustsFontSizeToFitWidth = true
    limitLabel.minimumScaleFactor = 0.7
    sign.addSubview(limitLabel)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = UIColor(
      red: 0x30 / 255,
      green: 0x34 / 255,
      blue: 0x3B / 255,
      alpha: 1
    )
    sign.addSubview(spinner)

    speedLabel.translatesAutoresizingMaskIntoConstraints = false
    speedLabel.textAlignment = .center
    speedLabel.adjustsFontSizeToFitWidth = true
    speedLabel.minimumScaleFactor = 0.7
    addSubview(speedLabel)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 44),
      heightAnchor.constraint(equalToConstant: 58),
      sign.widthAnchor.constraint(equalToConstant: 34),
      sign.heightAnchor.constraint(equalToConstant: 34),
      sign.topAnchor.constraint(equalTo: topAnchor),
      sign.centerXAnchor.constraint(equalTo: centerXAnchor),
      limitLabel.leadingAnchor.constraint(equalTo: sign.leadingAnchor, constant: 4),
      limitLabel.trailingAnchor.constraint(equalTo: sign.trailingAnchor, constant: -4),
      limitLabel.centerYAnchor.constraint(equalTo: sign.centerYAnchor),
      spinner.centerXAnchor.constraint(equalTo: sign.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: sign.centerYAnchor),
      speedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      speedLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      speedLabel.topAnchor.constraint(equalTo: sign.bottomAnchor, constant: 2),
      speedLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(_ speed: [String: Any]?) {
    guard let speed else {
      isHidden = true
      spinner.stopAnimating()
      return
    }
    isHidden = false

    let status = speed["limitStatus"] as? String
    let limit = (speed["limitMilesPerHour"] as? NSNumber)?.intValue
    let unlimited = (speed["limitUnlimited"] as? NSNumber)?.boolValue ?? false
    let known = status == "known" && (limit != nil || unlimited)
    let checking = status == "checking"
    limitLabel.isHidden = checking
    if checking {
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
      limitLabel.text = known ? (unlimited ? "∞" : "\(limit!)") : "–"
    }
    sign.layer.borderColor = (
      known
        ? UIColor(red: 0xD7 / 255, green: 0x19 / 255, blue: 0x20 / 255, alpha: 1)
        : UIColor(red: 0x89 / 255, green: 0x93 / 255, blue: 0xA0 / 255, alpha: 1)
    ).cgColor

    let metresPerSecond = (speed["metresPerSecond"] as? NSNumber)?.doubleValue
    let milesPerHour = metresPerSecond.flatMap { value in
      value.isFinite && value >= 0 ? Int((value * 2.236_936).rounded()) : nil
    }
    let currentSpeed = milesPerHour.map(String.init) ?? "–"
    speedLabel.attributedText = NSAttributedString(
      string: currentSpeed,
      attributes: [
        .font: UIFont.systemFont(ofSize: 18, weight: .black),
        .foregroundColor: UIColor.white,
        .strokeColor: UIColor.black.withAlphaComponent(0.9),
        .strokeWidth: -3,
      ]
    )
    let ageing = (speed["isAgeing"] as? NSNumber)?.boolValue ?? false
    speedLabel.alpha = ageing ? 0.55 : 1

    let limitDescription = known
      ? (unlimited ? "unrestricted" : "\(limit!) miles per hour")
      : "unavailable"
    let speedDescription = milesPerHour.map { "\($0) miles per hour" }
      ?? "unavailable"
    accessibilityLabel = "Mapped speed limit \(limitDescription). "
      + "Your GPS speed is \(speedDescription)."
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
    backgroundColor = CarPlayPalette.cardFill
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15, weight: .semibold)
    label.textColor = CarPlayPalette.cardTitle
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
    // The card keeps the app's own fill and the *ink* carries the state, for the
    // same reason the trend is a word and an arrow rather than a colour: a
    // tinted visor in daylight flattens these, and some riders cannot tell them
    // apart at all. The headline already says which state it is in words.
    switch tec["state"] as? String {
    case "none":
      label.textColor = CarPlayPalette.alerting
    case "stale", "awaitingLocation":
      label.textColor = CarPlayPalette.cardLabel
    default:
      label.textColor = CarPlayPalette.cardTitle
    }
  }
}
