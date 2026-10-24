import SwiftUI
import UIKit

/// A UIKit app delegate used to control supported interface orientations.
///
/// SwiftUI alone is not always enough for strict orientation management,
/// so this delegate provides the system-level orientation mask.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The currently allowed orientation mask for the application.
    ///
    /// Default value:
    /// - `.landscape`
    static var orientationLock: UIInterfaceOrientationMask = .landscape

    /// Returns the orientation mask supported by the app.
    ///
    /// - Parameters:
    ///   - application: The shared application object.
    ///   - window: The window whose supported orientations are being requested.
    /// - Returns: The allowed interface orientation mask.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// A SwiftUI view modifier that applies a specific orientation lock.
struct OrientationLockViewModifier: ViewModifier {
    /// The desired interface orientation mask.
    let orientation: UIInterfaceOrientationMask

    /// Applies the orientation lock when the view appears.
    ///
    /// - Parameter content: The wrapped content view.
    /// - Returns: The modified view.
    func body(content: Content) -> some View {
        content
            .onAppear {
                AppDelegate.orientationLock = orientation
                UINavigationController.attemptRotationToDeviceOrientation()
            }
    }
}

extension View {
    /// Locks the view hierarchy to a specific interface orientation mask.
    ///
    /// - Parameter orientation: The desired orientation mask.
    /// - Returns: A modified view with orientation behavior applied.
    func lockOrientation(_ orientation: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockViewModifier(orientation: orientation))
    }
}
