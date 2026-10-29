import PocketCastsDataModel

extension NowPlayingPlayerItemViewController {
    /// Marks the ads that will be skipped on the timeline of the playing download.
    func updateAdMarkers() {
        guard let episode = PlaybackManager.shared.currentEpisode as? Episode,
              episode.downloaded(pathFinder: DownloadManager.shared) else {
            timeSlider.markedRanges = []
            return
        }
        timeSlider.markedRanges = (AdSkipCoordinator.shared.skippableAds(for: episode.uuid) ?? []).map { $0.start..<$0.end }
    }
}
