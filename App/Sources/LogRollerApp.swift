import AppKit
import SwiftUI

final class LogRollerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

@main
struct LogRollerApp: App {
    @NSApplicationDelegateAdaptor(LogRollerApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("LogRoller") {
            MainWindowView(model: model)
                .background(WindowCloseInterceptor(model: model))
                .task {
                    await model.startIfNeeded()
                }
        }
        .defaultSize(width: 1100, height: 700)
    }
}
