import AppKit
import LooperCore
import SwiftUI
import UserNotifications

/// Feedback for long exports that happen while you're doing something else: progress
/// on the Dock icon, and a notification when the export ends if Looper isn't in front.
struct ExportFeedback: ViewModifier {
    @Environment(LooperModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onChange(of: model.progress?.fractionCompleted) { _, fraction in
                NSApp.dockTile.badgeLabel = model.isExporting ? fraction.map(Format.percent) : nil
            }
            .onChange(of: model.phase) { _, phase in
                switch phase {
                case .exporting:
                    // The async form: a completion closure written here would inherit the
                    // view's main-actor isolation, and the system calls it on a background
                    // queue, which Swift 6 traps on (crashed after the permission prompt).
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                case .finished(let url):
                    NSApp.dockTile.badgeLabel = nil
                    notify(title: "Export finished", body: url.lastPathComponent)
                case .failed(let message):
                    NSApp.dockTile.badgeLabel = nil
                    notify(title: "Export failed", body: message)
                case .idle, .cancelled:
                    NSApp.dockTile.badgeLabel = nil
                }
            }
    }

    private func notify(title: String, body: String) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
