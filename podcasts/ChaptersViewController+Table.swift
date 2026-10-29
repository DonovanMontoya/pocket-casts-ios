import Foundation
import SafariServices
import PocketCastsUtils
#if !APPCLIP
import AdSkipping
#endif

/// A row in the chapter list: a chapter, by its index in the shown chapters, or an ad.
enum ChapterListRow {
    case chapter(Int)
    #if !APPCLIP
    case ad(AdSegment)
    #endif

    var chapterIndex: Int? {
        if case .chapter(let index) = self { return index }
        return nil
    }
}

extension PlaybackManager {
    /// The chapter list shows ads too, so it earns a tab even when there are no chapters.
    @MainActor
    var hasChapterListRows: Bool {
        #if APPCLIP
        chapterCount() > 0
        #else
        chapterCount() > 0 || !currentEpisodeAds.isEmpty
        #endif
    }
}

extension ChaptersViewController: UITableViewDataSource, UITableViewDelegate, UIScrollViewDelegate {
    private static let chapterCell = "ChapterCell"

    func registerCells() {
        chaptersTable.register(UINib(nibName: "PlayerChapterCell", bundle: nil), forCellReuseIdentifier: ChaptersViewController.chapterCell)
        #if !APPCLIP
        chaptersTable.register(AdChapterCell.self, forCellReuseIdentifier: AdChapterCell.reuseIdentifier)
        #endif
    }

    private func chapter(at index: Int) -> ChapterInfo? {
        isTogglingChapters ? PlaybackManager.shared.chapterAt(index: index) : PlaybackManager.shared.playableChapterAt(index: index)
    }

    func makeRows() -> [ChapterListRow] {
        var rows = (0..<PlaybackManager.shared.chapterCount(onlyPlayable: !isTogglingChapters)).map(ChapterListRow.chapter)
        #if !APPCLIP
        // Each ad goes before the first chapter that starts after it. Ads are left
        // out while picking chapters to skip, since they're skipped anyway.
        guard !isTogglingChapters else { return rows }
        for ad in PlaybackManager.shared.currentEpisodeAds.sorted(by: { $0.start < $1.start }) {
            let position = rows.firstIndex { row in
                row.chapterIndex.flatMap { chapter(at: $0) }.map { $0.effectiveStartTime > ad.start } ?? false
            } ?? rows.count
            rows.insert(.ad(ad), at: position)
        }
        #endif
        return rows
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrollViewHandler?.scrollViewDidScroll?(scrollView)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows = makeRows()
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        #if !APPCLIP
        if case .ad(let ad) = rows[indexPath.row] {
            let adCell = tableView.dequeueReusableCell(withIdentifier: AdChapterCell.reuseIdentifier, for: indexPath) as! AdChapterCell
            adCell.populate(ad: ad, isPlayed: PlaybackManager.shared.currentTime >= ad.end)
            return adCell
        }
        #endif
        let chapterCell = tableView.dequeueReusableCell(withIdentifier: ChaptersViewController.chapterCell, for: indexPath) as! PlayerChapterCell

        if let chapter = rows[indexPath.row].chapterIndex.flatMap({ chapter(at: $0) }) {
            var state = PlayerChapterCell.ChapterPlayState.played
            let currentChapters = PlaybackManager.shared.currentChapters

            if chapter.index == currentChapters.index {
                state = PlaybackManager.shared.isPlaying ? .currentlyPlaying : .currentlyPaused
            } else if chapter.index > currentChapters.index {
                state = .future
            }

            chapterCell.populateFrom(chapter: chapter, playState: state, isChapterToggleEnabled: isTogglingChapters) { [weak self] url in
                if Settings.openLinks {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                } else {
                    self?.present(SFSafariViewController(with: url), animated: true)
                }
            }

            chapterCell.seperatorView.isHidden = (chapter.index == PlaybackManager.shared.currentChapters.index - 1 || chapter.index == PlaybackManager.shared.currentChapters.index || (indexPath.row == rows.count - 1))
        }

        chapterCell.setResolving(indexPath == resolvingIndexPath)

        return chapterCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        #if !APPCLIP
        if case .ad(let ad) = rows[indexPath.row] {
            PlaybackManager.shared.playAd(ad)
            return
        }
        #endif
        guard let index = rows[indexPath.row].chapterIndex else { return }

        guard !isTogglingChapters else {
            // Ensure at least one chapter is selected
            if PlaybackManager.shared.chapterAt(index: index)?.isPlayable() == true, PlaybackManager.shared.chapterCount(onlyPlayable: true) == 1 {
                Toast.show(L10n.selectAChapter)
                return
            }

            (tableView.cellForRow(at: indexPath) as? PlayerChapterCell)?.toggleChapterTapped(self)
            return
        }

        if let chapter = PlaybackManager.shared.playableChapterAt(index: index) {
            if chapter.index == PlaybackManager.shared.currentChapters.index {
                containerDelegate?.scrollToNowPlaying()
                // Android also emits the selection event when the tapped chapter is
                // already playing, so keep parity even though nothing seeks here.
                trackChapterSelected()
            } else if GeneratedChapterSeeker.isEnabled {
                resolveAndSeek(to: chapter, at: indexPath)
            } else {
                trackChapterSelected()
                PlaybackManager.shared.skipToChapter(chapter, startPlaybackAfterSkip: true)
            }
        }
    }

