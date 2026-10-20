import Foundation

/// A release version, "1.2.3" (a leading "v" is accepted). Missing parts are 0.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A published release that's newer than the running app.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: AppVersion
    /// The release's disk image.
    public let downloadURL: URL
    public let byteCount: Int
    /// The release page, for notes and a manual download.
    public let pageURL: URL
    /// Release notes (Markdown), possibly empty.
    public let notes: String
}

/// Looks for a newer Pankapture on GitHub Releases (UP-1, ADR-28). The only
/// request is an anonymous GET of the latest release; nothing about the user
/// or their captures is sent.
public enum SoftwareUpdate {
    public static let repository = "Frank16UX/pankapture"
    public static let assetName = "Pankapture.dmg"

    /// The running app's version (`CFBundleShortVersionString`).
    public static var currentVersion: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    /// Builds made by the release workflow carry `PKReleaseBuild`; local
    /// `make app` builds don't, so they never replace themselves.
    public static var isReleaseBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "PKReleaseBuild") as? Bool ?? false
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let browser_download_url: URL
        }

        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// The newest release if it's newer than `current`, else `nil`.
    public static func check(
        current: AppVersion,
        session: URLSession = .shared
    ) async throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pankapture/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // No release published yet.
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try update(from: data, current: current)
    }

    /// Parses a GitHub "latest release" response.
    static func update(from data: Data, current: AppVersion) throws -> AvailableUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              let version = AppVersion(release.tag_name), version > current,
              let asset = release.assets.first(where: { $0.name == assetName }) else { return nil }
        return AvailableUpdate(
            version: version,
            downloadURL: asset.browser_download_url,
            byteCount: asset.size,
            pageURL: release.html_url,
            notes: release.body ?? ""
        )
    }
}
