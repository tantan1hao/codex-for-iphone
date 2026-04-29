import SwiftUI

@main
struct CodexMobileHelperApp: App {
    @StateObject private var controller = HelperController()

    var body: some Scene {
        MenuBarExtra("Codex Mobile", systemImage: "iphone.gen3.radiowaves.left.and.right") {
            HelperMenuView()
                .environmentObject(controller)
                .frame(width: 380)
        }
        .menuBarExtraStyle(.window)

        Settings {
            HelperSettingsView()
                .environmentObject(controller)
                .frame(width: 520, height: 280)
        }
    }
}

