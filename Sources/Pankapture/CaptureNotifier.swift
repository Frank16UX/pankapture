import AppCore
import AppKit
import Capture
import UserNotifications

/// Native confirmation after a capture: "Screenshot saved" with Open and
/// Show in Finder actions, or "Copied to clipboard" when nothing was saved.
@MainActor
final class CaptureNotifier: NSObject {
    static let shared = CaptureNotifier()

    private enum ID {
        static let savedCategory = "capture.saved"
        static let copiedCategory = "capture.copied"
        static let recordingCategory = "recording.saved"
        static let open = "capture.open"
        static let reveal = "capture.reveal"
        static let edit = "recording.edit"
        static let fileKey = "fileURL"
    }

    private let center = UNUserNotificationCenter.current()

    /// Opens a recording in the video editor (clicking a "Recording saved"
    /// notification, or its Edit action).
    var onEditRecording: ((URL) -> Void)?

    private func edit(_ url: URL) {
        if let onEditRecording { onEditRecording(url) } else { NSWorkspace.shared.open(url) }
    }

    /// Call once at launch.
    func configure() {
        center.delegate = self
        let open = UNNotificationAction(identifier: ID.open, title: "Open", options: [.foreground])
        let reveal = UNNotificationAction(identifier: ID.reveal, title: "Show in Finder", options: [.foreground])
        let edit = UNNotificationAction(identifier: ID.edit, title: "Edit", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ID.savedCategory, actions: [open, reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: ID.recordingCategory, actions: [edit, reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: ID.copiedCategory, actions: [], intentIdentifiers: []),
        ])
    }

    /// Posts a confirmation. `savedURL` nil means the capture was only copied.
    func notify(savedURL: URL?, copied: Bool, image: CGImage?) {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.showNotifications) else { return }
        guard savedURL != nil || copied else { return }

        let content = UNMutableNotificationContent()
        if let savedURL {
            content.title = "Screenshot saved"
            content.body = copied
                ? "\(savedURL.lastPathComponent) · also copied to the clipboard"
                : savedURL.lastPathComponent
            content.categoryIdentifier = ID.savedCategory
            content.userInfo = [ID.fileKey: savedURL.path]
        } else {
            content.title = "Screenshot copied"
            content.body = "Paste it anywhere with ⌘V."
            content.categoryIdentifier = ID.copiedCategory
        }
        if let image, let attachment = Self.thumbnailAttachment(for: image) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard await authorize() else { return }
            do {
                try await center.add(request)
            } catch {
                Log.output.error("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Confirms a saved recording. Clicking it (or Edit) opens the video
    /// editor; GIFs get Open and Show in Finder.
    func notifyRecording(savedURL: URL) {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.showNotifications) else { return }
        let content = UNMutableNotificationContent()
        let isGIF = savedURL.pathExtension.lowercased() == "gif"
        content.title = isGIF ? "GIF saved" : "Recording saved"
        content.body = isGIF ? savedURL.lastPathComponent : "\(savedURL.lastPathComponent) · click to edit"
        content.categoryIdentifier = isGIF ? ID.savedCategory : ID.recordingCategory
        content.userInfo = [ID.fileKey: savedURL.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard await authorize() else { return }
            try? await center.add(request)
        }
    }

    /// Confirms "Capture Text": nil means nothing was recognized.
    func notifyText(_ text: String?) {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.showNotifications) else { return }
        let content = UNMutableNotificationContent()
        if let text {
            let lines = text.split(separator: "\n").count
            content.title = lines == 1 ? "Copied 1 line of text" : "Copied \(lines) lines of text"
            content.body = String(text.prefix(160))
        } else {
            content.title = "No text found"
            content.body = "Try selecting a larger area or higher-contrast text."
        }
        content.categoryIdentifier = ID.copiedCategory
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            guard await authorize() else { return }
            try? await center.add(request)
        }
    }

    private func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    /// The system moves attachment files into its own store, so hand it a
    /// small temporary copy rather than the user's file.
    private static func thumbnailAttachment(for image: CGImage) -> UNNotificationAttachment? {
        let maxSide = 512.0
        let scale = min(1, maxSide / Double(max(image.width, image.height)))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let thumbnail = context.makeImage(),
              let url = try? ImageOutput.writeTemporary(thumbnail) else { return nil }
        return try? UNNotificationAttachment(identifier: "thumbnail", url: url)
    }
}

extension CaptureNotifier: UNUserNotificationCenterDelegate {
    /// Show the banner even though the app is technically active after a capture.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo[ID.fileKey] as? String else { return }
        let url = URL(fileURLWithPath: path)
        let action = response.actionIdentifier
        let isRecording = response.notification.request.content.categoryIdentifier == ID.recordingCategory
        await MainActor.run {
            switch action {
            case ID.reveal:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case ID.edit:
                CaptureNotifier.shared.edit(url)
            case UNNotificationDefaultActionIdentifier where isRecording:
                CaptureNotifier.shared.edit(url)
            case ID.open, UNNotificationDefaultActionIdentifier:
                NSWorkspace.shared.open(url)
            default:
                break
            }
        }
    }
}
