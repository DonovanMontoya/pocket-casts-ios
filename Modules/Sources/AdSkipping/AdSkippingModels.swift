import Foundation

/// One recognized stretch of speech, on the downloaded file's timeline.
public struct TranscriptChunk: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A time range believed to be advertising.
public struct AdSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Double
    public var reason: String
    public var provider: String
    public var model: String

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double,
        reason: String,
        provider: String,
        model: String
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.confidence = confidence
        self.reason = reason
        self.provider = provider
        self.model = model
    }

    /// Finite, forward, on the timeline, with a probability-like confidence.
    var isValid: Bool {
        start.isFinite && end.isFinite && confidence.isFinite && start >= 0 && end > start && (0...1).contains(confidence)
    }
}

public enum AdSkippingError: Error, LocalizedError, Equatable {
    case apiKeyMissing
    case unsupportedResponse
    case transcriptionUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            "Add an OpenAI API key to find ads."
        case .unsupportedResponse:
            "The ad service returned an unexpected response."
        case .transcriptionUnavailable(let message):
            message
        }
    }
}
