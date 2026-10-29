import Foundation

/// Ad results per episode, one small JSON file each, kept on this device only.
/// A new download can carry different ads, so results are dropped with the file.
public final class AdSegmentStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var cache: [String: AdDetector.Result] = [:]

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "AdSkipping", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    public func result(for episodeUuid: String) -> AdDetector.Result? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[episodeUuid] { return cached }
        guard let data = try? Data(contentsOf: fileURL(episodeUuid)),
              let result = try? JSONDecoder().decode(AdDetector.Result.self, from: data) else { return nil }
        cache[episodeUuid] = result
        return result
    }

    public func save(_ result: AdDetector.Result, for episodeUuid: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: fileURL(episodeUuid), options: .atomic)
        lock.lock()
        cache[episodeUuid] = result
        lock.unlock()
    }

    public func remove(_ episodeUuid: String) {
        try? FileManager.default.removeItem(at: fileURL(episodeUuid))
        lock.lock()
        cache[episodeUuid] = nil
        lock.unlock()
    }

    private func fileURL(_ episodeUuid: String) -> URL {
        // Episode uuids are file-safe, but never let one escape the directory.
        let name = episodeUuid.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appending(path: "\(name).json")
    }
}
