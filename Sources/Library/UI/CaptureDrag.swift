import AppKit
import UniformTypeIdentifiers

/// In-app drags of captures onto sidebar folders and tags (HI-8, HI-9). Cards
/// offer this type next to their file data; it carries the IDs of every
/// dragged capture (the whole selection when the card is part of it).
enum CaptureDrag {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`).
    static let type = UTType(exportedAs: "com.franklinperez.pankapture.capture-ids", conformingTo: .data)

    static func register(_ ids: [UUID], on provider: NSItemProvider) {
        let data = Data(ids.map(\.uuidString).joined(separator: "\n").utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
    }

    /// The capture IDs in a drop; empty when it came from somewhere else.
    @MainActor
    static func ids(from providers: [NSItemProvider]) async -> [UUID] {
        var ids: [UUID] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data, let text = String(data: data, encoding: .utf8) else { continue }
            ids += text.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
        }
        return ids
    }
}
