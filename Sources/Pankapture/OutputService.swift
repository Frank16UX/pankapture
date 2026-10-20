import AppCore
import AppKit
import Capture
import UniformTypeIdentifiers

/// App-level output actions for finished captures (OUT-1…OUT-3).
@MainActor
enum OutputService {
    static func copy(_ image: CGImage) {
        do {
            try ImageOutput.copyToClipboard(image)
        } catch {
            Log.output.error("Copy failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Saves into the configured folder; returns the file URL.
    @discardableResult
    static func save(_ image: CGImage) -> URL? {
        do {
            return try ImageOutput.write(image, to: Preferences.saveDirectory(), format: Preferences.imageFormat())
        } catch {
            Log.output.error("Save failed: \(error.localizedDescription, privacy: .public)")
            presentError("Couldn't save the capture", error)
            return nil
        }
    }

    /// Asks where to save (⇧⌘S); returns the chosen URL if saved.
    static func saveAs(_ image: CGImage) -> URL? {
        let format = Preferences.imageFormat()
        let panel = NSSavePanel()
        panel.title = "Save Capture"
        panel.nameFieldStringValue = CaptureFileNamer().baseName(for: .now) + "." + format.fileExtension
        panel.directoryURL = Preferences.saveDirectory()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let chosen: ImageFormat = switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic": .heic
        default: .png
        }
        do {
            try ImageOutput.encode(image, as: chosen).write(to: url, options: .atomic)
            return url
        } catch {
            presentError("Couldn't save the capture", error)
            return nil
        }
    }

    /// Standard print dialog (OUT-3), image scaled to fit the page.
    static func print(_ image: CGImage, scale: CGFloat) {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: size))
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.imageScaling = .scaleProportionallyDown

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = size.width > size.height ? .landscape : .portrait

        NSApp.activate()
        let operation = NSPrintOperation(view: imageView, printInfo: info)
        operation.jobTitle = CaptureFileNamer().baseName(for: .now)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    static func playCaptureSound() {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.playSounds) else { return }
        captureSound?.play()
    }

    /// The system's own screenshot sound, so captures sound familiar.
    private static let captureSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    static func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
