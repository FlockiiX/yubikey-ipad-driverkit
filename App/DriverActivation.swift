import Foundation

#if os(macOS)
import SystemExtensions

/// Activates the embedded driver extension through the System Extensions framework.
final class DriverActivation: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var message = "macOS: activate the embedded driver extension, then connect the YubiKey."

    func enableDriver() {
        guard let appID = Bundle.main.bundleIdentifier else {
            message = "The app's bundle identifier is missing."
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: appID + ".driver",
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        message = "Driver activation requested."
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        message = "Approve the driver extension in System Settings > Privacy & Security."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        message = result == .completed
            ? "Driver activated. Disconnect and reconnect the YubiKey."
            : "Driver activation completes after a restart."
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        message = "Driver activation failed: \(error.localizedDescription)"
    }
}
#else
import UIKit

/// iPadOS discovers the embedded driver itself; the user enables it in Settings.
final class DriverActivation: ObservableObject {
    @Published private(set) var message = "iPadOS: enable the driver in Settings > Privacy & Security > Drivers, then reconnect the YubiKey."

    func enableDriver() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
