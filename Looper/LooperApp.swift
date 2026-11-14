import AppKit
import LooperCore
import SwiftUI

@main
struct LooperApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = LooperModel()
    @State private var preview = PreviewModel()

    var body: some Scene {
        Window("Looper", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        // Opens at a standard size; can be resized down to the content's minimum.
        .defaultSize(width: Layout.width, height: Layout.height)
        .windowResizability(.contentMinSize)

        // Plays the layered output before exporting (opened from the main window).
        Window("Preview", id: "preview") {
            PreviewView()
                .environment(model)
                .environment(preview)
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
    }
}

/// Asks before quitting in the middle of an export, and quits when the window closes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LooperModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isExporting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit and cancel the export?"
        alert.informativeText = "The partly written video will be deleted."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.cancelExport()
        // Give the export a moment to delete its partial file before the process exits.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
