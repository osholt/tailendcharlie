import CarPlay
import UIKit

/// `didConnect interfaceController:` (no `window:` parameter) is the
/// template-only connect method - CPListTemplate's chrome is fully rendered
/// by CarPlayTemplateUIHost, so unlike CPMapTemplate this needs no custom
/// content view controller of our own.
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    let template = CarPlayStatusTemplate.makeTemplate()
    interfaceController.setRootTemplate(template, animated: true, completion: nil)
    (UIApplication.shared.delegate as? AppDelegate)?.carPlayDidConnect(template)
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    (UIApplication.shared.delegate as? AppDelegate)?.carPlayDidDisconnect()
  }
}
