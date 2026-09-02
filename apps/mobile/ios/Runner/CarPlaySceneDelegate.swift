import CarPlay
import CoreLocation
import Flutter
import MapLibre
import MapKit
import UIKit

/// Keeps asynchronous CarPlay template completions tied to the connection that
/// created them. A phone-side ride start can publish a navigation snapshot while
/// the head unit is still installing its root template; applying template state
/// before that completion, or accepting a completion from a disconnected scene,
/// can make CarPlay raise an Objective-C exception instead of returning an error.
struct CarPlaySceneLifecycle {
  private(set) var generation = 0
  private(set) var rootReady = false

  mutating func beginConnection() -> Int {
    generation &+= 1
    rootReady = false
    return generation
  }

  mutating func completeRootPresentation(
    generation completedGeneration: Int,
    succeeded: Bool
  ) -> Bool {
    guard completedGeneration == generation, succeeded else { return false }
    rootReady = true
    return true
  }

  mutating func disconnect() {
    generation &+= 1
    rootReady = false
  }
}

/// Converts the host's moving-vehicle restrictions into stable, testable
/// choices before templates are built. Route search needs both the keyboard
/// and a result list; essential ride/TEC/group rows remain when long lists are
/// restricted, while per-rider detail is omitted.
struct CarPlayInteractionPolicy: Equatable {
  let limitedUserInterfaces: CPLimitableUserInterface

  var allowsDestinationSearch: Bool {
    !limitedUserInterfaces.contains(.keyboard)
      && !limitedUserInterfaces.contains(.lists)
  }

  var allowsRiderRows: Bool {
    !limitedUserInterfaces.contains(.lists)
  }
}

/// One unit decision for every value Tail End Charlie gives CarPlay. An
/// explicit in-app preference wins; locale is only the restoration fallback
/// for an older snapshot that predates the units field.
struct CarPlayUnitPolicy: Equatable {
  let usesMiles: Bool

  init(distanceUnit: String?, localeIdentifier: String?) {
    if distanceUnit == "miles" {
      usesMiles = true
    } else if distanceUnit == "kilometres" {
      usesMiles = false
    } else {
      let locale = localeIdentifier.map(Locale.init(identifier:)) ?? .current
      usesMiles = locale.measurementSystem != .metric
    }
  }

  func distanceMeasurement(meters: Double) -> Measurement<UnitLength> {
    usesMiles
      ? Measurement(value: meters / 1_609.344, unit: .miles)
      : Measurement(value: meters, unit: .meters)
  }

  func speedValue(metersPerSecond: Double) -> Int {
    Int(
      (metersPerSecond * (usesMiles ? 2.236_936 : 3.6)).rounded()
    )
  }

  var spokenSpeedUnit: String {
    usesMiles ? "miles per hour" : "kilometres per hour"
  }
}

/// Converts the host-owned safe rectangle into MapLibre content insets. Kept
/// independent of any particular head-unit resolution so the same calculation
/// covers left/right driving layouts, compact displays, and wide screens.
struct CarPlayMapSafeArea: Equatable {
  let contentInsets: UIEdgeInsets

  init(viewBounds: CGRect, safeFrame: CGRect) {
    contentInsets = UIEdgeInsets(
      top: max(0, safeFrame.minY - viewBounds.minY),
      left: max(0, safeFrame.minX - viewBounds.minX),
      bottom: max(0, viewBounds.maxY - safeFrame.maxY),
      right: max(0, viewBounds.maxX - safeFrame.maxX)
    )
  }
}

/// The versioned, iOS-only navigation contract projected by Dart.
///
/// Decoding is intentionally strict at this boundary: rider-authored route
/// names and platform-channel values are bounded before a future coordinator
/// turns them into CarPlay templates. The legacy top-level snapshot remains the
/// active renderer during the migration tracked by #690–#698.
struct CarPlayNavigationProjectionV2: Equatable {
  struct Trip: Equatable {
    let id: String
    let routeChoiceID: String
    let name: String
    let trafficSide: String
  }

  struct Units: Equatable {
    let distance: String?
    let speed: String?
  }

  struct Position: Equatable {
    let latitude: Double
    let longitude: Double
  }

  struct Lane: Equatable {
    let indications: [String]
    let isValid: Bool
  }

  struct Maneuver: Equatable {
    let id: String
    let kind: String
    let direction: String
    let engineType: String
    let engineModifier: String?
    let instructionVariants: [String]
    let roadNameVariants: [String]
    let position: Position
    let exitNumber: Int?
    let trafficSide: String
    let distanceMeters: Double?
    let secondsRemaining: Double?
    let bearingBeforeDegrees: Double?
    let bearingAfterDegrees: Double?
    let departureBearingDegrees: Double?
    let stepCount: Int
    let lanes: [Lane]
  }

  let sourceID: String
  let sequence: Int
  let generatedAtMillis: Int64
  let ridePhase: String
  let navigationPhase: String
  let trip: Trip?
  let currentManeuver: Maneuver?
  let followingManeuver: Maneuver?
  let units: Units
  let localeIdentifier: String?

  init?(snapshot: [String: Any]) {
    guard
      let raw = snapshot["carplayNavigation"] as? [String: Any],
      Self.integer(raw["schemaVersion"]) == 2,
      let sourceID = Self.string(raw["sourceId"], maximumLength: 96),
      let sequence = Self.integer(raw["sequence"]),
      sequence > 0,
      let generatedAtMillis = Self.int64(raw["generatedAtMillis"]),
      generatedAtMillis >= 0,
      let ride = raw["rideLifecycle"] as? [String: Any],
      let ridePhase = Self.string(ride["phase"], maximumLength: 32),
      Self.ridePhases.contains(ridePhase),
      let navigation = raw["navigationLifecycle"] as? [String: Any],
      let navigationPhase = Self.string(navigation["phase"], maximumLength: 32),
      Self.navigationPhases.contains(navigationPhase),
      let rawUnits = raw["units"] as? [String: Any],
      let units = Self.units(rawUnits)
    else { return nil }

    let trip: Trip?
    if let rawTrip = raw["trip"] as? [String: Any] {
      guard let decoded = Self.trip(rawTrip) else { return nil }
      trip = decoded
    } else {
      trip = nil
    }
    if navigationPhase != "inactive", trip == nil { return nil }

    let currentManeuver: Maneuver?
    if let rawManeuver = raw["currentManeuver"] as? [String: Any] {
      guard let decoded = Self.maneuver(rawManeuver) else { return nil }
      currentManeuver = decoded
    } else {
      currentManeuver = nil
    }
    let followingManeuver: Maneuver?
    if let rawManeuver = raw["followingManeuver"] as? [String: Any] {
      guard let decoded = Self.maneuver(rawManeuver) else { return nil }
      followingManeuver = decoded
    } else {
      followingManeuver = nil
    }

    self.sourceID = sourceID
    self.sequence = sequence
    self.generatedAtMillis = generatedAtMillis
    self.ridePhase = ridePhase
    self.navigationPhase = navigationPhase
    self.trip = trip
    self.currentManeuver = currentManeuver
    self.followingManeuver = followingManeuver
    self.units = units
    self.localeIdentifier = Self.string(
      raw["localeIdentifier"],
      maximumLength: 48
    )
  }

  private static let ridePhases = Set([
    "home", "preRide", "activeRide", "endedRide",
  ])
  private static let navigationPhases = Set([
    "inactive", "routeReady", "navigating", "paused", "ended",
  ])
  private static let maneuverKinds = Set([
    "depart", "arrive", "roundabout", "turn", "endOfRoad", "merge",
    "fork", "onRamp", "offRamp", "useLane", "continueAhead",
  ])
  private static let maneuverDirections = Set([
    "sharpLeft", "left", "slightLeft", "straight", "slightRight", "right",
    "sharpRight", "uTurn", "unstated",
  ])
  private static let trafficSides = Set(["left", "right", "unknown"])

  private static func trip(_ raw: [String: Any]) -> Trip? {
    guard
      let id = string(raw["id"], maximumLength: 160),
      let routeChoiceID = string(raw["routeChoiceId"], maximumLength: 180),
      let name = string(raw["name"], maximumLength: 160),
      let trafficSide = string(raw["trafficSide"], maximumLength: 12),
      trafficSides.contains(trafficSide)
    else { return nil }
    return Trip(
      id: id,
      routeChoiceID: routeChoiceID,
      name: name,
      trafficSide: trafficSide
    )
  }

  private static func units(_ raw: [String: Any]) -> Units? {
    let distance = string(raw["distance"], maximumLength: 24)
    let speed = string(raw["speed"], maximumLength: 32)
    if let distance, !["miles", "kilometres"].contains(distance) { return nil }
    if let speed, !["milesPerHour", "kilometresPerHour"].contains(speed) {
      return nil
    }
    if (distance == "miles") != (speed == "milesPerHour"),
      distance != nil || speed != nil
    {
      return nil
    }
    return Units(distance: distance, speed: speed)
  }

  private static func maneuver(_ raw: [String: Any]) -> Maneuver? {
    guard
      let id = string(raw["id"], maximumLength: 220),
      let kind = string(raw["kind"], maximumLength: 32),
      maneuverKinds.contains(kind),
      let direction = string(raw["direction"], maximumLength: 32),
      maneuverDirections.contains(direction),
      let engineType = string(raw["engineType"], maximumLength: 80),
      let instructions = stringArray(
        raw["instructionVariants"],
        maximumCount: 4,
        maximumLength: 180
      ),
      !instructions.isEmpty,
      let roadNames = stringArray(
        raw["roadNameVariants"],
        maximumCount: 4,
        maximumLength: 160
      ),
      let rawPosition = raw["position"] as? [String: Any],
      let position = position(rawPosition),
      let trafficSide = string(raw["trafficSide"], maximumLength: 12),
      trafficSides.contains(trafficSide),
      let stepCount = integer(raw["stepCount"]),
      (1...32).contains(stepCount),
      let lanes = lanes(raw["lanes"])
    else { return nil }

    let exitNumber = integer(raw["exitNumber"])
    if let exitNumber, !(1...99).contains(exitNumber) { return nil }
    let distanceMeters = nonNegativeDouble(raw["distanceMeters"])
    if isPresent(raw["distanceMeters"]), distanceMeters == nil { return nil }
    let secondsRemaining = nonNegativeDouble(raw["secondsRemaining"])
    if isPresent(raw["secondsRemaining"]), secondsRemaining == nil { return nil }
    let bearingBefore = bearing(raw["bearingBeforeDegrees"])
    if isPresent(raw["bearingBeforeDegrees"]), bearingBefore == nil { return nil }
    let bearingAfter = bearing(raw["bearingAfterDegrees"])
    if isPresent(raw["bearingAfterDegrees"]), bearingAfter == nil { return nil }
    let departureBearing = bearing(raw["departureBearingDegrees"])
    if isPresent(raw["departureBearingDegrees"]), departureBearing == nil {
      return nil
    }

    return Maneuver(
      id: id,
      kind: kind,
      direction: direction,
      engineType: engineType,
      engineModifier: string(raw["engineModifier"], maximumLength: 80),
      instructionVariants: instructions,
      roadNameVariants: roadNames,
      position: position,
      exitNumber: exitNumber,
      trafficSide: trafficSide,
      distanceMeters: distanceMeters,
      secondsRemaining: secondsRemaining,
      bearingBeforeDegrees: bearingBefore,
      bearingAfterDegrees: bearingAfter,
      departureBearingDegrees: departureBearing,
      stepCount: stepCount,
      lanes: lanes
    )
  }

  private static func lanes(_ raw: Any?) -> [Lane]? {
    guard let values = raw as? [Any], values.count <= 8 else { return nil }
    var decoded: [Lane] = []
    for value in values {
      guard
        let lane = value as? [String: Any],
        let indications = stringArray(
          lane["indications"],
          maximumCount: 4,
          maximumLength: 32
        ),
        let valid = boolean(lane["valid"])
      else { return nil }
      decoded.append(Lane(indications: indications, isValid: valid))
    }
    return decoded
  }

  private static func position(_ raw: [String: Any]) -> Position? {
    guard
      let latitude = finiteDouble(raw["latitude"]),
      let longitude = finiteDouble(raw["longitude"]),
      (-90...90).contains(latitude),
      (-180...180).contains(longitude)
    else { return nil }
    return Position(latitude: latitude, longitude: longitude)
  }

  private static func stringArray(
    _ raw: Any?,
    maximumCount: Int,
    maximumLength: Int
  ) -> [String]? {
    guard let values = raw as? [Any], values.count <= maximumCount else {
      return nil
    }
    var decoded: [String] = []
    for value in values {
      guard let text = string(value, maximumLength: maximumLength) else {
        return nil
      }
      if !decoded.contains(text) { decoded.append(text) }
    }
    return decoded
  }

  private static func string(_ raw: Any?, maximumLength: Int) -> String? {
    guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return String(value.prefix(maximumLength))
  }

  private static func integer(_ raw: Any?) -> Int? {
    (raw as? NSNumber)?.intValue ?? raw as? Int
  }

  private static func int64(_ raw: Any?) -> Int64? {
    (raw as? NSNumber)?.int64Value ?? raw as? Int64
  }

  private static func boolean(_ raw: Any?) -> Bool? {
    (raw as? NSNumber)?.boolValue ?? raw as? Bool
  }

  private static func finiteDouble(_ raw: Any?) -> Double? {
    let value = (raw as? NSNumber)?.doubleValue ?? raw as? Double
    return value?.isFinite == true ? value : nil
  }

  private static func nonNegativeDouble(_ raw: Any?) -> Double? {
    guard let value = finiteDouble(raw), value >= 0 else { return nil }
    return value
  }

  private static func bearing(_ raw: Any?) -> Double? {
    guard let value = finiteDouble(raw), (0...360).contains(value) else {
      return nil
    }
    return value
  }

  private static func isPresent(_ raw: Any?) -> Bool {
    raw != nil && !(raw is NSNull)
  }
}

/// Rejects stale or replayed V2 messages without coupling navigation state to
/// the ride lifecycle. A newly-created Dart bridge can start at sequence one;
/// its newer generation timestamp is what safely takes ownership.
struct CarPlayNavigationProjectionStore {
  private(set) var latest: CarPlayNavigationProjectionV2?

  mutating func accept(snapshot: [String: Any]) -> Bool {
    guard let candidate = CarPlayNavigationProjectionV2(snapshot: snapshot) else {
      return false
    }
    if let latest {
      if candidate.sourceID == latest.sourceID {
        guard candidate.sequence > latest.sequence else { return false }
      } else {
        guard candidate.generatedAtMillis >= latest.generatedAtMillis else {
          return false
        }
      }
    }
    latest = candidate
    return true
  }
}

