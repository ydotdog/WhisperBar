import SwiftUI

@main
struct WhisperBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("WhisperBar", systemImage: "mic.fill") {
            MenuBarView()
                .environmentObject(appDelegate.engine)
                .environmentObject(appDelegate.vocabulary)
        }
        .menuBarExtraStyle(.menu)
    }
}
