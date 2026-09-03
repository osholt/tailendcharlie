import CarPlay
import UIKit

/// Builds and updates the glanceable CarPlay status list from the same bounded
/// projected snapshot used by Android Auto.
enum CarPlayStatusTemplate {
  static func makeTemplate(
    onEmergency: @escaping () -> Void = {
      (UIApplication.shared.delegate as? AppDelegate)?.triggerCarPlayEmergency()
    }
  ) -> CPListTemplate {
    let template = CPListTemplate(title: "Tail End Charlie", sections: [])
    template.trailingNavigationBarButtons = [
      CPBarButton(title: "SOS") { _ in onEmergency() }
    ]
    return template
  }

  static func apply(
    snapshot: [String: Any],
    to template: CPListTemplate,
    listsLimited: Bool = false,
    onLeave: @escaping () -> Void = {},
    onShowGroupOverview: @escaping () -> Void = {}
  ) {
    var items: [CPListItem] = []

    let routeName = (snapshot["routeName"] as? String).flatMap {
      $0.isEmpty ? nil : $0
    }
    let rideState = snapshot["rideState"] as? String
    items.append(
      CPListItem(
        text: routeName ?? "No route selected",
        detailText: rideState
      )
    )

    if let journey = snapshot["journeyProgress"] as? [String: Any] {
      let unitPolicy = unitPolicy(snapshot)
      if let detail = journeyDetail(journey, unitPolicy: unitPolicy) {
        items.append(CPListItem(text: "Journey", detailText: detail))
      }
      if
        let waypoint = nonEmpty(journey["nextWaypointName"]),
        let detail = waypointDetail(journey, unitPolicy: unitPolicy)
      {
        items.append(CPListItem(text: waypoint, detailText: detail))
      }
    }

    if !listsLimited, let rideStart = snapshot["rideStart"] as? [String: Any] {
      let enabled = (rideStart["enabled"] as? NSNumber)?.boolValue ?? false
      items.append(
        CPListItem(
          text: enabled ? "Ready to start" : "Ride not ready",
          detailText: enabled
            ? "Use Start on the map"
            : rideStart["unavailableReason"] as? String
        )
      )
    }

    if !listsLimited {
      let navigation = snapshot["carplayNavigation"] as? [String: Any]
      let current = navigation?["currentManeuver"] as? [String: Any]
      let currentVariants = current?["instructionVariants"] as? [String]
      let currentRoadNames = current?["roadNameVariants"] as? [String]
      let guidance = nonEmpty(snapshot["guidanceTitle"])
        ?? currentVariants?.first.flatMap(nonEmpty)
      let guidanceDetail = nonEmpty(snapshot["guidanceDetail"])
        ?? currentRoadNames?.first.flatMap(nonEmpty)
      if let guidance {
        items.append(
          CPListItem(text: "Now · \(guidance)", detailText: guidanceDetail)
        )
      }

      if
        let following = navigation?["followingManeuver"] as? [String: Any],
        let variants = following["instructionVariants"] as? [String],
        let instruction = variants.first.flatMap(nonEmpty)
      {
        let roadNames = following["roadNameVariants"] as? [String]
        items.append(
          CPListItem(
            text: "Then · \(instruction)",
            detailText: roadNames?.first.flatMap(nonEmpty)
          )
        )
      }
    }

    if
      !listsLimited,
      let alert = snapshot["alert"] as? [String: Any],
      let message = alert["message"] as? String
    {
      items.append(CPListItem(text: "Alert", detailText: message))
    }

    // The back-marker, above the marker and group rows because it is the one
    // fact this app exists to keep. Always present, including when nobody holds
    // the role: a missing row reads as "fine", and "nobody is watching the
    // back" is the opposite of fine. Dart has already decided the wording for
    // all four availability states.
    if let tec = snapshot["tec"] as? [String: Any] {
      items.append(
        CPListItem(
          text: "Tail End Charlie",
          detailText: tec["detail"] as? String
        )
      )
    }

    if !listsLimited, let markerStatus = snapshot["markerStatus"] as? String {
      items.append(CPListItem(text: "Marker", detailText: markerStatus))
    }

    if let groupStatus = snapshot["groupStatus"] as? String {
      let overview = CPListItem(
        text: "Show all riders on map",
        detailText: groupStatus
      )
      overview.handler = { _, completion in
        onShowGroupOverview()
        completion()
      }
      items.append(overview)
    }

    if !listsLimited, let speed = snapshot["speed"] as? [String: Any] {
      items.append(
        CPListItem(
          text: "Speed",
          detailText: speedDetail(speed, unitPolicy: unitPolicy(snapshot))
        )
      )
    }

    if snapshot["surfaceMode"] as? String == "activeRide" {
      let leave = CPListItem(
        text: "Leave ride",
        detailText: "Stop sharing and return to the home map"
      )
      leave.handler = { _, completion in
        onLeave()
        completion()
      }
      items.append(leave)
    }

    if !listsLimited, let riders = snapshot["riders"] as? [[String: Any]] {
      for rider in riders.prefix(4) {
        guard let label = rider["label"] as? String else { continue }
        let isLocal = (rider["isLocal"] as? NSNumber)?.boolValue ?? false
        let role = rider["role"] as? String ?? ""
        let needsAttention = (rider["needsAttention"] as? NSNumber)?.boolValue ?? false
        var detail = role
        if needsAttention {
          detail = detail.isEmpty ? "Off route" : "\(detail) · Off route"
        }
        items.append(
          CPListItem(
            text: isLocal ? "\(label) (you)" : label,
            detailText: detail.isEmpty ? nil : detail
          )
        )
      }
    }

    if items.isEmpty {
      items = [CPListItem(text: "Tail End Charlie", detailText: "Waiting for ride data…")]
    }

    template.updateSections([
      CPListSection(items: Array(items.prefix(CPListTemplate.maximumItemCount)))
    ])
  }

