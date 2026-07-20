import CarPlay
import UIKit

/// Builds and updates the CarPlay status list: one row per rider (name,
/// role, off-route indicator), a row for the current highest-priority
/// alert/hazard if any, and an SOS bar button. Driven by the same snapshot
/// shape `CarPlayBridge` publishes on the Dart side.
enum CarPlayStatusTemplate {
  static func makeTemplate() -> CPListTemplate {
    let template = CPListTemplate(title: "Tail End Charlie", sections: [])
    template.trailingNavigationBarButtons = [emergencyButton()]
    return template
  }

  static func apply(snapshot: [String: Any], to template: CPListTemplate) {
    var items: [CPListItem] = []

    if
      let alert = snapshot["alert"] as? [String: Any],
      let message = alert["message"] as? String
    {
      items.append(CPListItem(text: "Alert", detailText: message))
    }

    if let riders = snapshot["riders"] as? [[String: Any]] {
      for rider in riders {
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
