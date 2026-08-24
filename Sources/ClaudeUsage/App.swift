import ServiceManagement
import SwiftUI

struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(store)
        } label: {
            Image(systemName: "sparkle")
            Text(store.menuBarText)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Wraps the login-item registration so the menu can toggle it.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Claude Usage: login item toggle failed — \(error.localizedDescription)")
        }
    }
}
