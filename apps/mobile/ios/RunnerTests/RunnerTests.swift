import Flutter
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

  private func carPlayNavigationSnapshot(
    sourceID: String,
    sequence: Int,
    generatedAtMillis: Int64 = 1_000
  ) -> [String: Any] {
    [
      "carplayNavigation": [
        "schemaVersion": 2,
        "sourceId": sourceID,
        "sequence": sequence,
        "generatedAtMillis": generatedAtMillis,
        "rideLifecycle": ["phase": "activeRide"],
        "navigationLifecycle": ["phase": "navigating"],
        "trip": [
          "id": "france-route",
          "routeChoiceId": "france-route:primary",
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
