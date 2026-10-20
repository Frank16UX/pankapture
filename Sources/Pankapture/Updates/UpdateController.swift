import AppCore
import AppKit
import Observation
import Security

/// Checks GitHub Releases for a newer Pankapture and installs it (UP-1,
/// ADR-28): download the DMG, verify the app inside is signed by the same
/// identity as this one, swap the bundle after quitting, and relaunch.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, progress: Double)
        case installing(AvailableUpdate)
        /// Staged; installs as soon as the app quits (quitting was cancelled).
        case waitingToQuit(AvailableUpdate)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: PreferenceKey.updatesLastCheck) as? Date

    let currentVersion = SoftwareUpdate.currentVersion
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    /// Local `make app` builds check but don't replace themselves.
    let canInstall = SoftwareUpdate.isReleaseBuild

    /// Return `false` while installing would interrupt work (a recording).
    @ObservationIgnored var isSafeToQuit: () -> Bool = { true }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var task: Task<Void, Never>?

    var availableUpdate: AvailableUpdate? {
        if case let .available(update) = state { return update }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing, .waitingToQuit: true
        default: false
        }
    }

    private init() {}

    // MARK: Checking

    /// Hidden bundles an update leaves next to the app: the replaced version
    /// and any staged copy that never got installed.
    nonisolated static let leftoverPrefix = ".Pankapture-update-"

    /// Moves leftovers of a previous update to the Trash.
    private func cleanUpAfterUpdate() {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(Self.leftoverPrefix) && item.pathExtension == "app" {
            do {
                try FileManager.default.trashItem(at: item, resultingItemURL: nil)
                Log.updates.info("Moved \(item.lastPathComponent, privacy: .public) to the Trash")
            } catch {
                Log.updates.error("Couldn't remove \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Automatic checks: shortly after launch, then daily, when enabled.
    func start() {
        cleanUpAfterUpdate()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateController.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.updatesCheckAutomatically), !isBusy else { return }
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 24 * 60 * 60 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool = true) {
        guard !isBusy, let currentVersion else { return }
        state = .checking
        task = Task {
            do {
                let update = try await SoftwareUpdate.check(current: currentVersion)
                lastCheck = .now
                UserDefaults.standard.set(lastCheck, forKey: PreferenceKey.updatesLastCheck)
                let skipped = UserDefaults.standard.string(forKey: PreferenceKey.updatesSkippedVersion)
                if let update, userInitiated || update.version.description != skipped {
                    state = .available(update)
                    Log.updates.info("Update available: \(update.version.description, privacy: .public)")
                } else {
                    state = .upToDate
                }
            } catch {
                Log.updates.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                // Quiet when automatic: no network is normal.
                state = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
            }
        }
    }

    func skip(_ update: AvailableUpdate) {
        UserDefaults.standard.set(update.version.description, forKey: PreferenceKey.updatesSkippedVersion)
        state = .idle
    }

    // MARK: Installing

    func install(_ update: AvailableUpdate) {
        guard canInstall else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        guard isSafeToQuit() else {
            state = .failed("Stop the recording first; installing restarts Pankapture.")
            return
        }
        state = .downloading(update, progress: 0)
        task = Task {
            do {
                let dmg = try await download(update)
                state = .installing(update)
                let staged = try await Self.stage(dmg: dmg, version: update.version)
                try? FileManager.default.removeItem(at: dmg)
                try relaunch(installing: staged)
                state = .waitingToQuit(update)
                NSApp.terminate(nil)
            } catch let error as InstallError {
                if case let .notWritable(dmg) = error {
                    // Can't replace the app in place: hand over the disk image.
                    NSWorkspace.shared.open(dmg)
                    state = .available(update)
                } else {
                    state = .failed(error.message)
                }
            } catch {
                Log.updates.error("Update failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("The update couldn't be installed: \(error.localizedDescription)")
            }
        }
    }

    enum InstallError: Error {
        case notWritable(URL)
        case invalid(String)

        var message: String {
            switch self {
            case .notWritable: "Pankapture's folder isn't writable."
            case let .invalid(reason): reason
            }
        }
    }

    private func download(_ update: AvailableUpdate) async throws -> URL {
        let reporter = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(update, progress: fraction)
            }
        }
        let (temporary, response) = try await URLSession.shared.download(from: update.downloadURL, delegate: reporter)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError.invalid("The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Pankapture-\(update.version).dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: temporary, to: dmg)
        return dmg
    }

    /// Mounts the image, checks the app inside, and copies it next to the
    /// running app (same volume, so the final swap is a rename).
    private nonisolated static func stage(dmg: URL, version: AppVersion) async throws -> URL {
        let destination = Bundle.main.bundleURL
        let folder = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw InstallError.notWritable(dmg) }

        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("pankapture-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path, dmg.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }

        let app = mount.appendingPathComponent("Pankapture.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw InstallError.invalid("The download doesn't contain Pankapture.")
        }
        try verifySignature(of: app)
        let bundledVersion = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard bundledVersion.flatMap(AppVersion.init) == version else {
            throw InstallError.invalid("The download is a different version than expected.")
        }

        let staged = folder.appendingPathComponent("\(leftoverPrefix)\(version)-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// The new app must satisfy this app's designated requirement: same
    /// bundle identifier, signed by the same certificate. A tampered or
    /// differently signed download is refused (and would lose the user's
    /// privacy grants anyway).
    private nonisolated static func verifySignature(of app: URL) throws {
        var current: SecCode?
        var currentStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess, let currentStatic,
              SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw InstallError.invalid("Couldn't check the update's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else {
            Log.updates.error("Update signature rejected: \(status)")
            throw InstallError.invalid("The update isn't signed like this copy of Pankapture, so it wasn't installed.")
        }
    }

    /// A small shell script waits for this process to exit, swaps the
    /// bundles (renames only; nothing is deleted), and opens the new one,
    /// which moves the old bundle to the Trash (`cleanUpAfterUpdate`). If
    /// quitting is cancelled (unsaved edits), it runs whenever the app quits.
    private func relaunch(installing staged: URL) throws {
        let destination = Bundle.main.bundleURL
        let old = destination.deletingLastPathComponent()
            .appendingPathComponent("\(Self.leftoverPrefix)old-\(UUID().uuidString).app")
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.3; done
        if /bin/mv "$2" "$4"; then
          /bin/mv "$3" "$2" || /bin/mv "$4" "$2"
        fi
        /usr/bin/open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "pankapture-update", String(ProcessInfo.processInfo.processIdentifier),
                             destination.path, staged.path, old.path]
        try process.run()
        Log.updates.info("Update staged; relaunching")
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.invalid("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(process.terminationStatus)).")
        }
        return process.terminationStatus
    }
}

/// Download progress for `URLSession.download(from:delegate:)`.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
