import AppKit
import DesignSystem
import SwiftUI

/// Decoded thumbnails, keyed by file + edit version so re-edits refresh them.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 600
        return cache
    }()

    func image(for url: URL, version: Date) async -> CGImage? {
        let key = "\(url.path)#\(version.timeIntervalSince1970)" as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        guard let image = await LibraryIO.loadImage(at: url) else { return nil }
        cache.setObject(Entry(image), forKey: key)
        return image
    }
}

/// Async-loaded thumbnail, aspect-fit on a subtle fill.
struct ThumbnailView: View {
    let url: URL?
    let version: Date
    let kind: CaptureKind

    @State private var image: CGImage?

    private struct LoadKey: Hashable {
        var url: URL?
        var version: Date
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: LoadKey(url: url, version: version)) {
            guard let url else {
                image = nil
                return
            }
            image = await ThumbnailCache.shared.image(for: url, version: version)
        }
    }
}

/// Small capsule label over a thumbnail (kind, duration, missing file).
struct ThumbnailBadge: View {
    let text: String?
    let systemImage: String
    var tint: Color?

    var body: some View {
        HStack(spacing: PK.Spacing.xxs) {
            Image(systemName: systemImage)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            if let text {
                Text(text).monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, PK.Spacing.xs + PK.Spacing.xxs)
        .padding(.vertical, PK.Spacing.xxs)
        .background(.regularMaterial, in: Capsule())
        .padding(PK.Spacing.xs)
    }
}

enum LibraryFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }
}

/// One grid cell (HI-2): thumbnail with kind / duration / missing badges, name (HI-7), and date.
struct CaptureCard: View {
    let item: CaptureSnapshot
    let isSelected: Bool

    static let thumbnailHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.xs) {
            ThumbnailView(url: item.thumbnailURL, version: item.editedAt, kind: item.kind)
                .opacity(item.isUnavailable ? 0.55 : 1)
                .frame(height: Self.thumbnailHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                        .strokeBorder(.separator, lineWidth: PK.Metrics.hairline)
                }
                .overlay(alignment: .topLeading) {
                    if item.kind != .screenshot {
                        ThumbnailBadge(text: item.kind == .gif ? "GIF" : nil, systemImage: item.kind.symbolName)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = item.duration {
                        ThumbnailBadge(text: LibraryFormat.duration(duration), systemImage: "play.fill")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isUnavailable {
                        ThumbnailBadge(text: "Missing", systemImage: "exclamationmark.triangle.fill", tint: .yellow)
                    }
                }

            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                // Two lines, always reserved, so long names stay readable and rows stay even.
                Text(item.displayName)
                    .font(.callout)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.middle)
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, PK.Spacing.xxs)
        }
        .padding(PK.Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: PK.Radius.thumbnail + PK.Spacing.xs, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: PK.Radius.thumbnail + PK.Spacing.xs, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var parts = [item.kind.title, item.displayName]
        if !item.tags.isEmpty { parts.append("tags: " + item.tags.joined(separator: ", ")) }
        if let duration = item.duration { parts.append(LibraryFormat.duration(duration)) }
        if item.isUnavailable { parts.append("file missing") }
        return parts.joined(separator: ", ")
    }
}
