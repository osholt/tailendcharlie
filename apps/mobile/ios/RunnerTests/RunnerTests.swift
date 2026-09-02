import CarPlay
import Flutter
import MapLibre
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testCarPlayRootBecomesReadyOnlyForCurrentSuccessfulConnection() {
    var lifecycle = CarPlaySceneLifecycle()
    let first = lifecycle.beginConnection()
    let second = lifecycle.beginConnection()

    XCTAssertFalse(
      lifecycle.completeRootPresentation(generation: first, succeeded: true),
      "a stale root completion must not activate the replacement scene"
    )
    XCTAssertFalse(lifecycle.rootReady)
    XCTAssertFalse(
      lifecycle.completeRootPresentation(generation: second, succeeded: false),
      "a failed presentation must remain inert instead of driving templates"
    )
    XCTAssertFalse(lifecycle.rootReady)
    XCTAssertTrue(
      lifecycle.completeRootPresentation(generation: second, succeeded: true)
    )
    XCTAssertTrue(lifecycle.rootReady)
  }

  func testCarPlayDisconnectInvalidatesDelayedRootCompletion() {
    var lifecycle = CarPlaySceneLifecycle()
    let generation = lifecycle.beginConnection()
    lifecycle.disconnect()

    XCTAssertFalse(
      lifecycle.completeRootPresentation(generation: generation, succeeded: true)
    )
    XCTAssertFalse(lifecycle.rootReady)
  }

  func testCarPlayDrivingRestrictionsHideOnlyUnsafeDetail() {
    let unrestricted = CarPlayInteractionPolicy(limitedUserInterfaces: [])
    XCTAssertTrue(unrestricted.allowsDestinationSearch)
    XCTAssertTrue(unrestricted.allowsRiderRows)

    let keyboardLimited = CarPlayInteractionPolicy(
      limitedUserInterfaces: [.keyboard]
    )
    XCTAssertFalse(keyboardLimited.allowsDestinationSearch)
    XCTAssertTrue(keyboardLimited.allowsRiderRows)

    let listsLimited = CarPlayInteractionPolicy(
      limitedUserInterfaces: [.lists]
    )
    XCTAssertFalse(listsLimited.allowsDestinationSearch)
    XCTAssertFalse(listsLimited.allowsRiderRows)
  }

  func testCarPlaySafeAreaUsesEveryHostInset() {
    let safeArea = CarPlayMapSafeArea(
      viewBounds: CGRect(x: 0, y: 0, width: 800, height: 480),
      safeFrame: CGRect(x: 80, y: 30, width: 640, height: 400)
    )

    XCTAssertEqual(safeArea.contentInsets.top, 30)
    XCTAssertEqual(safeArea.contentInsets.left, 80)
    XCTAssertEqual(safeArea.contentInsets.bottom, 50)
    XCTAssertEqual(safeArea.contentInsets.right, 80)
  }

  func testCarPlayUnitsPreferExplicitChoiceThenLocale() {
    let france = CarPlayUnitPolicy(
      distanceUnit: nil,
      localeIdentifier: "fr-FR"
    )
    XCTAssertFalse(france.usesMiles)
    XCTAssertEqual(france.speedValue(metersPerSecond: 10), 36)
    XCTAssertEqual(france.spokenSpeedUnit, "kilometres per hour")

    let explicitUKMetric = CarPlayUnitPolicy(
      distanceUnit: "kilometres",
      localeIdentifier: "en-GB"
    )
    XCTAssertFalse(explicitUKMetric.usesMiles)

    let explicitFrenchMiles = CarPlayUnitPolicy(
      distanceUnit: "miles",
      localeIdentifier: "fr-FR"
    )
    XCTAssertTrue(explicitFrenchMiles.usesMiles)
    XCTAssertEqual(explicitFrenchMiles.speedValue(metersPerSecond: 10), 22)
  }

  func testCarPlayListRestrictionKeepsOnlyEssentialRideRows() {
    let snapshot: [String: Any] = [
      "routeName": "D 980 to Salers",
      "rideState": "activeRide",
      "rideStart": ["enabled": true],
      "guidanceTitle": "At the fork, keep right",
      "alert": ["message": "Debris", "severity": "warning"],
      "tec": ["detail": "Charlie · 250 m behind"],
      "markerStatus": "Next marker in 2 km",
      "groupStatus": "5 riders connected",
      "surfaceMode": "activeRide",
      "riders": [["label": "Alice", "role": "leader"]],
    ]
    let template = CarPlayStatusTemplate.makeTemplate()

    CarPlayStatusTemplate.apply(
      snapshot: snapshot,
      to: template,
      listsLimited: true
    )

    let titles = template.sections.first?.items.compactMap {
      ($0 as? CPListItem)?.text
    }
    XCTAssertEqual(
      titles,
      ["D 980 to Salers", "Tail End Charlie", "Group", "Leave ride"]
    )
  }

  func testCarPlayBaseViewContainsOnlyTheMap() {
    let controller = CarPlayNavigationViewController()
    controller.loadViewIfNeeded()
    controller.viewWillAppear(false)

    XCTAssertEqual(controller.view.subviews.count, 1)
    XCTAssertTrue(controller.view.subviews.first is MLNMapView)
  }

  func testCarPlayCommandCompletionResolvesExactlyOnce() {
    let completed = expectation(description: "command completed")
    completed.assertForOverFulfill = true
    var results: [(Bool, String?)] = []
    let command = CarPlayCommandCompletion { success, error in
      results.append((success, error))
      completed.fulfill()
    }

    command.resolve(success: true, error: nil)
    command.resolve(success: false, error: "late timeout")

    wait(for: [completed], timeout: 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    XCTAssertEqual(results.count, 1)
    XCTAssertTrue(results[0].0)
    XCTAssertNil(results[0].1)
  }

  func testCarPlayV2ProjectionDecodesTypedFrenchRoundabout() throws {
    let projection = try XCTUnwrap(
      CarPlayNavigationProjectionV2(
        snapshot: carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 4)
      )
    )

    XCTAssertEqual(projection.ridePhase, "activeRide")
    XCTAssertEqual(projection.navigationPhase, "navigating")
    XCTAssertEqual(projection.trip?.routeChoiceID, "france-route:primary")
    XCTAssertEqual(projection.trip?.trafficSide, "right")
    XCTAssertEqual(projection.units.distance, "kilometres")
    XCTAssertEqual(projection.units.speed, "kilometresPerHour")
    XCTAssertEqual(projection.localeIdentifier, "fr-FR")
    XCTAssertEqual(projection.currentManeuver?.kind, "roundabout")
    XCTAssertEqual(projection.currentManeuver?.direction, "right")
    XCTAssertEqual(projection.currentManeuver?.exitNumber, 3)
    XCTAssertEqual(projection.currentManeuver?.lanes.first?.isValid, true)
  }

  func testCarPlayV2ProjectionRejectsMissingAndMalformedMessages() {
    XCTAssertNil(CarPlayNavigationProjectionV2(snapshot: [:]))

    var snapshot = carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 1)
    var navigation = snapshot["carplayNavigation"] as! [String: Any]
    var maneuver = navigation["currentManeuver"] as! [String: Any]
    maneuver["position"] = ["latitude": 145.0, "longitude": 2.7]
    navigation["currentManeuver"] = maneuver
    snapshot["carplayNavigation"] = navigation

    XCTAssertNil(CarPlayNavigationProjectionV2(snapshot: snapshot))
  }

  func testCarPlayV2ProjectionStoreRejectsReplayAndOutOfOrderMessages() {
    var store = CarPlayNavigationProjectionStore()

    XCTAssertTrue(
      store.accept(
        snapshot: carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 2)
      )
    )
    XCTAssertFalse(
      store.accept(
        snapshot: carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 2)
      )
    )
    XCTAssertFalse(
      store.accept(
        snapshot: carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 1)
      )
    )
    XCTAssertEqual(store.latest?.sequence, 2)
  }

  func testCarPlayV2ProjectionStoreRejectsStalePreviousSource() {
    var store = CarPlayNavigationProjectionStore()

    XCTAssertTrue(
      store.accept(
        snapshot: carPlayNavigationSnapshot(
          sourceID: "dart-new",
          sequence: 1,
          generatedAtMillis: 2_000
        )
      )
    )
    XCTAssertFalse(
      store.accept(
        snapshot: carPlayNavigationSnapshot(
          sourceID: "dart-old",
          sequence: 99,
          generatedAtMillis: 1_999
        )
      )
    )
    XCTAssertEqual(store.latest?.sourceID, "dart-new")
  }

  func testCarPlayNavigationLifecycleIsIdempotent() throws {
    var coordinator = CarPlayNavigationCoordinator()
    let navigating = try XCTUnwrap(
      CarPlayNavigationProjectionV2(
        snapshot: carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 1)
      )
    )

    XCTAssertEqual(
      coordinator.apply(navigating),
      .start(routeID: "france-route", paused: false)
    )
    XCTAssertEqual(coordinator.apply(navigating), .update)

    let paused = try XCTUnwrap(
      CarPlayNavigationProjectionV2(
        snapshot: carPlayNavigationSnapshot(
          sourceID: "dart-1",
          sequence: 2,
          navigationPhase: "paused"
        )
      )
    )
    XCTAssertEqual(coordinator.apply(paused), .pause)
    XCTAssertEqual(coordinator.apply(paused), .none)
    XCTAssertEqual(coordinator.apply(navigating), .resume)
  }

  func testCarPlayNavigationLifecycleReroutesArrivesAndCancelsOnce() throws {
    var coordinator = CarPlayNavigationCoordinator()
    let first = try XCTUnwrap(
      CarPlayNavigationProjectionV2(
        snapshot: carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 1)
      )
    )
    _ = coordinator.apply(first)
    let reroute = try XCTUnwrap(
      CarPlayNavigationProjectionV2(
        snapshot: carPlayNavigationSnapshot(
          sourceID: "dart-1",
          sequence: 2,
          routeID: "rerouted-france-route"
        )
      )
    )
    XCTAssertEqual(
      coordinator.apply(reroute),
      .reroute(from: "france-route", to: "rerouted-france-route")
    )
    coordinator.completeReroute(routeID: "rerouted-france-route")

    let ended = try XCTUnwrap(
      CarPlayNavigationProjectionV2(
        snapshot: carPlayNavigationSnapshot(
          sourceID: "dart-1",
          sequence: 3,
          navigationPhase: "ended",
          routeID: "rerouted-france-route"
        )
      )
    )
    XCTAssertEqual(coordinator.apply(ended), .finish)
    XCTAssertEqual(coordinator.apply(ended), .none)
    XCTAssertEqual(coordinator.cancel(), .cancel)
    XCTAssertEqual(coordinator.cancel(), .none)
  }

  func testCarPlayVehicleCancellationSuppressesSameRouteReplay() throws {
    var coordinator = CarPlayNavigationCoordinator()
    let navigating = try XCTUnwrap(
      CarPlayNavigationProjectionV2(
        snapshot: carPlayNavigationSnapshot(sourceID: "dart-1", sequence: 1)
      )
    )
    _ = coordinator.apply(navigating)

    XCTAssertEqual(coordinator.cancel(), .cancel)
    XCTAssertEqual(coordinator.apply(navigating), .none)
    XCTAssertEqual(coordinator.phase, .cancelled("france-route"))
  }

  func testCarPlayRoutePreviewRejectsNoRoute() {
    XCTAssertNil(
      CarPlayRoutePreviewPayload(
        response: carPlayRoutePreviewResponse(choiceCount: 0)
      )
    )
  }

  func testCarPlayRoutePreviewAcceptsOneRouteAndCommitsItOnce() throws {
    let preview = try XCTUnwrap(
      CarPlayRoutePreviewPayload(
        response: carPlayRoutePreviewResponse(choiceCount: 1)
      )
    )
    var coordinator = CarPlayRoutePreviewCoordinator()
    let request = coordinator.beginRequest()

    XCTAssertTrue(coordinator.accept(preview, generation: request.generation))
    XCTAssertEqual(coordinator.selectedChoiceID, "route-choice-1")
    XCTAssertEqual(
      coordinator.beginCommit(
        previewID: "preview-1",
        choiceID: "route-choice-1"
      )?.choice.routeID,
      "route-1"
    )
    XCTAssertNil(
      coordinator.beginCommit(
        previewID: "preview-1",
        choiceID: "route-choice-1"
      ),
      "a repeated CarPlay start callback must not reach Dart twice"
    )
    coordinator.completeCommit(succeeded: true)
    XCTAssertEqual(coordinator.phase, .committed)
    XCTAssertNil(
      coordinator.preview,
      "committed preview state must not intercept End Directions"
    )
  }

  func testCarPlayRoutePreviewAcceptsAndSelectsThreeRoutes() throws {
    let preview = try XCTUnwrap(
      CarPlayRoutePreviewPayload(
        response: carPlayRoutePreviewResponse(choiceCount: 3)
      )
    )
    var coordinator = CarPlayRoutePreviewCoordinator()
    let request = coordinator.beginRequest()

    XCTAssertEqual(preview.choices.count, 3)
    XCTAssertTrue(coordinator.accept(preview, generation: request.generation))
    XCTAssertEqual(
      coordinator.select(choiceID: "route-choice-3")?.distanceMeters,
      30_000
    )
    XCTAssertEqual(coordinator.selectedChoiceID, "route-choice-3")
  }

  func testCarPlayRoutePreviewRejectsStalePlanningResult() throws {
    let preview = try XCTUnwrap(
      CarPlayRoutePreviewPayload(
        response: carPlayRoutePreviewResponse(choiceCount: 1)
      )
    )
    var coordinator = CarPlayRoutePreviewCoordinator()
    let staleRequest = coordinator.beginRequest()
    let currentRequest = coordinator.beginRequest()

    XCTAssertFalse(
      coordinator.accept(preview, generation: staleRequest.generation)
    )
    XCTAssertTrue(
      coordinator.accept(preview, generation: currentRequest.generation)
    )
  }

  func testCarPlayRoutePreviewCancellationDoesNotLeaveASelection() throws {
    let preview = try XCTUnwrap(
      CarPlayRoutePreviewPayload(
        response: carPlayRoutePreviewResponse(choiceCount: 1)
      )
    )
    var coordinator = CarPlayRoutePreviewCoordinator()
    let request = coordinator.beginRequest()
    XCTAssertTrue(coordinator.accept(preview, generation: request.generation))

    XCTAssertEqual(coordinator.cancel(), "preview-1")
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertNil(coordinator.preview)
    XCTAssertNil(
      coordinator.beginCommit(
        previewID: "preview-1",
        choiceID: "route-choice-1"
      )
    )
  }

  private func carPlayRoutePreviewResponse(choiceCount: Int) -> [String: Any] {
    [
      "preview": [
        "schemaVersion": 1,
        "id": "preview-1",
        "destinationLabel": "Puy Mary, France",
        "origin": ["latitude": 45.05, "longitude": 2.70],
        "destination": ["latitude": 45.06, "longitude": 2.72],
        "choices": (1 ... max(1, choiceCount)).prefix(choiceCount).map { index in
          [
            "id": "route-choice-\(index)",
            "routeId": "route-\(index)",
            "summaryVariants": ["Route \(index)"],
            "additionalInformationVariants": ["Motorcycle route"],
            "selectionSummaryVariants": ["Use route \(index)"],
            "distanceMeters": Double(index) * 10_000,
            "durationSeconds": Double(index) * 900,
            "routePoints": [
              ["latitude": 45.05, "longitude": 2.70],
              ["latitude": 45.06, "longitude": 2.72],
            ],
          ] as [String: Any]
        },
      ] as [String: Any],
      "error": NSNull(),
    ]
  }

  private func carPlayNavigationSnapshot(
    sourceID: String,
    sequence: Int,
    generatedAtMillis: Int64 = 1_000,
    navigationPhase: String = "navigating",
    routeID: String = "france-route"
  ) -> [String: Any] {
    [
      "carplayNavigation": [
        "schemaVersion": 2,
        "sourceId": sourceID,
        "sequence": sequence,
        "generatedAtMillis": generatedAtMillis,
        "rideLifecycle": ["phase": "activeRide"],
        "navigationLifecycle": ["phase": navigationPhase],
        "trip": [
          "id": routeID,
          "routeChoiceId": "\(routeID):primary",
          "name": "To Puy Mary",
          "trafficSide": "right",
        ],
        "currentManeuver": [
          "id": "roundabout|45.05200,2.71100|right|3",
          "kind": "roundabout",
          "direction": "right",
          "engineType": "roundabout",
          "engineModifier": "right",
          "instructionVariants": [
            "3rd exit, right", "At the roundabout take the 3rd exit, right",
          ],
          "roadNameVariants": ["Route de Salers · D 680", "D 680"],
          "position": ["latitude": 45.052, "longitude": 2.711],
          "exitNumber": 3,
          "trafficSide": "right",
          "distanceMeters": 400.0,
          "secondsRemaining": 20.0,
          "bearingBeforeDegrees": 12.0,
          "bearingAfterDegrees": 112.0,
          "departureBearingDegrees": 112.0,
          "stepCount": 2,
          "lanes": [
            ["indications": ["right"], "valid": true],
          ],
        ],
        "followingManeuver": NSNull(),
        "journey": NSNull(),
        "units": [
          "distance": "kilometres", "speed": "kilometresPerHour",
        ],
        "localeIdentifier": "fr-FR",
      ],
    ]
  }

}