/// Pure navigation lifecycle decisions, kept separate from the ride lifecycle.
/// In particular, `.cancelled` suppresses replayed snapshots for the same route
/// while Dart processes the vehicle's End Directions request; it never implies
/// that the recorded ride has ended.
struct CarPlayNavigationCoordinator {
  enum Phase: Equatable {
    case idle
    case previewing
    case loading(String)
    case navigating(String)
    case paused(String)
    case rerouting(String)
    case arrived(String)
    case cancelled(String?)
  }

  enum Action: Equatable {
    case none
    case start(routeID: String, paused: Bool)
    case update
    case pause
    case resume
    case reroute(from: String, to: String)
    case finish
    case cancel
  }

  private(set) var phase: Phase = .idle

  mutating func beginPreview() {
    guard case .idle = phase else { return }
    phase = .previewing
  }

  mutating func beginLoading(routeID: String) -> Bool {
    switch phase {
    case .loading(let current) where current == routeID:
      return false
    case .navigating(let current) where current == routeID:
      return false
    case .paused(let current) where current == routeID:
      return false
    default:
      phase = .loading(routeID)
      return true
    }
  }

  mutating func apply(_ projection: CarPlayNavigationProjectionV2) -> Action {
    let routeID = projection.trip?.id
    switch projection.navigationPhase {
    case "inactive":
      switch phase {
      case .idle, .cancelled:
        return .none
      case .previewing:
        phase = .idle
        return .none
      default:
        phase = .cancelled(routeID)
        return .cancel
      }
    case "routeReady":
      phase = .previewing
      return .none
    case "ended":
      guard let routeID else { return .none }
      if case .arrived(let current) = phase, current == routeID { return .none }
      phase = .arrived(routeID)
      return .finish
    case "paused":
      guard let routeID else { return .none }
      switch phase {
      case .paused(let current) where current == routeID:
        return .none
      case .loading(let current) where current == routeID:
        return .none
      case .navigating(let current) where current == routeID:
        phase = .paused(routeID)
        return .pause
      case .cancelled(let current) where current == routeID:
        return .none
      default:
        phase = .paused(routeID)
        return .start(routeID: routeID, paused: true)
      }
    case "navigating":
      guard let routeID else { return .none }
      switch phase {
      case .loading(let current) where current == routeID:
        phase = .navigating(routeID)
        return .resume
      case .paused(let current) where current == routeID:
        phase = .navigating(routeID)
        return .resume
      case .navigating(let current) where current == routeID:
        return .update
      case .cancelled(let current) where current == routeID:
        return .none
      case .navigating(let previous), .paused(let previous),
        .loading(let previous), .rerouting(let previous):
        phase = .rerouting(routeID)
        return .reroute(from: previous, to: routeID)
      default:
        phase = .navigating(routeID)
        return .start(routeID: routeID, paused: false)
      }
    default:
      return .none
    }
  }

  mutating func completeReroute(routeID: String) {
    guard case .rerouting(let current) = phase, current == routeID else { return }
    phase = .navigating(routeID)
  }

  mutating func cancel() -> Action {
    switch phase {
    case .cancelled, .idle:
      return .none
    default:
      let routeID: String?
      switch phase {
      case .loading(let id), .navigating(let id), .paused(let id),
        .rerouting(let id), .arrived(let id):
        routeID = id
      default:
        routeID = nil
      }
      phase = .cancelled(routeID)
      return .cancel
    }
  }

  mutating func disconnect() {
    phase = .idle
  }
}

/// The side-effect-free route choices Dart calculated for a CarPlay preview.
///
/// Platform-channel input is deliberately decoded before any CarPlay object is
/// created. This keeps malformed geometry, unbounded labels, and empty route
/// arrays away from APIs that assume a valid trip.
struct CarPlayRoutePreviewPayload: Equatable {
  struct Coordinate: Equatable {
    let latitude: Double
    let longitude: Double

    var clLocationCoordinate: CLLocationCoordinate2D {
      CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
  }

  struct Choice: Equatable {
    let id: String
    let routeID: String
    let summaryVariants: [String]
    let additionalInformationVariants: [String]
    let selectionSummaryVariants: [String]
    let distanceMeters: Double
    let durationSeconds: TimeInterval
    let routePoints: [Coordinate]
  }

  let id: String
  let destinationLabel: String
  let origin: Coordinate
  let destination: Coordinate
  let choices: [Choice]

  init?(response: [String: Any]) {
    guard
      response["error"] == nil || response["error"] is NSNull,
      let raw = response["preview"] as? [String: Any],
      Self.integer(raw["schemaVersion"]) == 1,
      let id = Self.string(raw["id"], maximumLength: 220),
      let destinationLabel = Self.string(
        raw["destinationLabel"],
        maximumLength: 180
      ),
      let rawOrigin = raw["origin"] as? [String: Any],
      let origin = Self.coordinate(rawOrigin),
      let rawDestination = raw["destination"] as? [String: Any],
      let destination = Self.coordinate(rawDestination),
      let rawChoices = raw["choices"] as? [[String: Any]],
      (1 ... 3).contains(rawChoices.count)
    else { return nil }

    var decodedChoices: [Choice] = []
    var choiceIDs = Set<String>()
    for rawChoice in rawChoices {
      guard
        let choice = Self.choice(rawChoice),
        choiceIDs.insert(choice.id).inserted
      else { return nil }
      decodedChoices.append(choice)
    }

    self.id = id
    self.destinationLabel = destinationLabel
    self.origin = origin
    self.destination = destination
    self.choices = decodedChoices
  }

  private static func choice(_ raw: [String: Any]) -> Choice? {
    guard
      let id = string(raw["id"], maximumLength: 220),
      let routeID = string(raw["routeId"], maximumLength: 180),
      let summaryVariants = stringArray(
        raw["summaryVariants"],
        maximumCount: 3,
        maximumLength: 160
      ),
      !summaryVariants.isEmpty,
      let additionalInformationVariants = stringArray(
        raw["additionalInformationVariants"],
        maximumCount: 3,
        maximumLength: 160
      ),
      !additionalInformationVariants.isEmpty,
      let selectionSummaryVariants = stringArray(
        raw["selectionSummaryVariants"],
        maximumCount: 3,
        maximumLength: 160
      ),
      !selectionSummaryVariants.isEmpty,
      let distanceMeters = nonNegativeDouble(raw["distanceMeters"]),
      let durationSeconds = nonNegativeDouble(raw["durationSeconds"]),
      let rawPoints = raw["routePoints"] as? [[String: Any]],
      rawPoints.count >= 2,
      rawPoints.count <= 200_000
    else { return nil }

    let routePoints = rawPoints.compactMap(coordinate)
    guard routePoints.count == rawPoints.count else { return nil }
    return Choice(
      id: id,
      routeID: routeID,
      summaryVariants: summaryVariants,
      additionalInformationVariants: additionalInformationVariants,
      selectionSummaryVariants: selectionSummaryVariants,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      routePoints: routePoints
    )
  }

  private static func coordinate(_ raw: [String: Any]) -> Coordinate? {
    guard
      let latitude = finiteDouble(raw["latitude"]),
      let longitude = finiteDouble(raw["longitude"]),
      (-90 ... 90).contains(latitude),
      (-180 ... 180).contains(longitude)
    else { return nil }
    return Coordinate(latitude: latitude, longitude: longitude)
  }

  private static func stringArray(
    _ raw: Any?,
    maximumCount: Int,
    maximumLength: Int
  ) -> [String]? {
    guard
      let values = raw as? [Any],
      (1 ... maximumCount).contains(values.count)
    else { return nil }
    var result: [String] = []
    for value in values {
      guard let text = string(value, maximumLength: maximumLength) else {
        return nil
      }
      if !result.contains(text) { result.append(text) }
    }
    return result
  }

  private static func string(_ raw: Any?, maximumLength: Int) -> String? {
    guard
      let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.count <= maximumLength
    else { return nil }
    return value
  }

  private static func integer(_ raw: Any?) -> Int? {
    (raw as? NSNumber)?.intValue ?? raw as? Int
  }

  private static func finiteDouble(_ raw: Any?) -> Double? {
    let value = (raw as? NSNumber)?.doubleValue ?? raw as? Double
    return value?.isFinite == true ? value : nil
  }

  private static func nonNegativeDouble(_ raw: Any?) -> Double? {
    guard let value = finiteDouble(raw), value >= 0 else { return nil }
    return value
  }
}

/// Orders asynchronous planning results and consumes the selected choice once.
/// Dart has its own transaction guard at the persistence boundary; keeping the
/// same rule here prevents repeated CarPlay delegate callbacks reaching it.
struct CarPlayRoutePreviewCoordinator {
  enum Phase: Equatable {
    case idle
    case previewing
    case committing
    case committed
  }

  struct Request: Equatable {
    let generation: Int
    let supersededPreviewID: String?
  }

  struct Selection: Equatable {
    let previewID: String
    let choice: CarPlayRoutePreviewPayload.Choice
  }

  private(set) var generation = 0
  private(set) var phase = Phase.idle
  private(set) var preview: CarPlayRoutePreviewPayload?
  private(set) var selectedChoiceID: String?

  var selectedChoice: CarPlayRoutePreviewPayload.Choice? {
    guard let preview, let selectedChoiceID else { return nil }
    return preview.choices.first { $0.id == selectedChoiceID }
  }

  mutating func beginRequest() -> Request {
    generation &+= 1
    let supersededPreviewID = phase == .previewing ? preview?.id : nil
    phase = .idle
    preview = nil
    selectedChoiceID = nil
    return Request(
      generation: generation,
      supersededPreviewID: supersededPreviewID
    )
  }

  mutating func accept(
    _ candidate: CarPlayRoutePreviewPayload,
    generation candidateGeneration: Int
  ) -> Bool {
    guard candidateGeneration == generation, phase == .idle else {
      return false
    }
    preview = candidate
    selectedChoiceID = candidate.choices.first?.id
    phase = .previewing
    return true
  }

  mutating func fail(generation failedGeneration: Int) -> Bool {
    guard failedGeneration == generation, phase == .idle else { return false }
    preview = nil
    selectedChoiceID = nil
    return true
  }

  mutating func select(choiceID: String) -> CarPlayRoutePreviewPayload.Choice? {
    guard
      phase == .previewing,
      let choice = preview?.choices.first(where: { $0.id == choiceID })
    else { return nil }
    selectedChoiceID = choice.id
    return choice
  }

  mutating func beginCommit(
    previewID: String,
    choiceID: String
  ) -> Selection? {
    guard
      phase == .previewing,
      let preview,
      preview.id == previewID,
      let choice = preview.choices.first(where: { $0.id == choiceID })
    else { return nil }
    selectedChoiceID = choice.id
    phase = .committing
    return Selection(previewID: preview.id, choice: choice)
  }

  mutating func completeCommit(succeeded: Bool) {
    guard phase == .committing else { return }
    phase = succeeded ? .committed : .idle
    preview = nil
    selectedChoiceID = nil
  }

  mutating func cancel() -> String? {
    generation &+= 1
    let cancelledPreviewID = phase == .previewing ? preview?.id : nil
    phase = .idle
    preview = nil
    selectedChoiceID = nil
    return cancelledPreviewID
  }
}

/// Owns the navigation-app CarPlay scene. Navigation apps must use the
/// window-bearing delegate callback and place a `CPMapTemplate` at the root.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  CPMapTemplateDelegate, CPSearchTemplateDelegate, CPSessionConfigurationDelegate
{
  private var mapTemplate: CPMapTemplate?
  private var mapViewController: CarPlayNavigationViewController?
  private var statusTemplate: CPListTemplate?
  private var navigationSession: CPNavigationSession?
  private var activeNavigationTrip: CPTrip?
  private var navigationCoordinator = CarPlayNavigationCoordinator()
  private var activeManeuvers: [String: CPManeuver] = [:]
  private var lastManeuverEstimate: (distance: Double, seconds: Double)?
  private var lastTripEstimate: (distance: Double, seconds: Double)?
  private var presentedNavigationAlertKey: String?
  private var rideStartPrompt: [String: Any]?
  private var isShowingPanningInterface = false
  private var rideMenuButton: CPBarButton?
  private var surfaceMode = "unavailable"
  private var canPlanRoute = false
  private var canFreeRoam = false
  private var submittedSearchText = ""
  private var interfaceController: CPInterfaceController?
  private var carWindow: CPWindow?
  private var sessionConfiguration: CPSessionConfiguration?
  private var limitedUserInterfaces: CPLimitableUserInterface = []
  private var latestSnapshot: [String: Any]?
  private var sceneLifecycle = CarPlaySceneLifecycle()
  private var navigationProjectionV2Store = CarPlayNavigationProjectionStore()
  private var routePreviewCoordinator = CarPlayRoutePreviewCoordinator()
  private var routePreviewTrip: CPTrip?

  /// The request the presented alert is asking about, so the same question is
  /// not raised twice and a question that has gone away takes its alert with
  /// it.
  private var presentedTecRequestID: String?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController,
    to window: CPWindow
  ) {
    let connectionGeneration = sceneLifecycle.beginConnection()
    let mapViewController = CarPlayNavigationViewController()
    let mapTemplate = CPMapTemplate()
    let statusTemplate = CarPlayStatusTemplate.makeTemplate(
      onEmergency: { [weak self] in self?.presentEmergencyConfirmation() }
    )
    let sessionConfiguration = CPSessionConfiguration(delegate: self)

    self.mapTemplate = mapTemplate
    self.mapViewController = mapViewController
    self.statusTemplate = statusTemplate
    self.interfaceController = interfaceController
    carWindow = window
    self.sessionConfiguration = sessionConfiguration
    limitedUserInterfaces = sessionConfiguration.limitedUserInterfaces
    let rideMenuButton = statusButton(
      interfaceController: interfaceController,
      template: statusTemplate
    )
    self.rideMenuButton = rideMenuButton

    window.rootViewController = mapViewController
    mapTemplate.mapDelegate = self
    mapTemplate.automaticallyHidesNavigationBar = true
    mapTemplate.hidesButtonsWithNavigationBar = false
    mapTemplate.guidanceBackgroundColor = CarPlayPalette.primaryPanelFill
    mapTemplate.mapButtons = []
    applyHostContentStyle(sessionConfiguration.contentStyle)
    // Phone landscape puts its compact ride menu at the leading edge. Keep the
    // same learned location in the car; CarPlay still owns the navigation bar
    // and lays its manoeuvre card below it.
    mapTemplate.leadingNavigationBarButtons = [rideMenuButton]
    // Apple's header explicitly says a failed presentation throws when no
    // completion is supplied. More importantly, a navigation session must not
    // start until this root has actually been accepted by the head unit. The
    // phone can publish Start ride while this asynchronous operation is in
    // flight, which is the field crash reported in #441.
    interfaceController.setRootTemplate(mapTemplate, animated: false) {
      [weak self, weak interfaceController] success, error in
      guard
        let self,
        let interfaceController,
        self.interfaceController === interfaceController
      else { return }
      let becameReady = self.sceneLifecycle.completeRootPresentation(
        generation: connectionGeneration,
        succeeded: success
      )
      guard becameReady else {
        if let error {
          NSLog("CarPlay root template was not presented: %@", error.localizedDescription)
        }
        return
      }
      (UIApplication.shared.delegate as? AppDelegate)?.carPlayDidConnect(self)
    }
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController,
    from window: CPWindow
  ) {
    // A delayed disconnect from an earlier scene must not cancel the current
    // navigation session or clear its view hierarchy.
    guard
      self.interfaceController === interfaceController,
      carWindow === window
    else { return }
    sceneLifecycle.disconnect()
    cancelRoutePreview(notifyDart: true)
    cancelActiveNavigationSession()
    navigationCoordinator.disconnect()
    window.rootViewController = nil
    self.interfaceController = nil
    carWindow = nil
    sessionConfiguration = nil
    limitedUserInterfaces = []
    latestSnapshot = nil
    mapTemplate = nil
    mapViewController = nil
    statusTemplate = nil
    rideMenuButton = nil
    rideStartPrompt = nil
    surfaceMode = "unavailable"
    canPlanRoute = false
    canFreeRoam = false
    submittedSearchText = ""
    presentedTecRequestID = nil
    (UIApplication.shared.delegate as? AppDelegate)?.carPlayDidDisconnect(self)
  }

