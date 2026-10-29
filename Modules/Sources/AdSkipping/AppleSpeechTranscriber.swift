import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(iOS 26.0, macOS 26.0, *)
public struct AppleSpeechTranscriber: Sendable {
    public init() {}

    public static func modelStatusMessage() async -> String {
        guard SpeechTranscriber.isAvailable else {
            return "Apple Speech transcription is not available on this device."
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            return "Apple Speech does not support English transcription on this device."
        }
        let transcriber = makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return "Ready on this device. English transcription runs on device."
        case .supported:
            return "English model will download when you first analyze an episode."
        case .downloading:
            return "English model is downloading. Transcription will start when it is ready."
        case .unsupported:
            return "Apple Speech cannot use the English model on this device."
        @unknown default:
            return "Apple Speech model status is unavailable."
        }
    }

    public func transcribe(
        audioFile: URL,
        progress: (@Sendable (_ fraction: Double) async -> Void)?
    ) async throws -> [TranscriptChunk] {
        guard SpeechTranscriber.isAvailable else {
            throw AdSkippingError.transcriptionUnavailable("Apple Speech transcription is unavailable on this device.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw AdSkippingError.transcriptionUnavailable("Apple Speech does not support English transcription on this device.")
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .unsupported else {
            throw AdSkippingError.transcriptionUnavailable("Apple Speech cannot use the English model on this device.")
        }
        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: audioFile)
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sampleRate
        guard duration > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AdSkippingError.unsupportedResponse
        }

        // Separate analyzers on separate stretches of the file run side by side,
        // which is several times faster than one pass. Each part reads a little past
        // its boundary so no word is cut, and keeps only cues that start inside it.
        let parts = Self.partCount(for: duration)
        // Seams go in the quietest moment near each even split, where the
        // recognizer would end a cue anyway, so both sides agree on the words.
        var boundaries = [0.0]
        for part in 1..<max(parts, 1) {
            boundaries.append(try Self.quietestMoment(in: audioFile, near: duration * Double(part) / Double(parts)))
        }
        boundaries.append(duration)
        let tally = ProgressTally(duration: duration, report: progress)
        let pieces = try await withThrowingTaskGroup(of: (Int, [TranscriptChunk]).self) { group in
            for part in 0..<parts {
                let range = boundaries[part]..<boundaries[part + 1]
                group.addTask {
                    let cues = try await RecognizerPool.shared.run {
                        try await Self.transcribe(
                            audioFile: audioFile,
                            locale: locale,
                            format: format,
                            from: max(range.lowerBound - Self.overlap, 0),
                            to: min(range.upperBound + Self.overlap, duration),
                            tally: tally
                        )
                    }
                    // A cue belongs to the part holding its midpoint.
                    return (part, cues.filter {
                        let middle = ($0.start + $0.end) / 2
                        return middle >= range.lowerBound && (middle < range.upperBound || part == parts - 1)
                    })
                }
            }
            var pieces = [[TranscriptChunk]](repeating: [], count: parts)
            for try await (part, cues) in group { pieces[part] = cues }
            return pieces
        }

        var transcript: [TranscriptChunk] = []
        for piece in pieces {
            for var cue in piece {
                guard let last = transcript.last, cue.start < last.end else {
                    transcript.append(cue)
                    continue
                }
                // The two sides of a seam heard the same words; keep the fuller version.
                if cue.end - cue.start > last.end - last.start {
                    transcript[transcript.count - 1] = cue
                } else if cue.end > last.end + 0.25 {
                    cue.start = last.end
                    transcript.append(cue)
                }
            }
        }
        guard !transcript.isEmpty else { throw AdSkippingError.unsupportedResponse }
        return transcript
    }

    private static let overlap: TimeInterval = 4

    /// The start of the quietest 100 ms within ten seconds of `time`.
    static func quietestMoment(in audioFile: URL, near time: TimeInterval) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: audioFile)
        let rate = file.processingFormat.sampleRate
        let searchStart = max(time - 10, 0)
        file.framePosition = AVAudioFramePosition(searchStart * rate)
        let frames = AVAudioFrameCount(min(20 * rate, Double(file.length - file.framePosition)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return time
        }
        try file.read(into: buffer, frameCount: frames)
        guard let samples = buffer.floatChannelData?[0] else { return time }
        let window = max(Int(rate * 0.1), 1)
        var best = (energy: Float.greatestFiniteMagnitude, offset: Int(time - searchStart) * Int(rate))
        var offset = 0
        while offset + window <= Int(buffer.frameLength) {
            var energy: Float = 0
            for index in offset..<(offset + window) { energy += samples[index] * samples[index] }
            if energy < best.energy { best = (energy, offset) }
            offset += window
        }
        return searchStart + Double(best.offset) / rate
    }

    /// Short episodes don't gain from splitting; long ones use the cores the device has.
    static func partCount(for duration: TimeInterval) -> Int {
        let byLength = Int(duration / 300)
        let byCores = max(ProcessInfo.processInfo.activeProcessorCount / 2, 1)
        return min(max(min(byLength, byCores), 1), 4)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }

    /// Transcribes one stretch of the file, with cue times on the full file's timeline.
    private static func transcribe(
        audioFile: URL,
        locale: Locale,
        format: AVAudioFormat,
        from start: TimeInterval,
        to end: TimeInterval,
        tally: ProgressTally
    ) async throws -> [TranscriptChunk] {
        let transcriber = makeTranscriber(locale: locale)
        // Keep the model loaded between episodes so the next analysis starts warm.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let reader = try AVAudioFile(forReading: audioFile)
        let sampleRate = reader.processingFormat.sampleRate
        let firstFrame = AVAudioFramePosition(start * sampleRate)
        let lastFrame = min(AVAudioFramePosition(end * sampleRate), reader.length)
        reader.framePosition = firstFrame
        guard let converter = AVAudioConverter(from: reader.processingFormat, to: format) else {
            throw AdSkippingError.unsupportedResponse
        }

        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        async let results = collectFinalResults(from: transcriber, tally: tally)
        do {
            try await analyzer.start(inputSequence: inputs)
            var position = firstFrame
            var isFirst = true
            while position < lastFrame {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(AVAudioFramePosition(sampleRate * 4), lastFrame - position))
                guard let source = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: count),
                      let output = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: AVAudioFrameCount(Double(count) * format.sampleRate / sampleRate) + 64
                      ) else { throw AdSkippingError.unsupportedResponse }
                try reader.read(into: source, frameCount: count)
                var supplied = false
                var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if supplied {
                        status.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    status.pointee = .haveData
                    return source
                }
                if let conversionError { throw conversionError }
                // Only the first buffer carries a time; later buffers follow on directly.
                continuation.yield(isFirst
                    ? AnalyzerInput(buffer: output, bufferStartTime: CMTime(seconds: start, preferredTimescale: 600))
                    : AnalyzerInput(buffer: output))
                isFirst = false
                position += AVAudioFramePosition(source.frameLength)
                if source.frameLength == 0 { break }
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func collectFinalResults(from transcriber: SpeechTranscriber, tally: ProgressTally) async throws -> [TranscriptChunk] {
        var chunks: [TranscriptChunk] = []
        var previousEnd: TimeInterval?
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            guard !text.isEmpty, start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            chunks.append(TranscriptChunk(start: start, end: end, text: text))
            await tally.add(end - (previousEnd ?? start))
            previousEnd = end
        }
        return chunks
    }
}

