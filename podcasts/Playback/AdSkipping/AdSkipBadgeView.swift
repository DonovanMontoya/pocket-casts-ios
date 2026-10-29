import Combine
import PocketCastsDataModel
import UIKit

/// The ads state of one episode in a list row, shown beside the download icon:
/// the number of ads found, progress while finding them, or a warning when it failed.
/// Hidden for episodes that haven't been checked.
@MainActor
final class AdSkipBadgeView: UIStackView {
    private let icon = UIImageView()
    private let label = ThemeableLabel()
    private var episodeUuid: String?
    private var podcastUuid: String?
    private var isDownloaded = false
    private var subscription: AnyCancellable?

    /// What the row reads out to VoiceOver, or nil when there's nothing to say.
    private(set) var accessibilityText: String?

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 2
        isHidden = true

        icon.image = UIImage(systemName: "forward.end.alt")
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small).applying(UIImage.SymbolConfiguration(weight: .bold))
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.style = .primaryText02
        label.font = UIFont.font(ofSize: 13, scalingWith: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        addArrangedSubview(icon)
        addArrangedSubview(label)

        // objectWillChange fires before the new value lands, so read it on the next pass.
        subscription = AdSkipCoordinator.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ episode: BaseEpisode?) {
        let episode = AdSkipSettings.isSupported ? episode as? Episode : nil
        episodeUuid = episode?.uuid
        podcastUuid = episode?.podcastUuid
        isDownloaded = episode?.downloaded(pathFinder: DownloadManager.shared) ?? false
        refresh()
    }

    private func refresh() {
        let coordinator = AdSkipCoordinator.shared
        guard let episodeUuid else { return hide() }

        switch coordinator.statuses[episodeUuid] {
        case .waiting:
            apply(text: nil, alpha: 0.5, accessibility: "Waiting to find ads")
        case .finding(let progress):
            let percent = "\(Int((progress * 100).rounded()))%"
            apply(text: percent, accessibility: "Finding ads, \(percent)")
        case .failed:
            apply(text: nil, tint: ThemeColor.support05(), accessibility: "Couldn't find ads")
        case .found, nil:
            guard isDownloaded, let ads = coordinator.skippableAds(for: episodeUuid) else { return hide() }
            let exempt = podcastUuid.map(coordinator.isExempt(podcastUuid:)) ?? false
            let found = ads.count == 1 ? "1 ad found" : "\(ads.count) ads found"
            apply(text: "\(ads.count)", alpha: exempt ? 0.5 : 1, accessibility: found)
        }
    }

    private func hide() {
        isHidden = true
        accessibilityText = nil
    }

    private func apply(text: String?, tint: UIColor = ThemeColor.primaryIcon02(), alpha: CGFloat = 1, accessibility: String) {
        icon.tintColor = tint
        label.text = text
        label.isHidden = text == nil
        self.alpha = alpha
        accessibilityText = accessibility
        isHidden = false
    }
}
