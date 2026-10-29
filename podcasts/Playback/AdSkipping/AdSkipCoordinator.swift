import AdSkipping
import Combine
import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit

/// Finds ads in downloaded episodes and tells playback which ranges to skip.
///
/// Each new download is transcribed on device with Apple Speech, and the
/// transcript text is scored by OpenAI Decisions. Results are tied to that
/// download's file, so they are dropped when the download is deleted.
@MainActor
final class AdSkipCoordinator: ObservableObject {
    static let shared = AdSkipCoordinator()

    enum Status: Equatable {
        case waiting
        case finding(progress: Double)
        case found(adCount: Int)
        case failed(String)
    }

    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var hasAPIKey = AdSkipSettings.apiKey != nil

    let store = AdSegmentStore()

    private static let pendingKey = "AdSkipPendingEpisodes"
    private var pending: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingKey) }
    }
    private var worker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private var skippedSegmentIDs: Set<UUID> = []
    private var skipEpisodeUuid: String?
    private var boundaryTimer: Timer?
    private var validResults: [String: Bool] = [:]

    private init() {}

    /// Call once at launch.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Constants.Notifications.episodeDownloaded, object: nil, queue: .main) { notification in
            guard let uuid = notification.object as? String else { return }
            MainActor.assumeIsolated { AdSkipCoordinator.shared.episodeDownloaded(uuid) }
        })
        // Work cut short in the background picks up again here.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AdSkipCoordinator.shared.resume() }
        })
        resume()
    }

    var canFindAds: Bool {
        AdSkipSettings.isSupported && hasAPIKey
    }

    func setAPIKey(_ key: String?) {
        AdSkipSettings.apiKey = key
        hasAPIKey = AdSkipSettings.apiKey != nil
        resume()
    }

    // MARK: Finding ads

    func episodeDownloaded(_ uuid: String) {
        // A fresh download can carry different ads than the last one.
        forget(uuid)
        if AdSkipSettings.findOnDownload { enqueue([uuid]) }
    }

    /// Finds ads in one downloaded episode, replacing any earlier result.
    func findAds(in uuid: String) {
        forget(uuid)
        enqueue([uuid])
    }

    /// Finds ads in every downloaded episode that hasn't been checked yet.
    func findAdsInDownloadedEpisodes() {
        let uuids = DataManager.shared.findDownloadedEpisodes()
            .filter { $0 is Episode && store.result(for: $0.uuid) == nil }
            .map(\.uuid)
        enqueue(uuids)
    }

    func forget(_ uuid: String) {
        store.remove(uuid)
        validResults[uuid] = nil
        statuses[uuid] = nil
        pending.removeAll { $0 == uuid }
    }

    private func enqueue(_ uuids: [String]) {
        guard canFindAds else { return }
        var queue = pending
        for uuid in uuids where !queue.contains(uuid) {
            queue.append(uuid)
            statuses[uuid] = .waiting
        }
        pending = queue
        resume()
    }

    private func resume() {
        guard worker == nil, canFindAds, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        while let uuid = pending.first, canFindAds {
            let application = UIApplication.shared
            let work = Task { try await analyze(uuid) }
            let backgroundTask = application.beginBackgroundTask(withName: "Find ads") {
                // Out of background time: stop and retry when the app is next opened.
                work.cancel()
            }
            defer { application.endBackgroundTask(backgroundTask) }

            do {
                let count = try await work.value
                statuses[uuid] = .found(adCount: count)
                pending.removeAll { $0 == uuid }
            } catch is CancellationError {
                statuses[uuid] = .waiting
                return
            } catch {
                FileLog.shared.addMessage("AdSkip: finding ads in \(uuid) failed: \(error.localizedDescription)")
                statuses[uuid] = .failed(error.localizedDescription)
                pending.removeAll { $0 == uuid }
            }
        }
    }

    private func analyze(_ uuid: String) async throws -> Int {
        guard #available(iOS 26.0, *) else { throw AdSkippingError.transcriptionUnavailable("Finding ads needs iOS 26 or later.") }
        guard let episode = DataManager.shared.findEpisode(uuid: uuid),
              episode.downloaded(pathFinder: DownloadManager.shared),
              let apiKey = AdSkipSettings.apiKey else { return 0 }

        statuses[uuid] = .finding(progress: 0)
        let file = URL(fileURLWithPath: DownloadManager.shared.path(for: episode))
        let publisherTranscript = await Self.publisherTranscript(for: episode)
        let result = try await AdDetector().detectAds(
            inAudioFile: file,
            publisherTranscript: publisherTranscript,
            apiKey: apiKey,
            progress: { fraction in
                await MainActor.run { AdSkipCoordinator.shared.statuses[uuid] = .finding(progress: fraction) }
            }
        )
        try Task.checkCancellation()
        try store.save(result, for: uuid)
        validResults[uuid] = nil
        FileLog.shared.addMessage("AdSkip: found \(result.segments.count) ads in \(uuid) from \(result.cueCount) cues, publisher transcript used: \(result.usedPublisherTranscript)")
        return result.segments.count
    }

    /// The show's own transcript, when the feed provides one. Pocket Casts'
    /// generated transcripts are made from audio that includes ads, so they
    /// can't reveal where ads were inserted and are left out.
    private static func publisherTranscript(for episode: Episode) async -> String? {
        guard let metadata = try? await ShowInfoCoordinator.shared.loadTranscriptsMetadata(
            podcastUuid: episode.podcastUuid, episodeUuid: episode.uuid
        ), !metadata.transcripts.isEmpty, !metadata.isDisplayingGeneratedTranscript else { return nil }
        let manager = TranscriptManager(episodeUUID: episode.uuid, podcastUUID: episode.podcastUuid)
        guard let model = try? await manager.loadTranscript(), !manager.isDisplayingGeneratedTranscript else { return nil }
        return model.attributedText.string
    }

    // MARK: Playback

    /// The ad playing at `time` that hasn't been skipped yet in this listen.
    func adToSkip(episodeUuid: String, at time: TimeInterval) -> AdSegment? {
        guard AdSkipSettings.isEnabled else { return nil }
        if skipEpisodeUuid != episodeUuid {
            skipEpisodeUuid = episodeUuid
            skippedSegmentIDs.removeAll()
        }
        return unskippedAds(for: episodeUuid).first { time >= $0.start && time < $0.end - 0.5 }
    }

    func nextAdStart(episodeUuid: String, after time: TimeInterval) -> TimeInterval? {
        guard AdSkipSettings.isEnabled else { return nil }
        return unskippedAds(for: episodeUuid).map(\.start).filter { $0 > time }.min()
    }

    /// The ads that playback skips in this episode's current download, or nil when it hasn't been checked.
    func skippableAds(for episodeUuid: String) -> [AdSegment]? {
        currentResult(for: episodeUuid)?.segments.filter { $0.confidence >= AdSkipSettings.confidenceThreshold }
    }

    private func unskippedAds(for episodeUuid: String) -> [AdSegment] {
        (skippableAds(for: episodeUuid) ?? []).filter { !skippedSegmentIDs.contains($0.id) }
    }

    /// Results only count for the download they were made from. A file replaced
    /// since (deleted and downloaded again) can carry different ads.
    private func currentResult(for episodeUuid: String) -> AdDetector.Result? {
        guard let result = store.result(for: episodeUuid) else { return nil }
        if let valid = validResults[episodeUuid] { return valid ? result : nil }
        let path = DataManager.shared.findEpisode(uuid: episodeUuid).map { DownloadManager.shared.path(for: $0) }
        let modified = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        let valid = modified.map { $0 <= result.analyzedAt } ?? false
        validResults[episodeUuid] = valid
        if !valid { store.remove(episodeUuid) }
        return valid ? result : nil
    }

    func markSkipped(_ segment: AdSegment) {
        skippedSegmentIDs.insert(segment.id)
    }

    /// The playback tick runs about once a second; this lands the skip on the ad's first moment.
    func scheduleCheck(after delay: TimeInterval, _ check: @escaping @MainActor () -> Void) {
        boundaryTimer?.invalidate()
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.05), repeats: false) { _ in
            MainActor.assumeIsolated { check() }
        }
    }
}

