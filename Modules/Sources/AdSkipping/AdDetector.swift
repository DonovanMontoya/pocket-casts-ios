import Foundation

/// Finds the ads in one downloaded episode.
///
/// Apple Speech transcribes the file on device, so cue times match this exact
/// download (dynamically inserted ads differ between downloads). OpenAI
/// Decisions then scores each cue. When the publisher provides a transcript
/// that matches, audio missing from it counts as strong ad evidence, and those
/// gaps alone become the skips if the API can't be reached.
public struct AdDetector: Sendable {
    public struct Result: Codable, Equatable, Sendable {
        public var segments: [AdSegment]
        public var cueCount: Int
        public var usedPublisherTranscript: Bool
        public var analyzedAt: Date
    }

    private let classifier: OpenAIDecisionsAdClassifier
    private let gapTolerance: TimeInterval

    public init(classifier: OpenAIDecisionsAdClassifier = OpenAIDecisionsAdClassifier(), gapTolerance: TimeInterval = 2) {
        self.classifier = classifier
        self.gapTolerance = gapTolerance
    }

    @available(iOS 26.0, macOS 26.0, *)
    public func detectAds(
        inAudioFile audioFile: URL,
        publisherTranscript: String?,
        apiKey: String,
        progress: (@Sendable (_ fraction: Double) async -> Void)? = nil
    ) async throws -> Result {
        let transcript = try await AppleSpeechTranscriber().transcribe(audioFile: audioFile, progress: progress)
        return try await detectAds(in: transcript, publisherTranscript: publisherTranscript, apiKey: apiKey)
    }

    public func detectAds(in transcript: [TranscriptChunk], publisherTranscript: String?, apiKey: String) async throws -> Result {
        let cues = transcript
            .filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !cues.isEmpty else { throw AdSkippingError.unsupportedResponse }

        var referenceGaps: [TranscriptGap] = []
        if let publisherTranscript, !publisherTranscript.isEmpty {
            let comparison = ReferenceTranscriptAlignment.compare(cues, toReferenceText: publisherTranscript)
            if comparison.isReliable { referenceGaps = comparison.candidates }
        }
        let missing = cues.map { cue in referenceGaps.contains { cue.start < $0.end && cue.end > $0.start } }

        let segments: [AdSegment]
        do {
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AdSkippingError.apiKeyMissing }
            let probabilities = try await classifier.cueProbabilities(cues, apiKey: apiKey)
            segments = CueAdSegmenter.segments(
                cues: cues,
                probabilities: probabilities,
                missingFromReference: missing,
                reason: referenceGaps.isEmpty
                    ? "Identified as advertising."
                    : "Identified as advertising, checked against the publisher's transcript.",
                provider: "openai-decisions",
                model: classifier.classificationModel
            )
        } catch where !referenceGaps.isEmpty && !(error is CancellationError) {
            // Offline or no key: the publisher's ad-free transcript alone still finds the breaks.
            segments = ReferenceAdSegments.segments(from: referenceGaps)
        }
        return Result(
            segments: AdSegmentMerger.merge(segments.filter(\.isValid), gapTolerance: gapTolerance),
            cueCount: cues.count,
            usedPublisherTranscript: !referenceGaps.isEmpty,
            analyzedAt: Date()
        )
    }
}
