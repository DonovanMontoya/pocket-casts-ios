import Foundation
import PocketCastsUtils

/// Local-only settings for ad skipping. Nothing here syncs to Pocket Casts.
enum AdSkipSettings {
    private static let enabledKey = "AdSkipEnabled"
    private static let findOnDownloadKey = "AdSkipFindOnDownload"
    private static let confidenceKey = "AdSkipConfidenceThreshold"
    private static let exemptPodcastsKey = "AdSkipExemptPodcasts"
    private static let apiKeyKeychainKey = "AdSkipOpenAIKey"

    /// Ads scored at or above this are skipped. OpenAI Decisions scores real ads 0.96 to 1.00.
    static let defaultConfidenceThreshold = 0.8
    /// Ads scored below 0.5 aren't kept, so a lower threshold would change nothing.
    static let confidenceRange = 0.5...0.99

    static var confidenceThreshold: Double {
        get { (UserDefaults.standard.object(forKey: confidenceKey) as? Double ?? defaultConfidenceThreshold).clamped(to: confidenceRange) }
        set { UserDefaults.standard.set(newValue.clamped(to: confidenceRange), forKey: confidenceKey) }
    }

    /// Podcasts whose ads are left alone: not skipped, and not looked for on download.
    static var exemptPodcastUuids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: exemptPodcastsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: exemptPodcastsKey) }
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var findOnDownload: Bool {
        get { UserDefaults.standard.object(forKey: findOnDownloadKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: findOnDownloadKey) }
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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