extension PlaybackManager {
    /// Skips the ad at the current position, if any. Returns true when it skipped.
    /// Only downloaded files are checked: ad times come from transcribing that exact file.
    @MainActor
    func skipAdIfNeeded() -> Bool {
        guard let episode = currentEpisode as? Episode, !isSeeking,
              episode.downloaded(pathFinder: DownloadManager.shared) else { return false }
        let coordinator = AdSkipCoordinator.shared
        let time = currentTime
        if let ad = coordinator.adToSkip(episodeUuid: episode.uuid, at: time) {
            coordinator.markSkipped(ad)
            FileLog.shared.addMessage("AdSkip: skipping ad from \(time) to \(ad.end)")
            // Ad skips stay on this device: no seek analytics event, and not added
            // to the skipped-time stat that syncs to the Pocket Casts account.
            AnalyticsPlaybackHelper.shared.ignoreNextSeekEvent()
            seekTo(time: ad.end)
            if UIApplication.shared.applicationState == .active {
                Toast.show("Skipped ad", actions: [.init(title: "Undo") {
                    AnalyticsPlaybackHelper.shared.ignoreNextSeekEvent()
                    PlaybackManager.shared.seekTo(time: time)
                }], theme: .playerTheme)
            }
            return true
        }
        if let next = coordinator.nextAdStart(episodeUuid: episode.uuid, after: time), next - time < 1.5 {
            let rate = max(effects.playbackSpeed, 0.5)
            coordinator.scheduleCheck(after: (next - time) / rate + 0.05) {
                _ = PlaybackManager.shared.skipAdIfNeeded()
            }
        }
        return false
    }
}
