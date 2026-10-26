import AIProviders
import AppCore
import Foundation
import Transcription

/// The cloud transcription service the user chose in Settings ▸ AI (PRD
/// AI-5), if any. Off by default; its key lives in the Keychain.
public enum CloudTranscriptionSettings {
    public static var service: CloudTranscriptionService? {
        get { UserDefaults.standard.string(forKey: PreferenceKey.cloudTranscriptionService).flatMap(CloudTranscriptionService.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: PreferenceKey.cloudTranscriptionService) }
    }

    /// The service to transcribe with now: chosen and with a key.
    public static func active() -> (service: CloudTranscriptionService, apiKey: String)? {
        guard let service, let key = APIKeyStore.key(for: service.keyAccount) else { return nil }
        return (service, key)
    }
}
