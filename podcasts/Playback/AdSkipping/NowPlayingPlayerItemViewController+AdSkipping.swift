extension NowPlayingPlayerItemViewController {
    /// Marks the ads that will be skipped on the timeline of the playing download.
    func updateAdMarkers() {
        timeSlider.markedRanges = PlaybackManager.shared.currentEpisodeAds.map { $0.start..<$0.end }
    }
}
