import SwiftUI
import UIKit

extension EpisodeDetailViewController {
    /// Places the ads card under the action buttons, above the transcript card.
    func addAdSkipCard() {
        guard AdSkipSettings.isSupported,
              let actionsView = messageContainerView.superview as? UIStackView,
              let index = actionsView.arrangedSubviews.firstIndex(of: messageContainerView) else { return }

        let model = AdSkipEpisodeModel(
            episodeUuid: episode.uuid,
            podcastUuid: episode.podcastUuid,
            isDownloaded: episode.downloaded(pathFinder: DownloadManager.shared),
            openSettings: { [weak self] in self?.showAdSkipSettings() }
        )
        let controller = ThemedHostingController(rootView: AdSkipEpisodeCard(model: model))
        controller.sizingOptions = [.intrinsicContentSize]
        addChild(controller)
        actionsView.insertArrangedSubview(controller.view, at: index + 1)
        controller.didMove(toParent: self)
        adSkipModel = model
    }

    func updateAdSkipCard() {
        let isDownloaded = episode.downloaded(pathFinder: DownloadManager.shared)
        if adSkipModel?.isDownloaded != isDownloaded { adSkipModel?.isDownloaded = isDownloaded }
    }

    private func showAdSkipSettings() {
        let controller = UIHostingController(rootView: AdSkipSettingsView().setupDefaultEnvironment())
        let navigationController = SJUIUtils.navController(for: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak navigationController] _ in
            navigationController?.dismiss(animated: true)
        })
        present(navigationController, animated: true)
    }
}