  private static func unitPolicy(_ snapshot: [String: Any]) -> CarPlayUnitPolicy {
    CarPlayUnitPolicy(
      distanceUnit: snapshot["distanceUnit"] as? String,
      localeIdentifier: snapshot["localeIdentifier"] as? String
    )
  }

  private static func journeyDetail(
    _ journey: [String: Any],
    unitPolicy: CarPlayUnitPolicy
  ) -> String? {
    guard
      let distance = (journey["remainingDistanceMeters"] as? NSNumber)?.doubleValue,
      distance.isFinite,
      distance >= 0
    else { return nil }
    var parts = ["\(unitPolicy.distanceLabel(meters: distance)) left"]
    if
      let seconds = (journey["remainingSeconds"] as? NSNumber)?.doubleValue,
      seconds.isFinite,
      seconds >= 0
    {
      parts.append(durationLabel(seconds: seconds))
    }
    if let arrival = dateLabel(journey["arrivalTimeMillis"]) {
      parts.append("ETA \(arrival)")
    }
    return parts.joined(separator: " · ")
  }

  private static func waypointDetail(
    _ journey: [String: Any],
    unitPolicy: CarPlayUnitPolicy
  ) -> String? {
    var parts: [String] = []
    if
      let distance = (journey["nextWaypointDistanceMeters"] as? NSNumber)?.doubleValue,
      distance.isFinite,
      distance >= 0
    {
      parts.append(unitPolicy.distanceLabel(meters: distance))
    }
    if let arrival = dateLabel(journey["nextWaypointArrivalTimeMillis"]) {
      parts.append("ETA \(arrival)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func speedDetail(
    _ speed: [String: Any],
    unitPolicy: CarPlayUnitPolicy
  ) -> String {
    let unit = unitPolicy.usesMiles ? "mph" : "km/h"
    let ageing = (speed["isAgeing"] as? NSNumber)?.boolValue ?? false
    let rawCurrent = (speed["metresPerSecond"] as? NSNumber)?.doubleValue
    let current = rawCurrent.flatMap {
      $0.isFinite && $0 >= 0 ? unitPolicy.speedValue(metersPerSecond: $0) : nil
    }
    let currentText = ageing || current == nil ? "GPS speed unavailable" : "\(current!) \(unit)"

    let status = speed["limitStatus"] as? String
    let unlimited = (speed["limitUnlimited"] as? NSNumber)?.boolValue ?? false
    let milesPerHour = (speed["limitMilesPerHour"] as? NSNumber)?.intValue
    let limitText: String
    if status == "checking" {
      limitText = "checking mapped limit"
    } else if status == "known", unlimited {
      limitText = "unrestricted road"
    } else if status == "known", let milesPerHour {
      let displayed = unitPolicy.usesMiles
        ? milesPerHour
        : Int((Double(milesPerHour) * 1.609_344).rounded())
      limitText = "mapped limit \(displayed) \(unit)"
    } else {
      limitText = "mapped limit unavailable"
    }
    return "\(currentText) · \(limitText)"
  }

  private static func durationLabel(seconds: Double) -> String {
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
  }

  private static func dateLabel(_ raw: Any?) -> String? {
    guard let milliseconds = (raw as? NSNumber)?.doubleValue else { return nil }
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
  }

  private static func nonEmpty(_ raw: Any?) -> String? {
    guard let text = raw as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