  func apply(snapshot: [String: Any]) {
    latestSnapshot = snapshot
    // Decode and order the typed contract now, while the legacy renderer stays
    // active. The navigation coordinator can then migrate without changing the
    // wire format or risking Android Auto's shared V1 decoder (#690).
    let candidateNavigationProjection = CarPlayNavigationProjectionV2(
      snapshot: snapshot
    )
    let acceptedNavigationProjection = navigationProjectionV2Store.accept(
      snapshot: snapshot
    )
    mapViewController?.apply(snapshot: snapshot)
    if let statusTemplate {
      CarPlayStatusTemplate.apply(
        snapshot: snapshot,
        to: statusTemplate,
        listsLimited: !interactionPolicy.allowsRiderRows,
        onLeave: { [weak self] in self?.presentLeaveConfirmation() }
      )
    }
    // App-owned map/status views can accept data while the root is installing,
    // but CarPlay template and navigation APIs cannot. AppDelegate retains the
    // same snapshot and replays it after the root completion above.
    guard sceneLifecycle.rootReady else { return }
    updateSurfaceActions(snapshot)
    if let projection = navigationProjectionV2Store.latest,
      acceptedNavigationProjection || candidateNavigationProjection == projection
    {
      updateNavigationSession(projection: projection, snapshot: snapshot)
    }
    updateNavigationAlert(snapshot["alert"] as? [String: Any])
    updateTecRoleRequest(snapshot["tecRequest"] as? [String: Any])
    updateRideStart(snapshot["rideStart"] as? [String: Any])
  }

  func apply(viewport: [String: Any]) {
    mapViewController?.apply(viewport: viewport)
  }

  func apply(mapStyle: [String: Any]) {
    mapViewController?.apply(mapStyle: mapStyle)
  }

  func sessionConfiguration(
    _ sessionConfiguration: CPSessionConfiguration,
    limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
  ) {
    guard self.sessionConfiguration === sessionConfiguration else { return }
    self.limitedUserInterfaces = limitedUserInterfaces
    if let snapshot = latestSnapshot {
      updateSurfaceActions(snapshot)
      if let statusTemplate {
        CarPlayStatusTemplate.apply(
          snapshot: snapshot,
          to: statusTemplate,
          listsLimited: !interactionPolicy.allowsRiderRows,
          onLeave: { [weak self] in self?.presentLeaveConfirmation() }
        )
      }
    }
  }

  func sessionConfiguration(
    _ sessionConfiguration: CPSessionConfiguration,
    contentStyleChanged contentStyle: CPContentStyle
  ) {
    guard self.sessionConfiguration === sessionConfiguration else { return }
    applyHostContentStyle(contentStyle)
  }

