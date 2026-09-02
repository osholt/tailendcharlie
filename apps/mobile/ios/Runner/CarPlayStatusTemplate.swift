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
    onLeave: @escaping () -> Void = {}
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

    if !listsLimited, let rideStart = snapshot["rideStart"] as? [String: Any] {
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

    if !listsLimited, let guidance = snapshot["guidanceTitle"] as? String {
      items.append(
        CPListItem(
          text: guidance,
          detailText: snapshot["guidanceDetail"] as? String
        )
      )
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
      items.append(CPListItem(text: "Group", detailText: groupStatus))
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

    template.updateSections([CPListSection(items: items)])
  }
}
