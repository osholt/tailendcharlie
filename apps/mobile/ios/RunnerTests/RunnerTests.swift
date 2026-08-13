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

}
