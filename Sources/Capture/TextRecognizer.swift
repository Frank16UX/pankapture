import CoreGraphics
import Foundation
import Vision

/// On-device OCR for "Capture Text" (SC-12).
public enum TextRecognizer {
    /// Recognized lines, top to bottom, joined with newlines.
    public static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
