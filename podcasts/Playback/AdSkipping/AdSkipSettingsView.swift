import PocketCastsDataModel
import SwiftUI

struct AdSkipSettingsView: View {
    @ObservedObject private var coordinator = AdSkipCoordinator.shared
    @State private var isEnabled = AdSkipSettings.isEnabled
    @State private var hasKey = AdSkipSettings.apiKey != nil
    @State private var keyDraft = ""

    var body: some View {
        Form {
            if !AdSkipSettings.isSupported {
                Section {
                    Text("Finding ads transcribes episodes on this iPhone with Apple Speech, which needs iOS 26 or later.")
                }
            }

            Section {
                Toggle("Skip ads automatically", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, value in
                        AdSkipSettings.isEnabled = value
                    }
            } footer: {
                Text("When an episode finishes downloading, it's transcribed on this iPhone, and the transcript text is checked for ads. Ads are then skipped during playback of that download.")
            }

            Section {
                if hasKey {
                    LabeledContent("OpenAI API key", value: "Saved")
                    Button("Remove Key", role: .destructive) {
                        AdSkipSettings.apiKey = nil
                        hasKey = false
                    }
                } else {
                    SecureField("OpenAI API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Key") {
                        AdSkipSettings.apiKey = keyDraft
                        keyDraft = ""
                        hasKey = AdSkipSettings.apiKey != nil
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("Ads are found with OpenAI Decisions, usually about a third of a cent per episode. Only transcript text is sent, never audio. When the show publishes its own transcript, audio missing from it is treated as an inserted ad.")
            }

            Section {
                Button("Find Ads in Downloaded Episodes") {
                    coordinator.findAdsInDownloadedEpisodes()
                }
                .disabled(!AdSkipSettings.isSupported || !hasKey || !isEnabled)
            }

            if !coordinator.statuses.isEmpty {
                Section("Recent") {
                    ForEach(coordinator.statuses.keys.sorted(), id: \.self) { uuid in
                        LabeledContent(
                            DataManager.shared.findEpisode(uuid: uuid)?.title ?? "Episode",
                            value: Self.describe(coordinator.statuses[uuid])
                        )
                    }
                }
            }
        }
        .navigationTitle("Ad Skipping")
    }

    private static func describe(_ status: AdSkipCoordinator.Status?) -> String {
        switch status {
        case .waiting, nil:
            "Waiting"
        case .finding(let progress):
            "Finding ads, \(Int((progress * 100).rounded()))%"
        case .found(let count):
            count == 1 ? "1 ad" : "\(count) ads"
        case .failed(let message):
            message
        }
    }
}
