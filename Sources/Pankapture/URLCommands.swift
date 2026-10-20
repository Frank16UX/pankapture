import AppCore
import Foundation

/// `pankapture://` URLs, for launchers, automation, and scripted QA:
///
///     pankapture://capture/area[?rect=x,y,w,h]   area capture, optional preselection (display-local points)
///     pankapture://capture/previous              previous area
///     pankapture://capture/fullscreen
///
/// Any web page can open a URL like these, so only commands that need the user
/// to finish them (the interactive overlay) run by default. Commands that would
/// capture without further interaction require the opt-in
/// `PreferenceKey.allowsURLAutomation` setting (off by default).
@MainActor
enum URLCommands {
    static func handle(_ url: URL, coordinator: CaptureCoordinator) {
        guard url.scheme == "pankapture" else { return }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).joined(separator: "/")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        Log.app.info("URL command: \(path, privacy: .public)")

        switch path {
        case "capture/area":
            let rect = query.first { $0.name == "rect" }?.value.flatMap(parseRect)
            Task { await coordinator.captureArea(preselect: rect) }
        case "capture/previous":
            coordinator.perform(.capturePreviousArea)
        case "capture/fullscreen":
            guard UserDefaults.standard.bool(forKey: PreferenceKey.allowsURLAutomation) else {
                Log.app.notice("Ignored \(path, privacy: .public): URL automation is off")
                return
            }
            coordinator.perform(.captureFullscreen)
        default:
            Log.app.notice("Unknown URL command \(path, privacy: .public)")
        }
    }

    private static func parseRect(_ value: String) -> CGRect? {
        let numbers = value.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}
