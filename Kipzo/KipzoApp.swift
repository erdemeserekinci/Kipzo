import SwiftUI

/// The main entry point of the Kipzo application.
///
/// This app is intentionally locked to landscape orientation because the
/// robot control experience is designed around a fixed horizontal phone mount.
///
/// Responsibilities:
/// - Boot the SwiftUI app
/// - Attach the UIKit-backed app delegate
/// - Apply the landscape orientation lock to the root view
@main
struct KipzoApp: App {
    /// Bridges UIKit app lifecycle hooks into this SwiftUI app.
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .lockOrientation(.landscape)
        }
    }
}
