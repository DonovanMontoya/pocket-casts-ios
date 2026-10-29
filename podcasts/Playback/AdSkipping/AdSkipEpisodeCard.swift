import AdSkipping
import PocketCastsUtils
import SwiftUI

/// What the episode page tells the ads card as the episode changes.
final class AdSkipEpisodeModel: ObservableObject {
    let episodeUuid: String
    @Published var isDownloaded: Bool
    let openSettings: () -> Void

    init(episodeUuid: String, isDownloaded: Bool, openSettings: @escaping () -> Void) {
        self.episodeUuid = episodeUuid
        self.isDownloaded = isDownloaded
        self.openSettings = openSettings
    }
}

/// Shows whether ads were found in an episode's download, and finds them on request.
struct AdSkipEpisodeCard: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: AdSkipEpisodeModel
    @ObservedObject private var coordinator = AdSkipCoordinator.shared

    private enum CardState {
        case needsKey, notDownloaded, ready, waiting
        case finding(Double)
        case found([AdSegment])
        case failed(String)
    }

    private var state: CardState {
        switch coordinator.statuses[model.episodeUuid] {
        case .waiting: return .waiting
        case .finding(let progress): return .finding(progress)
        case .failed(let message): return .failed(message)
        case .found, nil: break
        }
        if !coordinator.hasAPIKey { return .needsKey }
        if !model.isDownloaded { return .notDownloaded }
        if let ads = coordinator.skippableAds(for: model.episodeUuid) { return .found(ads) }
        return .ready
    }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "forward.end.alt")
                    .foregroundStyle(theme.primaryIcon02)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(state))
                        .font(size: 15, style: .body, weight: .medium)
                        .foregroundStyle(theme.primaryText01)
                    Text(detail(state))
                        .font(size: 13, style: .footnote)
                        .foregroundStyle(theme.primaryText02)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                accessory(state)
            }
            if case .finding(let progress) = state {
                ProgressView(value: progress)
                    .tint(theme.primaryInteractive01)
            }
            if case .found(let ads) = state, !ads.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ads) { ad in
                        Text("\(TimeFormatter.shared.playTimeFormat(time: ad.start)) to \(TimeFormatter.shared.playTimeFormat(time: ad.end))")
                            .font(size: 13, style: .footnote)
                            .monospacedDigit()
                            .foregroundStyle(theme.primaryText02)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(16)
        .background(theme.primaryUi02Active)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func title(_ state: CardState) -> String {
        switch state {
        case .needsKey, .notDownloaded, .ready: "Find ads"
        case .waiting, .finding: "Finding ads"
        case .found(let ads): ads.isEmpty ? "No ads found" : ads.count == 1 ? "1 ad found" : "\(ads.count) ads found"
        case .failed: "Couldn't find ads"
        }
    }

    private func detail(_ state: CardState) -> String {
        switch state {
        case .needsKey:
            "Add an OpenAI API key in Ad Skipping settings."
        case .notDownloaded:
            "Download this episode to find its ads."
        case .ready:
            "Transcribes this download on your iPhone and checks it for ads."
        case .waiting:
            "Waiting for another episode to finish."
        case .finding(let progress):
            progress < 1 ? "Transcribing, \(Int((progress * 100).rounded()))%" : "Checking the transcript for ads"
        case .found(let ads):
            if ads.isEmpty {
                "Nothing to skip in this download."
            } else if AdSkipSettings.isEnabled {
                "\(TimeFormatter.shared.multipleUnitFormattedShortTime(time: ads.reduce(0) { $0 + $1.end - $1.start })) skipped when it plays."
            } else {
                "Ad skipping is off in Settings."
            }
        case .failed(let message):
            message
        }
    }

    @ViewBuilder
    private func accessory(_ state: CardState) -> some View {
        switch state {
        case .needsKey:
            actionButton("Settings", action: model.openSettings)
        case .ready:
            actionButton("Find Ads") { coordinator.findAds(in: model.episodeUuid) }
        case .found:
            actionButton("Find Again") { coordinator.findAds(in: model.episodeUuid) }
        case .failed where model.isDownloaded:
            actionButton("Try Again") { coordinator.findAds(in: model.episodeUuid) }
        case .waiting:
            ProgressView()
        default:
            EmptyView()
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(size: 15, style: .body, weight: .semibold)
            .foregroundStyle(theme.primaryInteractive01)
            .buttonStyle(.borderless)
    }
}
