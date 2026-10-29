import Foundation
import PocketCastsUtils

/// Local-only settings for ad skipping. Nothing here syncs to Pocket Casts.
enum AdSkipSettings {
    private static let enabledKey = "AdSkipEnabled"
    private static let apiKeyKeychainKey = "AdSkipOpenAIKey"

    /// Ads scored at or above this are skipped. OpenAI Decisions scores real ads 0.96 to 1.00.
    static let confidenceThreshold = 0.8

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Readable after first unlock, so episodes downloaded while the phone is locked can be analyzed.
    static var apiKey: String? {
        get {
            guard let key = try? KeychainHelper.string(for: apiKeyKeychainKey),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return key
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                KeychainHelper.removeKey(apiKeyKeychainKey)
            } else {
                _ = KeychainHelper.save(string: trimmed, key: apiKeyKeychainKey, accessibility: kSecAttrAccessibleAfterFirstUnlock)
            }
        }
    }

    /// Apple Speech's SpeechAnalyzer, which transcribes on device, needs iOS 26.
    static var isSupported: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }
}