/// Caps live recognizers across every analysis in the app. iOS allows only a
/// few at once; when it refuses one, the cap shrinks and that part waits its turn.
private actor RecognizerPool {
    static let shared = RecognizerPool()

    private var limit = 4
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            await acquire()
            do {
                let result = try await work()
                release()
                return result
            } catch where Self.isRecognizerLimit(error) && attempt < 4 {
                attempt += 1
                limit = max(min(limit, inUse) - 1, 1)
                release()
                try await Task.sleep(for: .milliseconds(500 * attempt))
            } catch {
                release()
                throw error
            }
        }
    }

    private func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        // A waiter takes over the slot directly, unless the cap has shrunk below use.
        if inUse <= limit, !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            inUse -= 1
        }
    }

    private static func isRecognizerLimit(_ error: Error) -> Bool {
        let text = "\(error.localizedDescription) \(error)".lowercased()
        return text.contains("maximum number of recognizers")
    }
}

/// Sums progress from parallel parts and reports it in roughly 1% steps.
private actor ProgressTally {
    private let duration: TimeInterval
    private let report: (@Sendable (_ fraction: Double) async -> Void)?
    private var done: TimeInterval = 0
    private var reported = 0.0

    init(duration: TimeInterval, report: (@Sendable (_ fraction: Double) async -> Void)?) {
        self.duration = duration
        self.report = report
    }

    func add(_ seconds: TimeInterval) async {
        guard let report, seconds > 0 else { return }
        done += seconds
        let fraction = min(done / duration, 1)
        guard fraction - reported >= 0.01 else { return }
        reported = fraction
        await report(fraction)
    }
}