    private func resolveAndSeek(to chapter: ChapterInfo, at indexPath: IndexPath) {
        // Clear any spinner from a previously-resolving row and reset the pointer.
        // The async path re-sets it for the tapped row via willBeginResolving; a
        // cache hit resolves synchronously and leaves resolvingIndexPath nil, so a
        // stale pointer can't resurface the wrong spinner on reuse/reload.
        if let previous = resolvingIndexPath {
            (chaptersTable.cellForRow(at: previous) as? PlayerChapterCell)?.setResolving(false)
        }
        resolvingIndexPath = nil

        // Fire on every tap — including the cache hit that resolves synchronously
        // without a spinner — so the selection event matches the non-generated path.
        trackChapterSelected()

        GeneratedChapterSeeker.seek(
            to: chapter,
            startPlayback: true,
            willBeginResolving: { [weak self] in
                self?.resolvingIndexPath = indexPath
                (self?.chaptersTable.cellForRow(at: indexPath) as? PlayerChapterCell)?.setResolving(true)
            },
            didEndResolving: { [weak self] in
                self?.resolvingIndexPath = nil
                (self?.chaptersTable.cellForRow(at: indexPath) as? PlayerChapterCell)?.setResolving(false)
            }
        )
    }

    /// Tracked directly rather than through `trackChapterEvent`: the playback
    /// helper merges in a default "source" (the current view) that wins over
    /// ours, but this event's source is typed as `chapters_shown_source` and
    /// must be "fullscreen_player", matching Android. Bypassing the helper also
    /// drops its auto-injected `content_type`, so re-add it from the same source.
    private func trackChapterSelected() {
        Analytics.track(.playerChapterSelected, properties: [
            "origin": PlaybackManager.shared.chaptersOriginAnalyticsValue,
            "source": "fullscreen_player",
            "content_type": AnalyticsPlaybackHelper.shared.currentEpisodeIsVideo ? "video" : "audio",
            "episode_uuid": PlaybackManager.shared.currentEpisode?.uuid ?? "unknown",
            "podcast_uuid": PlaybackManager.shared.currentPodcast?.uuid ?? "unknown"
        ])
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        UITableView.automaticDimension
    }

    var shouldShowDeselectChaptersHeader: Bool {
        PlaybackManager.shared.currentEpisode?.isUserEpisode == false
    }
}

extension ChaptersViewController: ChaptersHeaderDelegate {
    func toggleTapped() {
        guard PaidFeature.deselectChapters.isUnlocked else {
            PaidFeature.deselectChapters.presentUpgradeController(from: self, source: .deselectChapters, customTitle: PaidFeature.deselectChapters.tier == .plus ? L10n.skipChaptersPlusPrompt : L10n.skipChaptersPatronPrompt)
            return
        }

        isTogglingChapters.toggle()
        chaptersTable.reloadSections([0], with: .automatic)
        header.isTogglingChapters = isTogglingChapters
        header.update()
        updateSize()
        playbackManager.playableChaptersUpdated()

        if isTogglingChapters {
            numberOfDeselectedChapters = playbackManager.chapterCount(onlyPlayable: true)
            PlaybackManager.shared.trackChapterEvent(.deselectChaptersToggledOn)
        } else {
            numberOfDeselectedChapters -= playbackManager.chapterCount(onlyPlayable: true)
            PlaybackManager.shared.trackChapterEvent(.deselectChaptersToggledOff, properties: ["number_of_deselected_chapters": numberOfDeselectedChapters])
        }
    }
}
