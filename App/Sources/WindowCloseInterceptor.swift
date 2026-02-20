import AppKit
import SwiftUI

struct WindowCloseInterceptor: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        guard let window = nsView.window else {
            return
        }
        context.coordinator.install(on: window)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var model: AppModel
        weak var previousDelegate: (any NSWindowDelegate)?
        weak var window: NSWindow?

        init(model: AppModel) {
            self.model = model
        }

        func install(on window: NSWindow) {
            guard self.window !== window else {
                return
            }

            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if !model.serverStatus.isRunning || model.skipCloseWarning {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Close window and keep LogRoller running?"
            alert.informativeText = "The HTTPS ingest server will remain active. Use Command-Q or Quit LogRoller from the menu to stop it."
            alert.addButton(withTitle: "Close Window")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true

            let result = alert.runModal()
            if alert.suppressionButton?.state == .on {
                model.skipCloseWarning = true
            }

            if result == .alertFirstButtonReturn {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }

            return false
        }
    }
}
