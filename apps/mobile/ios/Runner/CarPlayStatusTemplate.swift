import CarPlay
import UIKit

/// Builds and updates the glanceable CarPlay status list from the same bounded
/// projected snapshot used by Android Auto.
enum CarPlayStatusTemplate {
  static func makeTemplate() -> CPListTemplate {
    let template = CPListTemplate(title: "Tail End Charlie", sections: [])
    template.trailingNavigationBarButtons = [emergencyButton()]
    return template
  }

  static func apply(snapshot: [String: Any], to template: CPListTemplate) {
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

    if let rideStart = snapshot["rideStart"] as? [String: Any] {
      let enabled = (rideStart["enabled"] as? NSNumber)?.boolValue ?? false
      items.append(
        CPListItem(
          text: enabled ? "Ready to start" : "Finish setup on iPhone",
          detailText: enabled
            ? "Use Start on the map"
            : rideStart["unavailableReason"] as? String
        )
      )
    }

    if let guidance = snapshot["guidanceTitle"] as? String {
      items.append(
        CPListItem(
          text: guidance,
          detailText: snapshot["guidanceDetail"] as? String
        )
      )
    }

    if
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

    if let markerStatus = snapshot["markerStatus"] as? String {
      items.append(CPListItem(text: "Marker", detailText: markerStatus))
    }

    if let groupStatus = snapshot["groupStatus"] as? String {
      items.append(CPListItem(text: "Group", detailText: groupStatus))
    }

    if let riders = snapshot["riders"] as? [[String: Any]] {
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

    template.updateSections([CPListSection(items: items)])
  }

  private static func emergencyButton() -> CPBarButton {
    CPBarButton(title: "SOS") { _ in
      (UIApplication.shared.delegate as? AppDelegate)?.triggerCarPlayEmergency()
    }
  }
}
