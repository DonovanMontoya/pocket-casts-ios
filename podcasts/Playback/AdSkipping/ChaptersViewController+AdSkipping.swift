import AdSkipping
import PocketCastsUtils
import PocketCastsDataModel
import UIKit

extension PlaybackManager {
    /// The ads skipped in the playing download, for the timeline and the chapter list.
    @MainActor
    var currentEpisodeAds: [AdSegment] {
        guard let episode = currentEpisode as? Episode,
              episode.downloaded(pathFinder: DownloadManager.shared) else { return [] }
        return AdSkipCoordinator.shared.skippableAds(for: episode.uuid) ?? []
    }

    /// Plays an ad from the chapter list instead of skipping it.
    @MainActor
    func playAd(_ ad: AdSegment) {
        guard let episodeUuid = currentEpisode?.uuid else { return }
        AdSkipCoordinator.shared.markSkipped(ad, episodeUuid: episodeUuid)
        AnalyticsPlaybackHelper.shared.ignoreNextSeekEvent()
        seekTo(time: ad.start, startPlaybackAfterSeek: true)
    }
}

/// A row in the player's chapter list for an ad that playback skips.
@MainActor
final class AdChapterCell: UITableViewCell {
    static let reuseIdentifier = "AdChapterCell"

    private let icon = AdSkipIconView()
    private let title = UILabel()
    private let times = UILabel()
    private let length = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        icon.color = .systemYellow
        title.text = "Ad"
        title.font = .font(ofSize: 14, weight: .medium, scalingWith: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        times.font = .font(ofSize: 12, weight: .medium, scalingWith: .caption1)
        times.adjustsFontForContentSizeCategory = true
        length.font = .font(ofSize: 12, weight: .semibold, scalingWith: .caption1)
        length.adjustsFontForContentSizeCategory = true
        length.textAlignment = .right
        length.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [icon, title, times, length] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            times.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            times.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            length.leadingAnchor.constraint(greaterThanOrEqualTo: times.trailingAnchor, constant: 8),
            length.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            length.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func populate(ad: AdSegment, isPlayed: Bool) {
        let color = isPlayed ? ThemeColor.playerContrast02() : ThemeColor.playerContrast01()
        title.textColor = color
        length.textColor = color
        times.textColor = ThemeColor.playerContrast02()
        icon.alpha = isPlayed ? 0.5 : 1
        length.text = TimeFormatter.shared.singleUnitFormattedShortestTime(time: ad.end - ad.start)
        let range = "\(TimeFormatter.shared.playTimeFormat(time: ad.start)) to \(TimeFormatter.shared.playTimeFormat(time: ad.end))"
        times.text = range
        accessibilityLabel = "Ad, \(range), skipped"
        accessibilityHint = "Plays the ad"
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        backgroundColor = highlighted ? ThemeColor.playerContrast05() : .clear
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        setHighlighted(selected, animated: animated)
    }
}
