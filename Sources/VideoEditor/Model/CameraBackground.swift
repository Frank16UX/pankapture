import AppCore
import Foundation

/// What shows behind the person in the camera layer (PRD CAM-1, CAM-2).
/// Applied by the compositor, so it stays editable after recording.
public struct CameraBackground: Codable, Hashable, Sendable {
    public enum Effect: String, Codable, CaseIterable, Sendable, Identifiable {
        case none
        case blur
        /// A color or a picture.
        case replace
        /// The person cut out over the screen.
        case remove

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .none: "None"
            case .blur: "Blur"
            case .replace: "Replace"
            case .remove: "Remove"
            }
        }
    }

    /// How the person is told apart from the background.
    public enum Matte: String, Codable, CaseIterable, Sendable, Identifiable {
        /// On-device person segmentation.
        case person
        /// A chroma key, for a green (or blue) screen.
        case greenScreen

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .person: "Person Detection"
            case .greenScreen: "Green Screen"
            }
        }
    }

    public var effect: Effect
    /// Blur strength, 0…1.
    public var blurAmount: Double
    /// The replacement color, when there's no picture.
    public var color: RGBAColor
    /// The replacement picture, scaled to fill the camera frame.
    public var imageURL: URL?
    /// Removed backgrounds keep the camera's shape (and its shadow) instead
    /// of showing only the person.
    public var keepsShape: Bool
    /// Blur always finds the person automatically; replace and remove can
    /// use a green screen instead.
    public var matte: Matte
    public var keyColor: RGBAColor
    /// How far from the key color still counts as background, 0…1.
    public var tolerance: Double
    /// How much of the key color's tint to take off the person, 0…1.
    public var spill: Double

    public static let defaultColor = RGBAColor(hex: 0x2B2D31)
    /// A typical chroma-key green.
    public static let defaultKeyColor = RGBAColor(red: 0.1, green: 0.75, blue: 0.25)

    public init(
        effect: Effect = .none,
        blurAmount: Double = 0.5,
        color: RGBAColor = CameraBackground.defaultColor,
        imageURL: URL? = nil,
        keepsShape: Bool = false,
        matte: Matte = .person,
        keyColor: RGBAColor = CameraBackground.defaultKeyColor,
        tolerance: Double = 0.4,
        spill: Double = 0.5
    ) {
        self.effect = effect
        self.blurAmount = blurAmount
        self.color = color
        self.imageURL = imageURL
        self.keepsShape = keepsShape
        self.matte = matte
        self.keyColor = keyColor
        self.tolerance = tolerance
        self.spill = spill
    }

    public var isActive: Bool { effect != .none }

    /// The matte actually used: blur always segments the person.
    public var effectiveMatte: Matte { effect == .blur ? .person : matte }

    /// A gray key color can't be told apart from the person.
    public var keyColorIsUsable: Bool { CameraMatte.keyStrength(of: keyColor) != nil }

    /// Whether the camera's shape and shadow are drawn.
    public var drawsShape: Bool { effect != .remove || keepsShape }

    private enum CodingKeys: String, CodingKey {
        case effect, blurAmount, color, imageURL, keepsShape, matte, keyColor, tolerance, spill
    }

    /// Every key is optional, so settings saved by other versions still open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CameraBackground()
        effect = try container.decodeIfPresent(Effect.self, forKey: .effect) ?? defaults.effect
        blurAmount = try container.decodeIfPresent(Double.self, forKey: .blurAmount) ?? defaults.blurAmount
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? defaults.color
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        keepsShape = try container.decodeIfPresent(Bool.self, forKey: .keepsShape) ?? defaults.keepsShape
        matte = try container.decodeIfPresent(Matte.self, forKey: .matte) ?? defaults.matte
        keyColor = try container.decodeIfPresent(RGBAColor.self, forKey: .keyColor) ?? defaults.keyColor
        tolerance = try container.decodeIfPresent(Double.self, forKey: .tolerance) ?? defaults.tolerance
        spill = try container.decodeIfPresent(Double.self, forKey: .spill) ?? defaults.spill
    }

    // MARK: Default (CAM-3)

    /// The background new recordings start with, from Settings ▸ Recording.
    public static func savedDefault(in defaults: UserDefaults = .standard) -> CameraBackground {
        guard let data = defaults.data(forKey: PreferenceKey.recordingCameraBackground),
              let background = try? JSONDecoder().decode(CameraBackground.self, from: data) else { return CameraBackground() }
        return background
    }

    public static func saveDefault(_ background: CameraBackground, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(background) else { return }
        defaults.set(data, forKey: PreferenceKey.recordingCameraBackground)
    }
}