  func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
    applyHostContentStyle(contentStyle == .dark ? [.dark] : [.light])
  }

  private func applyHostContentStyle(_ contentStyle: CPContentStyle) {
    let dark = contentStyle.contains(.dark)
    mapTemplate?.guidanceBackgroundColor = dark
      ? CarPlayPalette.primaryPanelFill
      : UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
    mapViewController?.apply(contentStyle: contentStyle)
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
        interfaceController?.dismissTemplate(animated: true) { _, error in
          if let error {
            NSLog("CarPlay role request could not be dismissed: %@", error.localizedDescription)
          }
        }
      }
      return
    }
    guard requestID != presentedTecRequestID else { return }
    guard let interfaceController else { return }

    let answer: (Bool) -> Void = { [weak self] accepted in
      self?.presentedTecRequestID = nil
      self?.performConfirmedAction(
        dismissing: interfaceController,
        failureMessage: "That request could not be answered. Try again."
      ) { completion in
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
          completion(false, nil)
          return
        }
        appDelegate.answerCarPlayTecRoleRequest(
          requestID: requestID,
          accepted: accepted,
          completion: completion
        )
      }
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
    interfaceController.presentTemplate(alert, animated: true) {
      [weak self, weak interfaceController] success, error in
      guard
        let self,
        let interfaceController,
        self.interfaceController === interfaceController
      else { return }
      if !success, self.presentedTecRequestID == requestID {
        self.presentedTecRequestID = nil
      }
      if let error {
        NSLog("CarPlay role request was not presented: %@", error.localizedDescription)
      }
    }
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

  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    panBeganWith direction: CPMapTemplate.PanDirection
  ) {
    mapViewController?.beginDirectionalPan(direction: direction)
  }

  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    panEndedWith direction: CPMapTemplate.PanDirection
  ) {
    mapViewController?.endDirectionalPan()
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

  @available(iOS 26.0, *)
  func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
    mapViewController?.beginZoomGesture()
  }

  @available(iOS 26.0, *)
  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didUpdateZoomGestureWithCenter center: CGPoint,
    scale: CGFloat,
    velocity: CGFloat
  ) {
    mapViewController?.updateZoomGesture(scale: scale)
  }

  @available(iOS 26.0, *)
  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didEndZoomGestureWithVelocity velocity: CGFloat
  ) {
    mapViewController?.endZoomGesture()
  }

  @available(iOS 26.0, *)
  func mapTemplateDidBeginRotationGesture(_ mapTemplate: CPMapTemplate) {
    mapViewController?.beginRotationGesture()
  }

  @available(iOS 26.0, *)
  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    didRotateWithCenter center: CGPoint,
    rotation: CGFloat,
    velocity: CGFloat
  ) {
    mapViewController?.updateRotationGesture(rotation: rotation)
  }

  @available(iOS 26.0, *)
  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    rotationDidEndWithVelocity velocity: CGFloat
  ) {
    mapViewController?.endRotationGesture()
  }

  @available(iOS 26.0, *)
  func mapTemplateDidBeginPitchGesture(_ mapTemplate: CPMapTemplate) {
    mapViewController?.beginPitchGesture()
  }

  @available(iOS 26.0, *)
  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    pitchWithCenter center: CGPoint
  ) {
    mapViewController?.updatePitchGesture(center: center)
  }

  @available(iOS 26.0, *)
  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    pitchEndedWithCenter center: CGPoint
  ) {
    mapViewController?.endPitchGesture()
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

  private func updateNavigationSession(
    projection: CarPlayNavigationProjectionV2,
    snapshot: [String: Any]
  ) {
    guard sceneLifecycle.rootReady, let mapTemplate else { return }
    let unitPolicy = CarPlayUnitPolicy(
      distanceUnit: projection.units.distance,
      localeIdentifier: projection.localeIdentifier
    )
    let action = navigationCoordinator.apply(projection)
    var shouldResume = false
    switch action {
    case .none:
      return
    case .cancel:
      cancelActiveNavigationSession()
      return
    case .finish:
      navigationSession?.finishTrip()
      navigationSession = nil
      activeNavigationTrip = nil
      activeManeuvers.removeAll()
      return
    case .start(_, let paused):
      guard let trip = navigationTrip(projection: projection, snapshot: snapshot) else {
        // A projection can arrive before its route geometry during app/scene
        // restoration. Leave the coordinator retryable so the next complete
        // snapshot can start the session.
        navigationCoordinator.disconnect()
        return
      }
      cancelActiveNavigationSession()
      activeNavigationTrip = trip
      navigationSession = mapTemplate.startNavigationSession(for: trip)
      if paused {
        navigationSession?.pauseTrip(
          for: .loading,
          description: "Ride paused",
          turnCardColor: CarPlayPalette.primaryPanelFill
        )
      }
    case .pause:
      navigationSession?.pauseTrip(
        for: .proceedToRoute,
        description: "Ride paused",
        turnCardColor: CarPlayPalette.primaryPanelFill
      )
      return
    case .resume:
      shouldResume = true
    case .reroute(_, let routeID):
      navigationSession?.pauseTrip(
        for: .rerouting,
        description: "Updating route",
        turnCardColor: CarPlayPalette.primaryPanelFill
      )
      activeManeuvers.removeAll()
      lastManeuverEstimate = nil
      lastTripEstimate = nil
      navigationCoordinator.completeReroute(routeID: routeID)
      shouldResume = true
    case .update:
      break
    }

    guard let navigationSession else { return }
    let projectedManeuvers = [
      projection.currentManeuver,
      projection.followingManeuver,
    ].compactMap { $0 }
    let maneuvers = projectedManeuvers.map { payload -> CPManeuver in
      if let existing = activeManeuvers[payload.id] { return existing }
      let created = carPlayManeuver(payload)
      activeManeuvers[payload.id] = created
      return created
    }
    guard let currentPayload = projection.currentManeuver,
      let currentManeuver = maneuvers.first
    else {
      navigationSession.upcomingManeuvers = []
      return
    }
    if #available(iOS 17.4, *) {
      navigationSession.add(maneuvers)
      navigationSession.currentRoadNameVariants = currentPayload.roadNameVariants
      navigationSession.maneuverState = maneuverState(
        distanceMeters: currentPayload.distanceMeters
      )
      updateLaneGuidance(currentPayload, session: navigationSession)
    }
    navigationSession.upcomingManeuvers = maneuvers
    updateManeuverEstimate(
      currentPayload,
      maneuver: currentManeuver,
      session: navigationSession,
      usesMiles: unitPolicy.usesMiles
    )
    updateTripEstimate(
      snapshot: snapshot,
      trip: activeNavigationTrip,
      mapTemplate: mapTemplate,
      usesMiles: unitPolicy.usesMiles
    )
    if shouldResume {
      resumeNavigationSession(
        session: navigationSession,
        maneuvers: maneuvers,
        currentPayload: currentPayload,
        snapshot: snapshot,
        usesMiles: unitPolicy.usesMiles
      )
    }
  }

  private func resumeNavigationSession(
    session: CPNavigationSession,
    maneuvers: [CPManeuver],
    currentPayload: CarPlayNavigationProjectionV2.Maneuver,
    snapshot: [String: Any],
    usesMiles: Bool
  ) {
    guard #available(iOS 17.4, *), let currentManeuver = maneuvers.first else {
      // Before iOS 17.4 CarPlay resumes a paused card when the replacement
      // upcoming manoeuvres arrive; there is no public resume selector.
      session.upcomingManeuvers = maneuvers
      return
    }
    let maneuverEstimate = CPTravelEstimates(
      distanceRemaining: distanceMeasurement(
        currentPayload.distanceMeters ?? -1,
        usesMiles: usesMiles
      ),
      timeRemaining: currentPayload.secondsRemaining ?? -1
    )
    let journey = snapshot["journeyProgress"] as? [String: Any]
    let tripEstimate = CPTravelEstimates(
      distanceRemaining: distanceMeasurement(
        (journey?["remainingDistanceMeters"] as? NSNumber)?.doubleValue ?? -1,
        usesMiles: usesMiles
      ),
      timeRemaining:
        (journey?["remainingSeconds"] as? NSNumber)?.doubleValue ?? -1
    )
    let laneGuidance = session.currentLaneGuidance ?? CPLaneGuidance()
    if laneGuidance.instructionVariants.isEmpty {
      laneGuidance.instructionVariants = orderedVariants(
        currentPayload.instructionVariants
      )
      laneGuidance.lanes = []
    }
    let information = CPRouteInformation(
      maneuvers: maneuvers,
      laneGuidances: session.currentLaneGuidance.map { [$0] } ?? [],
      currentManeuvers: [currentManeuver],
      currentLaneGuidance: laneGuidance,
      trip: tripEstimate,
      maneuverTravelEstimates: maneuverEstimate
    )
    session.resumeTrip(updatedRouteInformation: information)
  }

  private func navigationTrip(
    projection: CarPlayNavigationProjectionV2,
    snapshot: [String: Any]
  ) -> CPTrip? {
    guard
      let payload = projection.trip,
      let routePoints = snapshot["routePoints"] as? [[String: Any]],
      routePoints.count >= 2,
      let first = coordinate(from: routePoints.first),
      let last = coordinate(from: routePoints.last)
    else { return nil }
    let origin = MKMapItem(placemark: MKPlacemark(coordinate: first))
    origin.name = "Ride start"
    let destination = MKMapItem(placemark: MKPlacemark(coordinate: last))
    destination.name = payload.name
    let choice = CPRouteChoice(
      summaryVariants: [payload.name],
      additionalInformationVariants: ["Motorcycle route"],
      selectionSummaryVariants: [payload.name]
    )
    choice.userInfo = ["routeChoiceId": payload.routeChoiceID]
    let trip = CPTrip(origin: origin, destination: destination, routeChoices: [choice])
    trip.userInfo = ["routeId": payload.id]
    if #available(iOS 17.4, *) {
      trip.destinationNameVariants = orderedVariants([payload.name, "Destination"])
    }
    return trip
  }

  private func carPlayManeuver(
    _ payload: CarPlayNavigationProjectionV2.Maneuver
  ) -> CPManeuver {
    let maneuver = CPManeuver()
    maneuver.instructionVariants = orderedVariants(payload.instructionVariants)
    maneuver.dashboardInstructionVariants = orderedVariants(
      payload.instructionVariants
    )
    maneuver.notificationInstructionVariants = orderedVariants(
      payload.instructionVariants
    )
    let symbolName = maneuverSymbolName(payload)
    if let imageSet = navigationImageSet(named: symbolName) {
      maneuver.symbolSet = imageSet
      maneuver.symbolImage = adaptiveNavigationImage(named: symbolName)
      maneuver.dashboardSymbolImage = adaptiveNavigationImage(named: symbolName)
      maneuver.notificationSymbolImage = adaptiveNavigationImage(named: symbolName)
    }
    maneuver.cardBackgroundColor = CarPlayPalette.primaryPanelFill
    if #available(iOS 17.4, *) {
      maneuver.maneuverType = maneuverType(payload)
      maneuver.roadFollowingManeuverVariants = orderedVariants(
        payload.roadNameVariants
      )
      maneuver.trafficSide = payload.trafficSide == "left" ? .left : .right
    }
    return maneuver
  }

  private func orderedVariants(_ values: [String]) -> [String] {
    Array(Set(values)).sorted {
      if $0.count == $1.count { return $0 < $1 }
      return $0.count > $1.count
    }
  }

  private func navigationImageSet(named name: String) -> CPImageSet? {
    guard
      let base = UIImage(
        systemName: name,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
      )
    else { return nil }
    return CPImageSet(
      lightContentImage: base.withTintColor(.black, renderingMode: .alwaysOriginal),
      darkContentImage: base.withTintColor(.white, renderingMode: .alwaysOriginal)
    )
  }

  private func adaptiveNavigationImage(named name: String) -> UIImage? {
    guard
      let base = UIImage(
        systemName: name,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
      )
    else { return nil }
    return base.withTintColor(.label, renderingMode: .alwaysOriginal)
  }

  private func maneuverSymbolName(
    _ payload: CarPlayNavigationProjectionV2.Maneuver
  ) -> String {
    switch (payload.kind, payload.direction) {
    case ("arrive", _): return "flag.checkered"
    case ("roundabout", _): return "arrow.clockwise.circle"
    case (_, "sharpLeft"), (_, "left"): return "arrow.turn.up.left"
    case (_, "slightLeft"): return "arrow.up.left"
    case (_, "sharpRight"), (_, "right"): return "arrow.turn.up.right"
    case (_, "slightRight"): return "arrow.up.right"
    case (_, "uTurn"): return "arrow.uturn.up"
    default: return "arrow.up"
    }
  }

  @available(iOS 17.4, *)
  private func maneuverType(
    _ payload: CarPlayNavigationProjectionV2.Maneuver
  ) -> CPManeuverType {
    if payload.kind == "arrive" { return .arriveAtDestination }
    if payload.kind == "roundabout" { return .enterRoundabout }
    if payload.kind == "offRamp" {
      return payload.direction == "left" ? .highwayOffRampLeft : .highwayOffRampRight
    }
    if payload.kind == "onRamp" { return .onRamp }
    return switch payload.direction {
    case "sharpLeft": .sharpLeftTurn
    case "left": .leftTurn
    case "slightLeft": .slightLeftTurn
    case "slightRight": .slightRightTurn
    case "right": .rightTurn
    case "sharpRight": .sharpRightTurn
    case "uTurn": .uTurn
    default: .straightAhead
    }
  }

  @available(iOS 17.4, *)
  private func maneuverState(distanceMeters: Double?) -> CPManeuverState {
    guard let distanceMeters else { return .continue }
    if distanceMeters <= 35 { return .execute }
    if distanceMeters <= 180 { return .prepare }
    if distanceMeters <= 800 { return .initial }
    return .continue
  }

  @available(iOS 17.4, *)
  private func updateLaneGuidance(
    _ payload: CarPlayNavigationProjectionV2.Maneuver,
    session: CPNavigationSession
  ) {
    guard !payload.lanes.isEmpty else {
      session.currentLaneGuidance = nil
      return
    }
    let guidance = CPLaneGuidance()
    guidance.instructionVariants = orderedVariants(payload.instructionVariants)
    guidance.lanes = payload.lanes.map { payload in
      let lane = CPLane()
      lane.status = payload.isValid ? .good : .notGood
      let angles = payload.indications.map { indication in
        Measurement(value: laneAngle(indication), unit: UnitAngle.degrees)
      }
      lane.primaryAngle = angles.first ?? Measurement(value: 0, unit: .degrees)
      lane.secondaryAngles = Array(angles.dropFirst())
      return lane
    }
    session.add([guidance])
    session.currentLaneGuidance = guidance
  }

  private func laneAngle(_ indication: String) -> Double {
    switch indication.lowercased().replacingOccurrences(of: "_", with: " ") {
    case "sharp left": return -120
    case "left": return -90
    case "slight left": return -40
    case "slight right": return 40
    case "right": return 90
    case "sharp right": return 120
    case "uturn", "u-turn": return 180
    default: return 0
    }
  }

  private func updateManeuverEstimate(
    _ payload: CarPlayNavigationProjectionV2.Maneuver,
    maneuver: CPManeuver,
    session: CPNavigationSession,
    usesMiles: Bool
  ) {
    guard let distance = payload.distanceMeters else { return }
    let seconds = payload.secondsRemaining ?? -1
    guard estimateChanged(lastManeuverEstimate, distance: distance, seconds: seconds)
    else { return }
    lastManeuverEstimate = (distance, seconds)
    session.updateEstimates(
      CPTravelEstimates(
        distanceRemaining: distanceMeasurement(distance, usesMiles: usesMiles),
        timeRemaining: seconds
      ),
      for: maneuver
    )
  }

  private func updateTripEstimate(
    snapshot: [String: Any],
    trip: CPTrip?,
    mapTemplate: CPMapTemplate,
    usesMiles: Bool
  ) {
    guard
      let trip,
      let journey = snapshot["journeyProgress"] as? [String: Any],
      let distance = (journey["remainingDistanceMeters"] as? NSNumber)?.doubleValue
    else { return }
    let seconds = (journey["remainingSeconds"] as? NSNumber)?.doubleValue ?? -1
    guard estimateChanged(lastTripEstimate, distance: distance, seconds: seconds)
    else { return }
    lastTripEstimate = (distance, seconds)
    mapTemplate.updateEstimates(
      CPTravelEstimates(
        distanceRemaining: distanceMeasurement(distance, usesMiles: usesMiles),
        timeRemaining: seconds
      ),
      for: trip
    )
  }

  private func estimateChanged(
    _ previous: (distance: Double, seconds: Double)?,
    distance: Double,
    seconds: Double
  ) -> Bool {
    guard let previous else { return true }
    return abs(previous.distance - distance) >= 5 || abs(previous.seconds - seconds) >= 2
  }

  private func distanceMeasurement(_ meters: Double, usesMiles: Bool) -> Measurement<UnitLength> {
    usesMiles
      ? Measurement(value: meters / 1_609.344, unit: .miles)
      : Measurement(value: meters, unit: .meters)
  }

  private func cancelActiveNavigationSession() {
    navigationSession?.cancelTrip()
    if presentedNavigationAlertKey != nil {
      mapTemplate?.dismissNavigationAlert(animated: true) { _ in }
    }
    presentedNavigationAlertKey = nil
    navigationSession = nil
    activeNavigationTrip = nil
    activeManeuvers.removeAll()
    lastManeuverEstimate = nil
    lastTripEstimate = nil
  }

  private func updateNavigationAlert(_ rawAlert: [String: Any]?) {
    guard let mapTemplate else { return }
    guard
      navigationSession != nil,
      let message = nonEmptyString(rawAlert?["message"])
    else {
      if presentedNavigationAlertKey != nil {
        mapTemplate.dismissNavigationAlert(animated: true) { _ in }
      }
      presentedNavigationAlertKey = nil
      return
    }
    let severity = nonEmptyString(rawAlert?["severity"]) ?? "alert"
    let key = "\(severity)|\(message)"
    guard key != presentedNavigationAlertKey else { return }
    let present = { [weak self, weak mapTemplate] in
      guard let self, let mapTemplate else { return }
      let action = CPAlertAction(title: "OK", style: .default) { _ in }
      let alert = CPNavigationAlert(
        titleVariants: self.orderedVariants([message, "Road alert"]),
        subtitleVariants: [severity.capitalized],
        image: self.adaptiveNavigationImage(named: "exclamationmark.triangle.fill"),
        primaryAction: action,
        secondaryAction: nil,
        duration: 8
      )
      self.presentedNavigationAlertKey = key
      mapTemplate.present(navigationAlert: alert, animated: true)
    }
    if mapTemplate.currentNavigationAlert != nil {
      mapTemplate.dismissNavigationAlert(animated: true) { _ in present() }
    } else {
      present()
    }
  }

  private func recenterButton() -> CPMapButton {
    let button = CPMapButton { [weak self] _ in
      self?.mapViewController?.recenter()
    }
    button.image = mapButtonImage(
      // The phone's landscape control uses an outlined navigation arrow.
      named: "location.north",
      color: CarPlayPalette.actionInk,
      accessibilityLabel: "Follow my location"
    )
    return button
  }

  private func updateSurfaceActions(_ snapshot: [String: Any]) {
    surfaceMode = nonEmptyString(snapshot["surfaceMode"]) ?? "unavailable"
    canPlanRoute = (snapshot["canPlanRoute"] as? NSNumber)?.boolValue ?? false
    canFreeRoam = (snapshot["canFreeRoam"] as? NSNumber)?.boolValue ?? false
    guard let mapTemplate else { return }

    mapTemplate.mapButtons = [
      panButton(mapTemplate: mapTemplate),
      recenterButton(),
      zoomButton(delta: 1),
      zoomButton(delta: -1),
    ]
    if surfaceMode == "activeRide" {
      mapTemplate.trailingNavigationBarButtons = [
        reportBarButton(),
        emergencyBarButton(),
      ]
    } else {
      var buttons: [CPBarButton] = []
      if canPlanRoute, interactionPolicy.allowsDestinationSearch {
        buttons.append(planRouteBarButton())
      }
      if canFreeRoam { buttons.append(freeRoamBarButton()) }
      mapTemplate.trailingNavigationBarButtons = buttons
    }
  }

  private func planRouteBarButton() -> CPBarButton {
    let image = mapButtonImage(
      named: "magnifyingglass",
      color: CarPlayPalette.actionInk,
      accessibilityLabel: "Plan a destination"
    ) ?? UIImage()
    return CPBarButton(image: image) { [weak self] _ in
      self?.presentDestinationSearch()
    }
  }

  private func freeRoamBarButton() -> CPBarButton {
    let image = mapButtonImage(
      named: "road.lanes",
      color: CarPlayPalette.routeAhead,
      accessibilityLabel: "Start free roam"
    ) ?? UIImage()
    return CPBarButton(image: image) { [weak self] _ in
      self?.presentFreeRoamConfirmation()
    }
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

  private func reportBarButton() -> CPBarButton {
    let image = mapButtonImage(
      named: "bell.badge.fill",
      color: CarPlayPalette.reportAccent,
      accessibilityLabel: "Report alert"
    ) ?? UIImage()
    return CPBarButton(image: image) { [weak self] _ in
      self?.presentReportActions()
    }
  }

  private func emergencyBarButton() -> CPBarButton {
    let image = mapButtonImage(
      named: "sos",
      color: CarPlayPalette.emergencyFill,
      accessibilityLabel: "SOS"
    ) ?? UIImage()
    return CPBarButton(image: image) { [weak self] _ in
      self?.presentEmergencyConfirmation()
    }
  }

  private func zoomButton(delta: Double) -> CPMapButton {
    let button = CPMapButton { [weak self] _ in
      self?.mapViewController?.zoom(by: delta)
    }
    button.image = mapButtonImage(
      named: delta > 0 ? "plus.magnifyingglass" : "minus.magnifyingglass",
      color: CarPlayPalette.actionInk,
      accessibilityLabel: delta > 0 ? "Zoom in" : "Zoom out"
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

  private func presentDestinationSearch() {
    guard
      sceneLifecycle.rootReady,
      canPlanRoute,
      interactionPolicy.allowsDestinationSearch,
      let interfaceController
    else { return }
    submittedSearchText = ""
    let search = CPSearchTemplate()
    search.delegate = self
    interfaceController.pushTemplate(search, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay destination search was not presented: %@", error.localizedDescription)
      }
    }
  }

  private var interactionPolicy: CarPlayInteractionPolicy {
    CarPlayInteractionPolicy(limitedUserInterfaces: limitedUserInterfaces)
  }

  func searchTemplate(
    _ searchTemplate: CPSearchTemplate,
    updatedSearchText searchText: String,
    completionHandler: @escaping ([CPListItem]) -> Void
  ) {
    // The phone's public Nominatim integration explicitly forbids
    // autocomplete. Keep the typed value locally and perform one request only
    // when Search is submitted.
    submittedSearchText = searchText
    completionHandler([])
  }

  func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
    let query = submittedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      presentCarPlayError("Enter a destination.")
      return
    }
    (UIApplication.shared.delegate as? AppDelegate)?
      .searchCarPlayDestinations(query: query) { [weak self, weak searchTemplate] response in
        DispatchQueue.main.async {
          guard let self, let searchTemplate else { return }
          self.presentDestinationResults(response, from: searchTemplate)
        }
      }
  }

  func searchTemplate(
    _ searchTemplate: CPSearchTemplate,
    selectedResult item: CPListItem,
    completionHandler: @escaping () -> Void
  ) {
    completionHandler()
    guard let destination = item.userInfo as? [String: Any] else { return }
    requestDestinationPreview(destination)
  }

  private func presentDestinationResults(
    _ response: [String: Any],
    from searchTemplate: CPSearchTemplate
  ) {
    guard
      sceneLifecycle.rootReady,
      let interfaceController,
      interfaceController.topTemplate === searchTemplate
    else { return }
    if let error = nonEmptyString(response["error"]) {
      presentCarPlayError(error)
      return
    }
    let destinations = response["results"] as? [[String: Any]] ?? []
    guard !destinations.isEmpty else {
      presentCarPlayError("No destinations matched that search.")
      return
    }
    let items = destinations.prefix(5).compactMap { destination -> CPListItem? in
      guard let label = nonEmptyString(destination["label"]) else { return nil }
      let title = label.split(separator: ",", maxSplits: 1)
        .first.map(String.init) ?? label
      let item = CPListItem(text: title, detailText: label)
      item.userInfo = destination
      item.handler = { [weak self] _, completion in
        completion()
        self?.requestDestinationPreview(destination)
      }
      return item
    }
    let results = CPListTemplate(
      title: "Choose destination",
      sections: [CPListSection(items: items)]
    )
    interfaceController.pushTemplate(results, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay destination results were not presented: %@", error.localizedDescription)
      }
    }
  }

  private func requestDestinationPreview(_ destination: [String: Any]) {
    guard
      let interfaceController,
      let label = nonEmptyString(destination["label"]),
      let latitude = (destination["latitude"] as? NSNumber)?.doubleValue,
      let longitude = (destination["longitude"] as? NSNumber)?.doubleValue,
      latitude.isFinite,
      longitude.isFinite,
      (-90 ... 90).contains(latitude),
      (-180 ... 180).contains(longitude)
    else { return }

    let request = routePreviewCoordinator.beginRequest()
    if let supersededPreviewID = request.supersededPreviewID {
      (UIApplication.shared.delegate as? AppDelegate)?
        .cancelCarPlayDestinationPreview(previewID: supersededPreviewID)
    }
    routePreviewTrip = nil
    mapTemplate?.hideTripPreviews()
    mapViewController?.clearPreviewRoute()

    interfaceController.popToRootTemplate(animated: true) {
      [weak self, weak interfaceController] success, error in
      guard
        let self,
        let interfaceController,
        self.interfaceController === interfaceController,
        self.sceneLifecycle.rootReady,
        success
      else {
        if let error {
          NSLog("CarPlay could not return to the map for route preview: %@", error.localizedDescription)
        }
        return
      }
      (UIApplication.shared.delegate as? AppDelegate)?
        .previewCarPlayDestination(
          label: label,
          latitude: latitude,
          longitude: longitude
        ) { [weak self, weak interfaceController] response in
          DispatchQueue.main.async {
            guard
              let self,
              let interfaceController,
              self.interfaceController === interfaceController,
              self.sceneLifecycle.rootReady
            else { return }
            if let error = self.nonEmptyString(response["error"]) {
              guard self.routePreviewCoordinator.fail(
                generation: request.generation
              ) else { return }
              self.presentCarPlayError(error)
              return
            }
            guard
              let preview = CarPlayRoutePreviewPayload(response: response),
              self.routePreviewCoordinator.accept(
                preview,
                generation: request.generation
              )
            else {
              // A valid result for an older request is expected during rapid
              // reselection. Only an invalid result for the current request is
              // actionable; stale results remain invisible.
              if self.routePreviewCoordinator.fail(
                generation: request.generation
              ) {
                self.presentCarPlayError("No usable route was returned.")
              }
              return
            }
            self.presentRoutePreview(preview)
          }
        }
      }
  }

  private func presentRoutePreview(_ preview: CarPlayRoutePreviewPayload) {
    guard let mapTemplate else { return }
    navigationCoordinator.beginPreview()
    let origin = MKMapItem(
      placemark: MKPlacemark(coordinate: preview.origin.clLocationCoordinate)
    )
    origin.name = "Current location"
    let destination = MKMapItem(
      placemark: MKPlacemark(coordinate: preview.destination.clLocationCoordinate)
    )
    destination.name = preview.destinationLabel
    let routeChoices = preview.choices.map { choice in
      let routeChoice = CPRouteChoice(
        summaryVariants: choice.summaryVariants,
        additionalInformationVariants: choice.additionalInformationVariants,
        selectionSummaryVariants: choice.selectionSummaryVariants
      )
      routeChoice.userInfo = [
        "previewId": preview.id,
        "routeChoiceId": choice.id,
      ]
      return routeChoice
    }
    let trip = CPTrip(
      origin: origin,
      destination: destination,
      routeChoices: routeChoices
    )
    trip.userInfo = ["previewId": preview.id]
    routePreviewTrip = trip
    mapTemplate.showTripPreviews(
      [trip],
      selectedTrip: trip,
      textConfiguration: CPTripPreviewTextConfiguration(
        startButtonTitle: "Go",
        additionalRoutesButtonTitle: "Routes",
        overviewButtonTitle: "Overview"
      )
    )
    if let firstChoice = preview.choices.first {
      showRoutePreviewChoice(firstChoice, trip: trip)
    }
  }

  private func showRoutePreviewChoice(
    _ choice: CarPlayRoutePreviewPayload.Choice,
    trip: CPTrip
  ) {
    mapViewController?.showPreviewRoute(choice.routePoints)
    mapTemplate?.updateEstimates(
      CPTravelEstimates(
        distanceRemaining: Measurement(
          value: choice.distanceMeters,
          unit: UnitLength.meters
        ),
        timeRemaining: choice.durationSeconds
      ),
      for: trip
    )
  }

  private func previewIdentifiers(
    trip: CPTrip,
    routeChoice: CPRouteChoice
  ) -> (previewID: String, choiceID: String)? {
    guard
      let tripInfo = trip.userInfo as? [String: Any],
      let routeInfo = routeChoice.userInfo as? [String: Any],
      let previewID = nonEmptyString(tripInfo["previewId"]),
      let routePreviewID = nonEmptyString(routeInfo["previewId"]),
      previewID == routePreviewID,
      let choiceID = nonEmptyString(routeInfo["routeChoiceId"])
    else { return nil }
    return (previewID, choiceID)
  }

  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    selectedPreviewFor trip: CPTrip,
    using routeChoice: CPRouteChoice
  ) {
    guard
      let identifiers = previewIdentifiers(trip: trip, routeChoice: routeChoice),
      identifiers.previewID == routePreviewCoordinator.preview?.id,
      let choice = routePreviewCoordinator.select(
        choiceID: identifiers.choiceID
      )
    else { return }
    showRoutePreviewChoice(choice, trip: trip)
  }

  func mapTemplate(
    _ mapTemplate: CPMapTemplate,
    startedTrip trip: CPTrip,
    using routeChoice: CPRouteChoice
  ) {
    guard
      let identifiers = previewIdentifiers(trip: trip, routeChoice: routeChoice),
      let selection = routePreviewCoordinator.beginCommit(
        previewID: identifiers.previewID,
        choiceID: identifiers.choiceID
      )
    else { return }

    mapTemplate.hideTripPreviews()
    if navigationCoordinator.beginLoading(routeID: selection.choice.routeID) {
      activeNavigationTrip = trip
      navigationSession = mapTemplate.startNavigationSession(for: trip)
      navigationSession?.pauseTrip(
        for: .loading,
        description: "Preparing route",
        turnCardColor: CarPlayPalette.primaryPanelFill
      )
    }
    (UIApplication.shared.delegate as? AppDelegate)?
      .commitCarPlayDestinationPreview(
        previewID: selection.previewID,
        routeChoiceID: selection.choice.id
      ) { [weak self] success, error in
        DispatchQueue.main.async {
          guard let self else { return }
          self.routePreviewCoordinator.completeCommit(succeeded: success)
          self.routePreviewTrip = nil
          self.mapViewController?.clearPreviewRoute()
          guard !success else { return }
          _ = self.navigationCoordinator.cancel()
          self.cancelActiveNavigationSession()
          self.presentCarPlayError(error ?? "Could not start that route.")
        }
      }
  }

  func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
    // `preview` is retained while the selected route commits, but
    // `routePreviewTrip` is cleared once navigation owns it. Checking the live
    // preview trip prevents End Directions from dismissing stale preview state.
    if routePreviewTrip != nil, navigationSession == nil {
      cancelRoutePreview(notifyDart: true)
      return
    }
    guard navigationCoordinator.cancel() == .cancel else { return }
    cancelActiveNavigationSession()
    (UIApplication.shared.delegate as? AppDelegate)?.cancelCarPlayNavigation()
  }

  private func cancelRoutePreview(notifyDart: Bool) {
    let previewID = routePreviewCoordinator.cancel()
    routePreviewTrip = nil
    mapTemplate?.hideTripPreviews()
    mapViewController?.clearPreviewRoute()
    if notifyDart, let previewID {
      (UIApplication.shared.delegate as? AppDelegate)?
        .cancelCarPlayDestinationPreview(previewID: previewID)
    }
  }

  private func presentFreeRoamConfirmation() {
    guard
      sceneLifecycle.rootReady,
      canFreeRoam,
      let interfaceController
    else { return }
    let sheet = CPActionSheetTemplate(
      title: "Start free roam?",
      message: "Starts a solo ride with no planned route. Your track is still recorded.",
      actions: [
        CPAlertAction(title: "Start free roam", style: .default) { [weak self] _ in
          self?.performConfirmedAction(
            dismissing: interfaceController,
            failureMessage: "Could not start free roam."
          ) { completion in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
              completion(false, nil)
              return
            }
            appDelegate.startFreeRoamFromCarPlay(completion: completion)
          }
        },
        CPAlertAction(title: "Cancel", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
        },
      ]
    )
    interfaceController.presentTemplate(sheet, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay free-roam confirmation was not presented: %@", error.localizedDescription)
      }
    }
  }

  private func presentCarPlayError(_ message: String) {
    guard sceneLifecycle.rootReady, let interfaceController else { return }
    let alert = CPAlertTemplate(
      titleVariants: [message, "Action unavailable"],
      actions: [
        CPAlertAction(title: "OK", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true, completion: nil)
        },
      ]
    )
    interfaceController.presentTemplate(alert, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay error alert was not presented: %@", error.localizedDescription)
      }
    }
  }

  /// Leaves the system confirmation visible while Dart validates the command,
  /// then either dismisses it or replaces it with an actionable CarPlay error.
  /// AppDelegate bounds the wait so a restoring/locked Flutter engine cannot
  /// strand the vehicle UI indefinitely.
  private func performConfirmedAction(
    dismissing interfaceController: CPInterfaceController,
    failureMessage: String,
    action: (@escaping (Bool, String?) -> Void) -> Void
  ) {
    action { [weak self, weak interfaceController] success, errorMessage in
      guard
        let self,
        let interfaceController,
        self.interfaceController === interfaceController
      else { return }
      interfaceController.dismissTemplate(animated: true) {
        [weak self] _, dismissError in
        if let dismissError {
          NSLog(
            "CarPlay action sheet could not be dismissed: %@",
            dismissError.localizedDescription
          )
        }
        if !success {
          self?.presentCarPlayError(errorMessage ?? failureMessage)
        }
      }
    }
  }

  private func statusButton(
    interfaceController: CPInterfaceController,
    template: CPListTemplate
  ) -> CPBarButton {
    // Mirror the phone's compact landscape hamburger instead of allowing the
    // word "Ride" to expand into the largest control in the navigation bar.
    let image = mapButtonImage(
      named: "line.3.horizontal",
      color: CarPlayPalette.actionInk,
      accessibilityLabel: "Ride actions"
    ) ?? UIImage()
    return CPBarButton(image: image) { [weak self, weak interfaceController] _ in
      guard
        let self,
        self.sceneLifecycle.rootReady,
        let interfaceController,
        self.interfaceController === interfaceController
      else { return }
      interfaceController.pushTemplate(template, animated: true) { success, error in
        if !success, let error {
          NSLog("CarPlay ride status was not presented: %@", error.localizedDescription)
        }
      }
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
    guard
      let mapTemplate,
      let rideMenuButton,
      !isShowingPanningInterface
    else { return }
    let enabled = (rideStartPrompt?["enabled"] as? NSNumber)?.boolValue ?? false
    mapTemplate.leadingNavigationBarButtons = enabled
      ? [rideMenuButton, startRideButton()]
      : [rideMenuButton]
  }

  private func startRideButton() -> CPBarButton {
    CPBarButton(title: "Start") { [weak self] _ in
      self?.presentStartRideConfirmation()
    }
  }

  private func presentStartRideConfirmation() {
    guard
      sceneLifecycle.rootReady,
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
          // Hide the action immediately. Dart will either publish the active
          // ride or re-offer it if revalidation rejects the stale snapshot.
          self?.rideStartPrompt = nil
          self?.updateLeadingNavigationButtons()
          self?.performConfirmedAction(
            dismissing: interfaceController,
            failureMessage: "The ride could not be started. Try again."
          ) { completion in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
              completion(false, nil)
              return
            }
            appDelegate.startPreparedRideFromCarPlay { [weak self] success, error in
              if !success {
                self?.rideStartPrompt = self?.latestSnapshot?["rideStart"] as? [String: Any]
                self?.updateLeadingNavigationButtons()
              }
              completion(success, error)
            }
          }
        },
        CPAlertAction(title: "Cancel", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true) { _, error in
            if let error {
              NSLog("CarPlay start sheet could not be dismissed: %@", error.localizedDescription)
            }
          }
        },
      ]
    )
    interfaceController.presentTemplate(sheet, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay start sheet was not presented: %@", error.localizedDescription)
      }
    }
  }

  private func presentReportActions() {
    guard sceneLifecycle.rootReady, let interfaceController else { return }
    let report: (String) -> Void = { [weak self] type in
      self?.performConfirmedAction(
        dismissing: interfaceController,
        failureMessage: "That report could not be sent. Try again."
      ) { completion in
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
          completion(false, nil)
          return
        }
        appDelegate.reportCarPlayHazard(type: type, completion: completion)
      }
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
          interfaceController.dismissTemplate(animated: true) { _, error in
            if let error {
              NSLog("CarPlay report sheet could not be dismissed: %@", error.localizedDescription)
            }
          }
        },
      ]
    )
    interfaceController.presentTemplate(sheet, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay report sheet was not presented: %@", error.localizedDescription)
      }
    }
  }

  private func presentEmergencyConfirmation() {
    guard sceneLifecycle.rootReady, let interfaceController else { return }
    let alert = CPAlertTemplate(
      titleVariants: ["Send SOS to the group?", "Send SOS?"],
      actions: [
        CPAlertAction(title: "Send SOS", style: .destructive) { _ in
          self.performConfirmedAction(
            dismissing: interfaceController,
            failureMessage: "SOS could not be sent. Try again."
          ) { completion in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
              completion(false, nil)
              return
            }
            appDelegate.triggerCarPlayEmergency(completion: completion)
          }
        },
        CPAlertAction(title: "Cancel", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true) { _, error in
            if let error {
              NSLog("CarPlay SOS alert could not be dismissed: %@", error.localizedDescription)
            }
          }
        },
      ]
    )
    interfaceController.presentTemplate(alert, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay SOS alert was not presented: %@", error.localizedDescription)
      }
    }
  }

  private func presentLeaveConfirmation() {
    guard sceneLifecycle.rootReady, let interfaceController else { return }
    let sheet = CPActionSheetTemplate(
      title: "Leave this ride?",
      message: "Stops sharing this rider's position and returns to the home map.",
      actions: [
        CPAlertAction(title: "Leave ride", style: .destructive) { _ in
          self.performConfirmedAction(
            dismissing: interfaceController,
            failureMessage: "The ride could not be left. Try again."
          ) { completion in
            guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
              completion(false, nil)
              return
            }
            appDelegate.leaveRideFromCarPlay(completion: completion)
          }
        },
        CPAlertAction(title: "Cancel", style: .cancel) { _ in
          interfaceController.dismissTemplate(animated: true) { _, error in
            if let error {
              NSLog("CarPlay leave sheet could not be dismissed: %@", error.localizedDescription)
            }
          }
        },
      ]
    )
    interfaceController.presentTemplate(sheet, animated: true) { success, error in
      if !success, let error {
        NSLog("CarPlay leave sheet was not presented: %@", error.localizedDescription)
      }
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

/// Dashboard state is intentionally derived from the same ordered projection
/// as the main navigation session. Route-ready previews and ended rides never
/// become Dashboard map content; only actual guidance may replace the host's
/// normal Dashboard widgets.
struct CarPlayDashboardProjectionState: Equatable {
  private(set) var activeRouteID: String?

  mutating func accepts(snapshot: [String: Any]) -> Bool {
    guard
      let projection = CarPlayNavigationProjectionV2(snapshot: snapshot),
      ["navigating", "paused"].contains(projection.navigationPhase),
      let trip = projection.trip
    else {
      activeRouteID = nil
      return false
    }
    activeRouteID = trip.id
    return true
  }
}

/// Owns the CarPlay Dashboard's second map window. The main CPMapTemplate owns
/// the single CPNavigationSession and therefore the system manoeuvre/estimate
/// presentation; this scene draws only the matching map behind those system
/// elements and never starts a duplicate ride or navigation session.
final class CarPlayDashboardSceneDelegate: UIResponder,
  CPTemplateApplicationDashboardSceneDelegate
{
  private var dashboardController: CPDashboardController?
  private var dashboardWindow: UIWindow?
  private var mapViewController: CarPlayNavigationViewController?
  private var projectionState = CarPlayDashboardProjectionState()

  func templateApplicationDashboardScene(
    _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
    didConnect dashboardController: CPDashboardController,
    to window: UIWindow
  ) {
    let mapViewController = CarPlayNavigationViewController()
    self.dashboardController = dashboardController
    dashboardWindow = window
    self.mapViewController = mapViewController
    dashboardController.shortcutButtons = []
    mapViewController.apply(
      contentStyle: window.traitCollection.userInterfaceStyle == .dark
        ? [.dark]
        : [.light]
    )
    window.rootViewController = mapViewController
    (UIApplication.shared.delegate as? AppDelegate)?
      .carPlayDashboardDidConnect(self)
  }

  func templateApplicationDashboardScene(
    _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
    didDisconnect dashboardController: CPDashboardController,
    from window: UIWindow
  ) {
    guard
      self.dashboardController === dashboardController,
      dashboardWindow === window
    else { return }
    (UIApplication.shared.delegate as? AppDelegate)?
      .carPlayDashboardDidDisconnect(self)
    window.rootViewController = nil
    self.dashboardController = nil
    dashboardWindow = nil
    mapViewController = nil
    projectionState = CarPlayDashboardProjectionState()
  }

  func apply(snapshot: [String: Any]) {
    guard projectionState.accepts(snapshot: snapshot) else { return }
    mapViewController?.apply(snapshot: snapshot)
  }

  func apply(viewport: [String: Any]) {
    guard projectionState.activeRouteID != nil else { return }
    mapViewController?.apply(viewport: viewport)
  }

  func apply(mapStyle: [String: Any]) {
    mapViewController?.apply(mapStyle: mapStyle)
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
  static let ownRider = UIColor(red: 0x2F / 255, green: 0x80 / 255, blue: 0xED / 255, alpha: 1)
  static let tailEndCharlie = UIColor(red: 0x68 / 255, green: 0xA9 / 255, blue: 0xFF / 255, alpha: 1)
  static let rider = UIColor(red: 0x6E / 255, green: 0xD8 / 255, blue: 0x9A / 255, alpha: 1)
  static let alerting = UIColor(red: 0xFF / 255, green: 0x5D / 255, blue: 0x73 / 255, alpha: 1)

  /// The ride chrome's card fill and its label ink, from the phone's TEC card.
  static let cardFill = UIColor(red: 0x25 / 255, green: 0x2E / 255, blue: 0x39 / 255, alpha: 0.90)
  static let primaryPanelFill = UIColor(
    red: 0x25 / 255,
    green: 0x2E / 255,
    blue: 0x39 / 255,
    alpha: 0.85
  )
  static let cardLabel = UIColor(red: 0xB7 / 255, green: 0xC2 / 255, blue: 0xCF / 255, alpha: 1)
  static let cardTitle = UIColor.white
  static let actionInk = UIColor(red: 0xE4 / 255, green: 0xE9 / 255, blue: 0xEF / 255, alpha: 1)
  static let reportAccent = UIColor(red: 0xFF / 255, green: 0xD2 / 255, blue: 0x4A / 255, alpha: 1)
  static let emergencyFill = UIColor(red: 0xD9 / 255, green: 0x30 / 255, blue: 0x4F / 255, alpha: 1)
  static let leaveFill = UIColor(red: 0x54 / 255, green: 0x5F / 255, blue: 0x6E / 255, alpha: 1)

  /// `RouteLineStyle.routeAhead`: 6pt line on a 10pt casing.
  static let routeWidth: CGFloat = 6
  static let routeCasingWidth: CGFloat = 10

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
final class CarPlayNavigationViewController: UIViewController,
  MLNMapViewDelegate
{
  private var mapView: MLNMapView?
  private var routeSource: MLNShapeSource?
  private var routeCoordinates: [CLLocationCoordinate2D] = []
  private var previewRouteCoordinates: [CLLocationCoordinate2D]?
  private var routeID: String?
  private var routeProjectionKey: String?
  private var riderAnnotations: [CarPlayRiderAnnotation] = []
  private var maneuverCoordinates: [CLLocationCoordinate2D] = []
  private var localCoordinate: CLLocationCoordinate2D?
  private var localHeading: CLLocationDirection?
  private var followsLocalRider = true
  private var snapshotWantsRiderFollow = false
  private var panGestureStartCoordinate: CLLocationCoordinate2D?
  private var directionalPanTimer: Timer?
  private var zoomGestureStartLevel: Double?
  private var rotationGestureStartHeading: CLLocationDirection?
  private var pitchGestureStart: (point: CGPoint?, pitch: CGFloat)?
  private var hasFramedFirstFix = false
  private var surfaceMode = "unavailable"
  private var hostContentStyle: CPContentStyle = [.light]
  private var appliedHostInsets: UIEdgeInsets?

  /// Dart supplies both basemap variants plus the resolved document currently
  /// used by the phone. The resolved document is reused only when it matches
  /// CarPlay's requested appearance; the vehicle host owns day/night choice.
  private var lightStyleURL: URL?
  private var darkStyleURL: URL?
  private var appliedStyleURL: URL?
  private var phoneStyleURL: URL?
  private var phoneStyleJSON: String?
  private var phoneStyleIsDark = false
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

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyHostSafeAreaIfNeeded()
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyHostSafeAreaIfNeeded()
  }

  deinit {
    directionalPanTimer?.invalidate()
  }

  func apply(contentStyle: CPContentStyle) {
    hostContentStyle = contentStyle
    applyPreferredStyle()
  }

  func apply(snapshot: [String: Any]) {
    latestSnapshot = snapshot
    updateStyleURLs(snapshot["basemap"] as? [String: Any])
    guard let mapView else { return }
    surfaceMode = snapshot["surfaceMode"] as? String ?? "activeRide"
    if surfaceMode != "activeRide" {
      // A viewport belongs to the moving ride that produced it. Replaying it
      // over the home or pre-ride map is what reopened CarPlay miles away from
      // the phone after ending a ride.
      latestViewport = nil
    }
    let incomingRouteID = snapshot["routeId"] as? String
    let progress = (snapshot["routeProgressMeters"] as? NSNumber)?.doubleValue ?? 0
    let routeKey = "\(incomingRouteID ?? "none"):\(Int(progress / 2))"
    let routeChanged = previewRouteCoordinates == nil
      && (routeKey != routeProjectionKey || routeSource == nil)
    if routeChanged {
      updateRoute(
        snapshot["routePoints"],
        remaining: snapshot["remainingRoutePoints"]
      )
      routeID = incomingRouteID
      routeProjectionKey = routeKey
    }
    updateManeuverCoordinates(snapshot)
    updateRiders(snapshot)
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
    } else if previewRouteCoordinates != nil {
      showPreviewRouteCoordinates()
    } else if routeChanged || cameraModeChanged {
      showCompleteRoute()
    }
  }

  func showPreviewRoute(_ points: [CarPlayRoutePreviewPayload.Coordinate]) {
    let coordinates = points.map(\.clLocationCoordinate)
    guard coordinates.count >= 2 else { return }
    previewRouteCoordinates = coordinates
    showPreviewRouteCoordinates()
  }

  func clearPreviewRoute() {
    guard previewRouteCoordinates != nil else { return }
    previewRouteCoordinates = nil
    routeProjectionKey = nil
    if let latestSnapshot {
      apply(snapshot: latestSnapshot)
    } else {
      updateRemainingRoute([])
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
    }
    if let dark = (viewport["mapStyleDark"] as? NSNumber)?.boolValue {
      phoneStyleIsDark = dark
    }
    applyPreferredStyle()
    guard
      surfaceMode == "activeRide",
      snapshotWantsRiderFollow,
      followsLocalRider
    else { return }
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
    phoneStyleIsDark =
      (mapStyle["dark"] as? NSNumber)?.boolValue ?? phoneStyleIsDark
    if
      let rawURL = mapStyle["fallbackStyleUrl"] as? String,
      let fallbackURL = URL(string: rawURL)
    {
      phoneStyleURL = fallbackURL
    }
    applyPreferredStyle()
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
    if surfaceMode == "home" {
      mapView.userTrackingMode = .none
      mapView.setCenter(coordinate, zoomLevel: 14, animated: true)
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

  func beginDirectionalPan(direction: CPMapTemplate.PanDirection) {
    endDirectionalPan()
    pan(direction: direction)
    directionalPanTimer = Timer.scheduledTimer(
      withTimeInterval: 0.18,
      repeats: true
    ) { [weak self] _ in
      self?.pan(direction: direction)
    }
  }

  func endDirectionalPan() {
    directionalPanTimer?.invalidate()
    directionalPanTimer = nil
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

  func beginZoomGesture() {
    followsLocalRider = false
    mapView?.userTrackingMode = .none
    zoomGestureStartLevel = mapView?.zoomLevel
  }

  func zoom(by delta: Double) {
    followsLocalRider = false
    guard let mapView else { return }
    mapView.userTrackingMode = .none
    mapView.setZoomLevel(mapView.zoomLevel + delta, animated: true)
  }

  func updateZoomGesture(scale: CGFloat) {
    guard
      let mapView,
      let start = zoomGestureStartLevel,
      scale.isFinite,
      scale > 0
    else { return }
    mapView.zoomLevel = start + log2(Double(scale))
  }

  func endZoomGesture() {
    zoomGestureStartLevel = nil
  }

  func beginRotationGesture() {
    followsLocalRider = false
    mapView?.userTrackingMode = .none
    rotationGestureStartHeading = mapView?.direction
  }

  func updateRotationGesture(rotation: CGFloat) {
    guard
      let mapView,
      let start = rotationGestureStartHeading,
      rotation.isFinite
    else { return }
    let camera = mapView.camera
    let heading = start - CLLocationDirection(rotation * 180 / .pi)
    mapView.setCamera(
      MLNMapCamera(
        lookingAtCenter: camera.centerCoordinate,
        altitude: camera.altitude,
        pitch: camera.pitch,
        heading: heading
      ),
      animated: false
    )
  }

  func endRotationGesture() {
    rotationGestureStartHeading = nil
  }

  func beginPitchGesture() {
    followsLocalRider = false
    mapView?.userTrackingMode = .none
    pitchGestureStart = (nil, mapView?.camera.pitch ?? 0)
  }

  func updatePitchGesture(center: CGPoint) {
    guard let mapView, var start = pitchGestureStart else { return }
    if start.point == nil {
      start.point = center
      pitchGestureStart = start
      return
    }
    guard let startPoint = start.point else { return }
    let camera = mapView.camera
    let pitch = min(60, max(0, start.pitch + (startPoint.y - center.y) * 0.25))
    mapView.setCamera(
      MLNMapCamera(
        lookingAtCenter: camera.centerCoordinate,
        altitude: camera.altitude,
        pitch: pitch,
        heading: camera.heading
      ),
      animated: false
    )
  }

  func endPitchGesture() {
    pitchGestureStart = nil
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
    phoneStyleIsDark =
      (basemap["dark"] as? NSNumber)?.boolValue ?? phoneStyleIsDark
    if let styleJSON = basemap["styleJson"] as? String, !styleJSON.isEmpty {
      phoneStyleJSON = styleJSON
    }
    applyPreferredStyle()
  }

  private func applyPreferredStyle() {
    let hostWantsDark = hostContentStyle.contains(.dark)
    if phoneStyleIsDark == hostWantsDark, let preferredJSON = phoneStyleJSON {
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
    let preferred = (hostWantsDark ? darkStyleURL : lightStyleURL)
      ?? phoneStyleURL
    guard let preferred, preferred != appliedStyleURL else { return }
    appliedStyleURL = preferred
    appliedStyleJSON = nil
    guard let mapView else {
      installMapView(styleURL: preferred)
      return
    }
    mapView.styleURL = preferred
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
    // than decoration. Keep both MapLibre controls on the right, clear of the
    // app's left-hand status column and the top-trailing speed pair.
    mapView.logoView.isHidden = true
    mapView.attributionButtonPosition = .bottomRight
    mapView.attributionButtonMargins = CGPoint(x: 52, y: 14)
    mapView.compassView.isHidden = true
    // Match the phone home map's no-fix fallback rather than MapLibre's
    // world-sized default. As soon as the phone publishes an authorised fix,
    // the saved rider marker and the same z14 home framing replace this.
    mapView.setCenter(
      CLLocationCoordinate2D(latitude: 54.5, longitude: -3.2),
      zoomLevel: 5,
      animated: false
    )
    view.insertSubview(mapView, at: 0)
    self.mapView = mapView
    applyHostSafeAreaIfNeeded()
    if let latestSnapshot { apply(snapshot: latestSnapshot) }
    if let latestViewport { apply(viewport: latestViewport) }
  }

  private func applyHostSafeAreaIfNeeded() {
    guard let mapView, view.bounds.width > 0, view.bounds.height > 0 else { return }
    let safeArea = CarPlayMapSafeArea(
      viewBounds: view.bounds,
      safeFrame: view.safeAreaLayoutGuide.layoutFrame
    )
    guard appliedHostInsets != safeArea.contentInsets else { return }
    appliedHostInsets = safeArea.contentInsets
    mapView.automaticallyAdjustsContentInset = false
    mapView.contentInset = safeArea.contentInsets

    // A host can change its safe region when the navigation bar, guidance
    // card, or secondary display state changes. Refit the current mode without
    // taking a deliberately panned map back from the rider.
    if snapshotWantsRiderFollow, followsLocalRider, latestViewport != nil {
      applyPhoneViewport(animated: false)
    } else if previewRouteCoordinates != nil {
      showPreviewRouteCoordinates(animated: false)
    } else if !followsLocalRider {
      return
    } else {
      showCompleteRoute(animated: false)
    }
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
      let phoneWidth = (viewport["sourceViewportWidthPixels"] as? NSNumber)?.doubleValue,
      phoneHeight > 0,
      phoneWidth > 0,
      latitude.isFinite,
      longitude.isFinite,
      phoneZoom.isFinite,
      (-90 ... 90).contains(latitude),
      (-180 ... 180).contains(longitude)
    else { return }

    let safeFrame = view.safeAreaLayoutGuide.layoutFrame
    guard safeFrame.width > 0, safeFrame.height > 0 else { return }
    let heightRatio = Double(safeFrame.height) / phoneHeight
    guard heightRatio.isFinite, heightRatio > 0 else { return }
    let adjustedZoom = phoneZoom + log2(heightRatio)
    let rawTilt = (viewport["tilt"] as? NSNumber)?.doubleValue ?? 0
    let tilt = min(60, max(0, rawTilt))
    let bearing = (viewport["bearing"] as? NSNumber)?.doubleValue ?? 0
    let riderVerticalFraction = min(
      0.8,
      max(0.35, (viewport["riderViewportFraction"] as? NSNumber)?.doubleValue ?? 0.64)
    )
    // CarPlay is always landscape even when its attached phone is portrait.
    // A portrait phone publishes a centred phone anchor, so derive the car's
    // traffic-side third from the route handedness instead of copying 0.5.
    let leftHandTraffic =
      (viewport["leftHandTraffic"] as? NSNumber)?.boolValue ?? true
    let riderHorizontalFraction = leftHandTraffic ? (2.0 / 3.0) : (1.0 / 3.0)
    guard adjustedZoom.isFinite, tilt.isFinite, bearing.isFinite else { return }

    // MapLibre's zoom is the scale of 512 px Web Mercator tiles. Convert that
    // scale back to the MLNMapCamera altitude API while preserving the phone's
    // pitch and look-ahead target.
    let latitudeRadians = latitude * .pi / 180
    let metresPerPoint =
      78_271.516_964_020_48 * abs(cos(latitudeRadians)) / pow(2, adjustedZoom)
    let fieldOfView = 0.643_501_108_793_284_4
    let cameraToCenterDistance =
      Double(safeFrame.height) * 0.5 / tan(fieldOfView * 0.5)
    let altitude = cameraToCenterDistance * metresPerPoint * cos(tilt * .pi / 180)
    guard altitude.isFinite, altitude > 0 else { return }

    mapView.userTrackingMode = .none
    let camera = MLNMapCamera(
      lookingAtCenter: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      altitude: altitude,
      pitch: tilt,
      heading: bearing
    )
    // Establish scale and pitch first, then use MapLibre's own projection to
    // put the local rider at the exact traffic-side anchor on this wider
    // screen. CarPlay owns every card and button over this map.
    mapView.setCamera(camera, animated: false)
    view.layoutIfNeeded()
    let desired = CGPoint(
      x: safeFrame.minX + safeFrame.width * riderHorizontalFraction,
      y: safeFrame.minY + safeFrame.height * riderVerticalFraction
    )
    if let localCoordinate {
      var correctedCamera = camera
      // A pitched Mercator projection is not linear in screen Y, so a single
      // centre translation only moved part of the way to the requested anchor
      // on the 1920×720 CarPlay canvas. Reproject after each correction; three
      // small passes converge to the exact open-map point without guessing a
      // latitude-dependent offset.
      for _ in 0 ..< 3 {
        mapView.setCamera(correctedCamera, animated: false)
        let riderPoint = mapView.convert(localCoordinate, toPointTo: mapView)
        let error = CGPoint(
          x: riderPoint.x - desired.x,
          y: riderPoint.y - desired.y
        )
        if hypot(error.x, error.y) < 1 { break }
        let centrePoint = mapView.convert(
          correctedCamera.centerCoordinate,
          toPointTo: mapView
        )
        let correctedCentre = CGPoint(
          x: centrePoint.x + error.x,
          y: centrePoint.y + error.y
        )
        correctedCamera = MLNMapCamera(
          lookingAtCenter: mapView.convert(
            correctedCentre,
            toCoordinateFrom: mapView
          ),
          altitude: altitude,
          pitch: tilt,
          heading: bearing
        )
      }
      // The phone keeps publishing moving fixes, so these small deterministic
      // steps are already continuous. A second UIKit animation here leaves the
      // marker one animation behind and puts it back under the guidance card.
      mapView.setCamera(correctedCamera, animated: false)
    } else {
      mapView.setCamera(camera, animated: animated)
    }
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
    let previousAnnotations = riderAnnotations.map { $0 as MLNAnnotation }
    if !previousAnnotations.isEmpty {
      // MapLibre normally clears these during the style swap. Removing the
      // retained objects as well closes the short timing window where a
      // snapshot lands between the swap and this callback and would otherwise
      // leave two local-rider badges on the CarPlay map.
      mapView.removeAnnotations(previousAnnotations)
    }
    routeSource = nil
    riderAnnotations = []
    routeID = nil
    routeProjectionKey = nil
    if let latestSnapshot {
      apply(snapshot: latestSnapshot)
    } else if previewRouteCoordinates != nil {
      showPreviewRouteCoordinates()
    }
    if let latestViewport { apply(viewport: latestViewport) }
  }

  // MARK: - Content

  private func updateRoute(_ raw: Any?, remaining: Any?) {
    let allPoints = (raw as? [[String: Any]] ?? []).compactMap(coordinate(from:))
    guard allPoints.count >= 2 else {
      routeCoordinates = []
      routeSource?.shape = nil
      return
    }
    routeCoordinates = allPoints
    var remainingPoints =
      (remaining as? [[String: Any]] ?? []).compactMap(coordinate(from:))
    if remainingPoints.count < 2 {
      remainingPoints = allPoints
    }
    updateRemainingRoute(remainingPoints)
  }

  private func updateManeuverCoordinates(_ snapshot: [String: Any]) {
    guard
      let navigation = snapshot["carplayNavigation"] as? [String: Any]
    else {
      maneuverCoordinates = []
      return
    }
    maneuverCoordinates = ["currentManeuver", "followingManeuver"].compactMap {
      key in
      guard
        let maneuver = navigation[key] as? [String: Any],
        let position = maneuver["position"] as? [String: Any]
      else { return nil }
      return coordinate(from: position)
    }
  }

  /// The phone's route ahead is a long dash, not a solid line. Shape
  /// annotations have no dash property, so this one part of the route uses two
  /// MapLibre style layers over a shared source: an aligned dashed casing and
  /// the aligned green stroke above it. Completed planned-route geometry is
  /// intentionally omitted so the road immediately behind the rider is map,
  /// matching the phone navigation surface.
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
  private func showCompleteRoute(animated: Bool = true) {
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
    var coordinates = overviewCoordinates(routeCoordinates)
    mapView.setVisibleCoordinates(
      &coordinates,
      count: UInt(coordinates.count),
      edgePadding: UIEdgeInsets(top: 36, left: 36, bottom: 44, right: 36),
      animated: animated
    )
  }

  private func showPreviewRouteCoordinates(animated: Bool = true) {
    guard let mapView, var coordinates = previewRouteCoordinates else { return }
    guard coordinates.count >= 2 else { return }
    mapView.userTrackingMode = .none
    updateRemainingRoute(coordinates)
    coordinates = overviewCoordinates(coordinates)
    mapView.setVisibleCoordinates(
      &coordinates,
      count: UInt(coordinates.count),
      edgePadding: UIEdgeInsets(top: 36, left: 36, bottom: 52, right: 36),
      animated: animated
    )
  }

  private func overviewCoordinates(
    _ route: [CLLocationCoordinate2D]
  ) -> [CLLocationCoordinate2D] {
    var coordinates = route
    coordinates.append(contentsOf: maneuverCoordinates)
    coordinates.append(contentsOf: riderAnnotations.map(\.coordinate))
    if let localCoordinate { coordinates.append(localCoordinate) }
    return coordinates
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
    label.textColor = CarPlayPalette.markerGlyph
    label.shadowColor = nil
    label.shadowOffset = .zero
    imageView.image = nil

    if let initials = initialsIdentity(
      symbol: rider.riderSymbol,
      fallbackName: rider.title ?? ""
    ) {
      label.attributedText = NSAttributedString(
        string: initials.text,
        attributes: [.kern: -0.8]
      )
      label.textColor = initials.color
      label.shadowColor = initials.edge
      label.shadowOffset = CGSize(width: 0.7, height: 0.7)
      label.font = .systemFont(ofSize: 30, weight: .black)
    } else if rider.riderSymbol.hasPrefix("emoji:") {
      label.text = String(rider.riderSymbol.dropFirst("emoji:".count))
      label.font = .systemFont(ofSize: 21)
    } else {
      imageView.image = motorcycleImage(for: rider.motorcycleStyle)
    }
    setNeedsLayout()
  }

  private func initialsIdentity(
    symbol: String,
    fallbackName: String
  ) -> (text: String, color: UIColor, edge: UIColor)? {
    if symbol == "initials" {
      return (
        riderInitials(fallbackName),
        CarPlayPalette.markerGlyph,
        UIColor.white.withAlphaComponent(0.9)
      )
    }
    guard symbol.hasPrefix("initials:v1:") else { return nil }
    let parts = symbol.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "initials", parts[1] == "v1" else {
      return nil
    }
    let encoded = String(parts[2])
    let text: String
    if encoded.isEmpty {
      text = riderInitials(fallbackName)
    } else {
      var base64 = encoded.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
      base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
      guard
        let data = Data(base64Encoded: base64),
        let decoded = String(data: data, encoding: .utf8)
      else { return nil }
      let normalized = decoded.uppercased()
      guard
        (1...3).contains(normalized.count),
        normalized.unicodeScalars.allSatisfy({
          CharacterSet.alphanumerics.contains($0)
        })
      else { return nil }
      text = normalized
    }
    let inkName = String(parts[3])
    guard let ink = initialsInk(named: inkName) else { return nil }
    let darkEdgeNames: Set<String> = ["white", "yellow", "cyan", "pink"]
    let edge = darkEdgeNames.contains(inkName)
      ? CarPlayPalette.casing.withAlphaComponent(0.9)
      : UIColor.white.withAlphaComponent(0.9)
    return (text, ink, edge)
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
    case "purple": return UIColor(red: 0x9B / 255, green: 0x7B / 255, blue: 0xFF / 255, alpha: 1)
    case "white": return UIColor(red: 0xF4 / 255, green: 0xF6 / 255, blue: 0xF8 / 255, alpha: 1)
    case "blue": return UIColor(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255, alpha: 1)
    case "lime": return UIColor(red: 0xA7 / 255, green: 0xD9 / 255, blue: 0x57 / 255, alpha: 1)
    case "slate": return UIColor(red: 0x87 / 255, green: 0x96 / 255, blue: 0xA8 / 255, alpha: 1)
    default: return CarPlayPalette.rider
    }
  }

  private func initialsInk(named name: String) -> UIColor? {
    switch name {
    case "dark": return CarPlayPalette.markerGlyph
    case "white": return .white
    case "yellow": return UIColor(red: 0xFF / 255, green: 0xD8 / 255, blue: 0x4D / 255, alpha: 1)
    case "cyan": return UIColor(red: 0x3D / 255, green: 0xDC / 255, blue: 0xFF / 255, alpha: 1)
    case "pink": return UIColor(red: 0xFF / 255, green: 0x76 / 255, blue: 0xC8 / 255, alpha: 1)
    case "purple": return UIColor(red: 0x9B / 255, green: 0x7B / 255, blue: 0xFF / 255, alpha: 1)
    default: return nil
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
    backgroundColor = CarPlayPalette.primaryPanelFill
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    // Thicker and brighter than the 1.5 px casing it had (#442): "it blends into
    // the main map, so it is not obvious which is which". A hairline in the
    // casing colour is invisible against a basemap that is mostly the same
    // greys.
    layer.borderWidth = 3
    layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.6
    layer.shadowRadius = 6
    layer.shadowOffset = .zero
    layer.masksToBounds = false
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
    caption.adjustsFontSizeToFitWidth = true
    caption.minimumScaleFactor = 0.7
    addSubview(caption)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      // Bounded on both sides now that it carries a scale as well as a count:
      // the view is 110pt wide and the text must give way inside it rather than
      // widening the overview.
      caption.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -6
      ),
      caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      caption.heightAnchor.constraint(equalToConstant: 19),
    ])
  }

  /// The east-west span of the overview, in the rider's own units.
  ///
  /// The width rather than the diagonal: it is what the eye reads across the
  /// picture, and it is the number a map scale bar has always meant.
  static func spanLabel(
    for bounds: MLNCoordinateBounds,
    usesMiles: Bool
  ) -> String {
    let west = CLLocation(
      latitude: bounds.sw.latitude,
      longitude: bounds.sw.longitude
    )
    let east = CLLocation(
      latitude: bounds.sw.latitude,
      longitude: bounds.ne.longitude
    )
    let meters = west.distance(from: east)
    if usesMiles {
      let miles = meters / 1_609.344
      return miles < 0.5
        ? "\(Int((meters / 0.9144).rounded())) yd"
        : String(format: "%.1f mi", miles)
    }
    return meters < 950
      ? "\(Int(meters.rounded())) m"
      : String(format: "%.1f km", meters / 1_000)
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
    // How far the picture spans, so a rider can tell what they are looking at
    // (#442: "It needs a clear edge, and a scale"). Without it the overview could
    // be a hundred metres or ten miles and there is nothing on it to say which.
    let span = Self.spanLabel(
      for: Self.groupBounds(for: riders.map(\.coordinate)),
      usesMiles: CarPlayUnitPolicy(
        distanceUnit: snapshot["distanceUnit"] as? String,
        localeIdentifier: snapshot["localeIdentifier"] as? String
      ).usesMiles
    )
    caption.text = "  \(riders.count) \(riderWord) · \(span)  "
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
    // Render at the dynamically constrained rail size. A fixed 110x70 image
    // stretched into a 196-point view was both blurry and made it easy to miss
    // that the outer view had escaped the intended column.
    let renderSize = self.bounds.width >= 100 && self.bounds.height >= 60
      ? self.bounds.size
      : CGSize(width: 160, height: 95)
    let options = MLNMapSnapshotOptions(
      styleURL: resolvedStyleURL,
      camera: camera,
      size: renderSize
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
    context.clip(to: overlay.context.boundingBoxOfClipPath)

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

/// App-owned compass paired with the speed sign. Its footprint is deliberately
/// the same 34-point circle as [CarPlaySpeedLimitBadge]'s sign.
private final class CarPlayCompassBadge: UIView {
  private let arrow = UIImageView()
  private let north = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.cornerRadius = 17
    layer.cornerCurve = .continuous
    layer.borderWidth = 2
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.4
    layer.shadowRadius = 4
    layer.shadowOffset = CGSize(width: 0, height: 2)

    arrow.translatesAutoresizingMaskIntoConstraints = false
    arrow.image = UIImage(systemName: "location.north.fill")
    arrow.contentMode = .scaleAspectFit
    arrow.tintColor = CarPlayPalette.emergencyFill
    addSubview(arrow)
    north.translatesAutoresizingMaskIntoConstraints = false
    north.text = "N"
    north.font = .systemFont(ofSize: 8, weight: .black)
    north.textAlignment = .center
    addSubview(north)
    NSLayoutConstraint.activate([
      arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
      arrow.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
      arrow.widthAnchor.constraint(equalToConstant: 16),
      arrow.heightAnchor.constraint(equalToConstant: 16),
      north.centerXAnchor.constraint(equalTo: centerXAnchor),
      north.topAnchor.constraint(equalTo: topAnchor, constant: 3),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(direction: CLLocationDirection, darkMap: Bool) {
    backgroundColor = darkMap
      ? CarPlayPalette.cardFill
      : UIColor.white.withAlphaComponent(0.90)
    layer.borderColor = (
      darkMap ? UIColor(red: 0x89 / 255, green: 0x93 / 255, blue: 0xA0 / 255, alpha: 1)
        : UIColor(red: 0x30 / 255, green: 0x34 / 255, blue: 0x3B / 255, alpha: 1)
    ).cgColor
    north.textColor = darkMap ? .white : .black
    arrow.transform = CGAffineTransform(rotationAngle: -direction * .pi / 180)
    accessibilityLabel = "Map heading \(Int(direction.rounded())) degrees"
  }
}

/// Phone-style turn card used instead of starting a template navigation
/// session. The latter always adds Apple's separate trip-estimate panel, which
/// duplicated the app-owned ETA and could not be hidden independently.
private final class CarPlayGuidanceView: UIView {
  private let symbol = UIImageView()
  private let title = UILabel()
  private let detail = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isHidden = true
    isUserInteractionEnabled = false
    backgroundColor = CarPlayPalette.primaryPanelFill
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

    symbol.translatesAutoresizingMaskIntoConstraints = false
    symbol.contentMode = .scaleAspectFit
    symbol.tintColor = CarPlayPalette.routeAhead
    addSubview(symbol)
    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = .systemFont(ofSize: 17, weight: .bold)
    title.textColor = CarPlayPalette.cardTitle
    title.numberOfLines = 2
    title.adjustsFontSizeToFitWidth = true
    title.minimumScaleFactor = 0.76
    addSubview(title)
    detail.translatesAutoresizingMaskIntoConstraints = false
    detail.font = .systemFont(ofSize: 12, weight: .semibold)
    detail.textColor = CarPlayPalette.cardLabel
    detail.numberOfLines = 1
    detail.adjustsFontSizeToFitWidth = true
    detail.minimumScaleFactor = 0.76
    addSubview(detail)
    NSLayoutConstraint.activate([
      symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
      symbol.widthAnchor.constraint(equalToConstant: 30),
      symbol.heightAnchor.constraint(equalToConstant: 30),
      title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 9),
      title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(snapshot: [String: Any]) {
    let marker = snapshot["marker"] as? [String: Any]
    let headline = Self.nonEmpty(marker?["title"])
      ?? Self.nonEmpty(snapshot["guidanceTitle"])
    guard
      let headline,
      marker != nil || !headline.lowercased().contains("no more turns")
    else {
      isHidden = true
      return
    }
    isHidden = false
    title.text = headline
    detail.text = Self.nonEmpty(marker?["detail"])
      ?? Self.nonEmpty(snapshot["guidanceDetail"])
    symbol.image = UIImage(systemName: Self.symbolName(for: headline))
    accessibilityLabel = [headline, detail.text].compactMap { $0 }.joined(separator: ". ")
  }

  private static func nonEmpty(_ raw: Any?) -> String? {
    guard let value = raw as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func symbolName(for title: String) -> String {
    let lower = title.lowercased()
    if lower.contains("roundabout") { return "arrow.clockwise.circle" }
    if lower.contains("left") { return "arrow.turn.up.left" }
    if lower.contains("right") { return "arrow.turn.up.right" }
    if lower.contains("arrive") || lower.contains("destination") {
      return "flag.checkered"
    }
    return "arrow.up"
  }
}

/// The active-ride controls use the same labelled action language as phone
/// landscape. Generic template follow/browse buttons are intentionally absent;
/// Follow appears only after a deliberate pan.
private final class CarPlayRideActionsView: UIStackView {
  private let follow = CarPlayRideActionButton(
    title: "FOLLOW",
    symbol: "location.north",
    fill: CarPlayPalette.cardFill,
    ink: CarPlayPalette.actionInk
  )
  private let alert = CarPlayRideActionButton(
    title: "ALERT",
    symbol: "sos",
    fill: CarPlayPalette.emergencyFill,
    ink: .white
  )
  private let leave = CarPlayRideActionButton(
    title: "LEAVE",
    symbol: "rectangle.portrait.and.arrow.right",
    fill: CarPlayPalette.leaveFill,
    ink: .white
  )
  private let report = CarPlayRideActionButton(
    title: "REPORT",
    symbol: "bell.badge.fill",
    fill: CarPlayPalette.cardFill,
    ink: CarPlayPalette.reportAccent
  )

  var onFollow: (() -> Void)?
  var onReport: (() -> Void)?
  var onEmergency: (() -> Void)?
  var onLeave: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    axis = .vertical
    alignment = .fill
    distribution = .fill
    spacing = 10
    for button in [follow, alert, leave, report] {
      button.heightAnchor.constraint(equalToConstant: 34).isActive = true
      button.widthAnchor.constraint(equalToConstant: 82).isActive = true
      addArrangedSubview(button)
    }
    follow.addAction(UIAction { [weak self] _ in self?.onFollow?() }, for: .primaryActionTriggered)
    alert.addAction(UIAction { [weak self] _ in self?.onEmergency?() }, for: .primaryActionTriggered)
    leave.addAction(UIAction { [weak self] _ in self?.onLeave?() }, for: .primaryActionTriggered)
    report.addAction(UIAction { [weak self] _ in self?.onReport?() }, for: .primaryActionTriggered)
    setFollowing(true)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func setFollowing(_ following: Bool) {
    follow.isHidden = following
  }
}

private final class CarPlayRideActionButton: UIButton {
  init(title: String, symbol: String, fill: UIColor, ink: UIColor) {
    super.init(frame: .zero)
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.image = UIImage(systemName: symbol)
    configuration.imagePadding = 4
    configuration.imagePlacement = .leading
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 10,
      weight: .bold
    )
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 6,
      leading: 6,
      bottom: 6,
      trailing: 6
    )
    configuration.titleLineBreakMode = .byClipping
    configuration.baseBackgroundColor = fill
    configuration.baseForegroundColor = ink
    configuration.cornerStyle = .large
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
      incoming in
      var outgoing = incoming
      outgoing.font = .systemFont(ofSize: 7, weight: .black)
      return outgoing
    }
    self.configuration = configuration
    titleLabel?.numberOfLines = 1
    titleLabel?.adjustsFontSizeToFitWidth = true
    titleLabel?.minimumScaleFactor = 0.72
    accessibilityLabel = title.capitalized
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// The visual button is deliberately compact, but the effective target keeps
  /// CarPlay's 44-point minimum. Ten-point stack spacing means neighbouring
  /// expanded targets meet without overlapping.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -5, dy: -5).contains(point)
  }
}

/// The phone's landscape speed-limit sign and current-speed readout, scaled for
/// CarPlay's shorter map canvas. It follows the same explicit unit policy as
/// system travel estimates; locale is only a fallback for restored old data.
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

  func apply(
    _ speed: [String: Any]?,
    distanceUnit: String?,
    localeIdentifier: String?
  ) {
    guard let speed else {
      isHidden = true
      spinner.stopAnimating()
      return
    }
    isHidden = false

    let status = speed["limitStatus"] as? String
    let limitMilesPerHour = (speed["limitMilesPerHour"] as? NSNumber)?.intValue
    let unlimited = (speed["limitUnlimited"] as? NSNumber)?.boolValue ?? false
    let known = status == "known" && (limitMilesPerHour != nil || unlimited)
    let checking = status == "checking"
    let unitPolicy = CarPlayUnitPolicy(
      distanceUnit: distanceUnit,
      localeIdentifier: localeIdentifier
    )
    let displayedLimit = limitMilesPerHour.map {
      unitPolicy.usesMiles ? $0 : Int((Double($0) * 1.609_344).rounded())
    }
    limitLabel.isHidden = checking
    if checking {
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
      limitLabel.text = known ? (unlimited ? "∞" : "\(displayedLimit!)") : "–"
    }
    sign.layer.borderColor = (
      known
        ? UIColor(red: 0xD7 / 255, green: 0x19 / 255, blue: 0x20 / 255, alpha: 1)
        : UIColor(red: 0x89 / 255, green: 0x93 / 255, blue: 0xA0 / 255, alpha: 1)
    ).cgColor

    let metresPerSecond = (speed["metresPerSecond"] as? NSNumber)?.doubleValue
    let displayedSpeed = metresPerSecond.flatMap { value in
      value.isFinite && value >= 0 ? unitPolicy.speedValue(metersPerSecond: value) : nil
    }
    let currentSpeed = displayedSpeed.map(String.init) ?? "–"
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
      ? (unlimited
          ? "unrestricted"
          : "\(displayedLimit!) \(unitPolicy.spokenSpeedUnit)")
      : "unavailable"
    let speedDescription = displayedSpeed.map {
      "\($0) \(unitPolicy.spokenSpeedUnit)"
    }
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
    label.numberOfLines = 1
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.72
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

/// Compact route-wide timing above TEC in the left status column.
///
/// Dart owns the estimate and waypoint selection so the phone and car never
/// disagree. Native only formats the rider's units and local clock convention.
private final class CarPlayRouteProgressView: UIView {
  private let routeLabel = UILabel()
  private let waypointLabel = UILabel()
  private let timeFormatter = DateFormatter()

  init() {
    super.init(frame: .zero)
    isHidden = true
    isUserInteractionEnabled = false
    backgroundColor = CarPlayPalette.cardFill
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
    timeFormatter.setLocalizedDateFormatFromTemplate("j:mm")

    routeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    routeLabel.textColor = CarPlayPalette.cardTitle
    routeLabel.adjustsFontSizeToFitWidth = true
    routeLabel.minimumScaleFactor = 0.78
    waypointLabel.font = .systemFont(ofSize: 11, weight: .medium)
    waypointLabel.textColor = CarPlayPalette.cardLabel
    waypointLabel.adjustsFontSizeToFitWidth = true
    waypointLabel.minimumScaleFactor = 0.78
    for label in [routeLabel, waypointLabel] {
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 2
      label.lineBreakMode = .byWordWrapping
      addSubview(label)
    }
    NSLayoutConstraint.activate([
      routeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      routeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      routeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      waypointLabel.leadingAnchor.constraint(equalTo: routeLabel.leadingAnchor),
      waypointLabel.trailingAnchor.constraint(equalTo: routeLabel.trailingAnchor),
      waypointLabel.topAnchor.constraint(equalTo: routeLabel.bottomAnchor, constant: 4),
      waypointLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(_ progress: [String: Any]?, usesMiles: Bool) {
    guard
      let progress,
      let remaining = (progress["remainingDistanceMeters"] as? NSNumber)?.doubleValue
    else {
      isHidden = true
      return
    }
    isHidden = false
    let duration = durationLabel(progress["remainingSeconds"] as? NSNumber)
    let arrival = timeLabel(progress["arrivalTimeMillis"] as? NSNumber)
    routeLabel.text =
      "\(duration) · \(distanceLabel(remaining, usesMiles: usesMiles)) left · ETA \(arrival)"

    let waypointName = (progress["nextWaypointName"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let waypointDistance =
      (progress["nextWaypointDistanceMeters"] as? NSNumber)?.doubleValue
    if let waypointName, !waypointName.isEmpty, let waypointDistance {
      let waypointArrival = timeLabel(
        progress["nextWaypointArrivalTimeMillis"] as? NSNumber
      )
      waypointLabel.isHidden = false
      waypointLabel.text =
        "⚑ \(waypointName) · \(distanceLabel(waypointDistance, usesMiles: usesMiles)) · \(waypointArrival)"
    } else {
      waypointLabel.isHidden = true
      waypointLabel.text = nil
    }
    accessibilityLabel = [routeLabel.text, waypointLabel.text]
      .compactMap { $0 }
      .joined(separator: ". ")
  }

  private func durationLabel(_ seconds: NSNumber?) -> String {
    guard let seconds else { return "Time —" }
    let minutes = Int(ceil(seconds.doubleValue / 60))
    guard minutes >= 60 else { return "\(minutes) min" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
  }

  private func timeLabel(_ milliseconds: NSNumber?) -> String {
    guard let milliseconds else { return "—" }
    return timeFormatter.string(
      from: Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    )
  }

  private func distanceLabel(_ metres: Double, usesMiles: Bool) -> String {
    if usesMiles {
      let miles = metres / 1_609.344
      if miles < 0.1 { return "\(Int((metres * 1.093613).rounded())) yd" }
      return String(format: "%.1f mi", miles)
    }
    if metres < 1_000 { return "\(Int(metres.rounded())) m" }
    return String(format: "%.1f km", metres / 1_000)
  }
}

/// The time of day on the CarPlay map, drawn by the app (#452).
///
/// > Show the time on the map in landscape mode and on CarPlay but don't use
/// > Apple's built in widgets to do it.
///
/// A `DateFormatter` with the `j:mm` template rather than a hard "HH:mm": `j`
/// resolves to whichever of 12- or 24-hour the head unit's locale uses, so a car
/// set to a 12-hour clock does not suddenly show 13:00.
///
/// It ticks on the minute, not the second. A clock showing hours and minutes only
/// changes sixty times an hour, and this view is over a moving map.
final class CarPlayClockLabel: UIView {
  private let label = UILabel()
  private var tick: Timer?
  private let formatter = DateFormatter()

  /// Overridden by tests; production reads the device clock.
  var clock: () -> Date = Date.init

  override init(frame: CGRect) {
    super.init(frame: frame)
    formatter.setLocalizedDateFormatFromTemplate("j:mm")
    label.font = .systemFont(ofSize: 20, weight: .semibold)
    label.textColor = .white
    // The map behind this is any colour, so the glyphs carry their own shadow
    // rather than a panel — the same reasoning as the phone's map labels.
    label.layer.shadowColor = UIColor.black.cgColor
    label.layer.shadowOpacity = 0.8
    label.layer.shadowRadius = 4
    label.layer.shadowOffset = .zero
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.trailingAnchor.constraint(equalTo: trailingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    isUserInteractionEnabled = false
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  deinit { tick?.invalidate() }

  func apply(darkMap: Bool) {
    label.textColor = darkMap ? .white : .black
    label.layer.shadowColor = (darkMap ? UIColor.black : UIColor.white).cgColor
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Stopped when the view leaves the window, so a disconnected head unit does
    // not keep a timer alive.
    window == nil ? tick?.invalidate() : refresh()
  }

  private func refresh() {
    let now = clock()
    label.text = formatter.string(from: now)
    tick?.invalidate()
    guard window != nil else { return }
    // Rescheduled from the new time rather than repeating a fixed minute: a timer
    // that drifts eventually fires just before the boundary and shows the minute
    // that has already passed.
    let seconds = Calendar.current.component(.second, from: now)
    let delay = max(1, 60 - seconds)
    tick = Timer.scheduledTimer(
      withTimeInterval: TimeInterval(delay),
      repeats: false
    ) { [weak self] _ in
      self?.refresh()
    }
  }
}
