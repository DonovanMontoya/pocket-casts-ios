import AdSkipping
import PocketCastsUtils
import SwiftUI

/// What the episode page tells the ads card as the episode changes.
final class AdSkipEpisodeModel: ObservableObject {
    let episodeUuid: String
    let podcastUuid: String
    @Published var isDownloaded: Bool
    let openSettings: () -> Void

    init(episodeUuid: String, podcastUuid: String, isDownloaded: Bool, openSettings: @escaping () -> Void) {
        self.episodeUuid = episodeUuid
        self.podcastUuid = podcastUuid
        self.isDownloaded = isDownloaded
        self.openSettings = openSettings
    }
}

/// A one-line summary of the ads in an episode's download. Details, ad times and
/// finding again stay folded away until the row is tapped.
struct AdSkipEpisodeCard: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var model: AdSkipEpisodeModel
    @ObservedObject private var coordinator = AdSkipCoordinator.shared
    @State private var isExpanded = false

    private enum CardState {
        case needsKey, notDownloaded, ready, waiting
        case finding(Double)
        case found([AdSegment])
        case failed(String)

        var isExpandable: Bool {
            switch self {
            case .found, .failed: true
            default: false
            }
        }
    }

    private var state: CardState {
        switch coordinator.statuses[model.episodeUuid] {
        case .waiting: return .waiting
        case .finding(let progress): return .finding(progress)
        case .failed(let message): return .failed(message)
        case .found, nil: break
        }
        if model.isDownloaded, let ads = coordinator.skippableAds(for: model.episodeUuid) { return .found(ads) }
        if !coordinator.hasAPIKey { return .needsKey }
        if !model.isDownloaded { return .notDownloaded }
        return .ready
    }

    var body: some View {
        let state = state
        let showsDetails = isExpanded && state.isExpandable
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "forward.end.alt")
                    .foregroundStyle(theme.primaryIcon02)
                    .accessibilityHidden(true)
                Text(title(state))
                    .font(size: 15, style: .body, weight: .medium)
                    .foregroundStyle(theme.primaryText01)
                Spacer(minLength: 8)
                accessory(state)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard state.isExpandable else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(state.isExpandable ? .isButton : [])
            .accessibilityHint(state.isExpandable ? (isExpanded ? "Hides details" : "Shows details") : "")

            if case .finding(let progress) = state {
                ProgressView(value: progress)
                    .tint(theme.primaryInteractive01)
            }

            if showsDetails {
                details(state)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.primaryUi02Active)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func title(_ state: CardState) -> String {
        switch state {
        case .needsKey, .ready: "Not checked for ads"
        case .notDownloaded: "Download to find ads"
        case .waiting: "Waiting to find ads"
        case .finding: "Finding ads"
        case .found(let ads): ads.isEmpty ? "No ads found" : ads.count == 1 ? "1 ad found" : "\(ads.count) ads found"
        case .failed: "Couldn't find ads"
        }
    }

    @ViewBuilder
    private func accessory(_ state: CardState) -> some View {
        switch state {
        case .needsKey:
            actionButton("Add Key", action: model.openSettings)
        case .ready:
            actionButton("Find Ads") { coordinator.findAds(in: model.episodeUuid) }
        case .waiting:
            ProgressView()
        case .finding(let progress):
            Text(progress < 1 ? "\(Int((progress * 100).rounded()))%" : "Checking")
                .font(size: 13, style: .footnote)
                .monospacedDigit()
                .foregroundStyle(theme.primaryText02)
        case .found, .failed:
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.primaryIcon02)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        case .notDownloaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func details(_ state: CardState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .found(let ads):
                Text(foundDetail(ads))
                    .font(size: 13, style: .footnote)
                    .foregroundStyle(theme.primaryText02)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ads) { ad in
                    Text("\(TimeFormatter.shared.playTimeFormat(time: ad.start)) to \(TimeFormatter.shared.playTimeFormat(time: ad.end))")
                        .font(size: 13, style: .footnote)
                        .monospacedDigit()
                        .foregroundStyle(theme.primaryText02)
                }
                actionButton("Find Again") { coordinator.findAds(in: model.episodeUuid) }
            case .failed(let message):
                Text(message)
                    .font(size: 13, style: .footnote)
                    .foregroundStyle(theme.primaryText02)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isDownloaded {
                    actionButton("Try Again") { coordinator.findAds(in: model.episodeUuid) }
                }
            default:
                EmptyView()
            }
        }
        .padding(.leading, 32)
    }

    private func foundDetail(_ ads: [AdSegment]) -> String {
        if ads.isEmpty { return "Nothing to skip in this download." }
        if coordinator.isExempt(podcastUuid: model.podcastUuid) { return "Ads aren't skipped on this podcast." }
        if !AdSkipSettings.isEnabled { return "Ad skipping is off in Settings." }
        let total = ads.reduce(0) { $0 + $1.end - $1.start }
        return "\(TimeFormatter.shared.multipleUnitFormattedShortTime(time: total)) skipped when it plays."
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(size: 15, style: .body, weight: .semibold)
            .foregroundStyle(theme.primaryInteractive01)
            .buttonStyle(.borderless)
    }
}
