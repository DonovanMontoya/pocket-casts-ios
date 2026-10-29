import Foundation

/// Classifies every transcript cue with OpenAI's Decisions API.
///
/// The whole transcript goes in once as shared input, and each cue gets a
/// short predicate question, so every cue is judged with the full episode as
/// context. Requests of up to 400 questions run in parallel.
public final class OpenAIDecisionsAdClassifier: Sendable {
    public let classificationModel: String

    private let endpoint: URL
    private let questionsPerRequest: Int
    private let maxConcurrentRequests: Int
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        model: String = "gpt-6-luna",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        questionsPerRequest: Int = 400,
        maxConcurrentRequests: Int = 4,
        session: URLSession = .shared,
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        classificationModel = model
        endpoint = baseURL.appending(path: "decisions")
        self.questionsPerRequest = min(max(questionsPerRequest, 1), 400)
        self.maxConcurrentRequests = max(maxConcurrentRequests, 1)
        self.transport = transport ?? { try await session.data(for: $0) }
    }

    static let guidance = """
    You review a podcast episode transcript to find advertising so a player can skip it.
    Each transcript line is one audio cue: an ID in brackets, its start time, then the words.
    Every question names one cue ID. Answer whether that cue is part of an advertisement or \
    promotional break: a sponsor read (including a host reading it in their own voice), a \
    pre-recorded or dynamically inserted ad, a promo for another podcast, show, or product, an \
    offer code or discount, or the short sign-off that closes an ad. Ads often open with a hook \
    (a question, a short scene, or a story teaser) before naming the product; the hook belongs to \
    the ad. A break usually runs until the episode's own hosts or story resume, so read the \
    surrounding cues to place both edges.
    Do not count the episode's own content: discussion, stories, listener mail, the show's \
    normal intro and outro, credits, the show telling listeners where to follow, rate, or listen \
    to this same show, or casual mentions of a brand that nobody is paying to promote.
    """

    /// The probability that each cue, in order, belongs to an ad.
    public func cueProbabilities(_ cues: [TranscriptChunk], apiKey: String) async throws -> [Double] {
        let input = Self.transcriptInput(cues)
        let cacheKey = "turtlepod-\(Self.stableHash(input))"
        let batches = stride(from: 0, to: cues.count, by: questionsPerRequest).map {
            $0..<min($0 + questionsPerRequest, cues.count)
        }

        var probabilities = [Double](repeating: 0, count: cues.count)
        try await withThrowingTaskGroup(of: (Range<Int>, [Double]).self) { group in
            var next = 0
            func enqueue() {
                guard next < batches.count else { return }
                let range = batches[next]
                next += 1
                group.addTask { [self] in
                    (range, try await self.probabilities(for: range, input: input, cacheKey: cacheKey, apiKey: apiKey))
                }
            }
            for _ in 0..<min(maxConcurrentRequests, batches.count) { enqueue() }
            while let (range, values) = try await group.next() {
                for (offset, value) in values.enumerated() {
                    probabilities[range.lowerBound + offset] = value
                }
                enqueue()
            }
        }
        return probabilities
    }

    static func cueID(_ index: Int) -> String {
        "c\(index)"
    }

    static func transcriptInput(_ cues: [TranscriptChunk]) -> String {
        cues.enumerated().map { index, cue in
            "[\(cueID(index))] \(timestamp(cue.start)) \(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
    }

    func requestPayload(for range: Range<Int>, input: String, cacheKey: String) -> [String: Any] {
        [
            "model": classificationModel,
            "input": [
                ["role": "developer", "content": Self.guidance],
                ["role": "user", "content": input]
            ],
            "questions": range.map { index in
                [
                    "type": "predicate",
                    "name": Self.cueID(index),
                    "instructions": "Is cue \(Self.cueID(index)) part of an advertisement or promotional break?"
                ]
            },
            "prompt_cache_key": cacheKey
        ]
    }

    private func probabilities(for range: Range<Int>, input: String, cacheKey: String, apiKey: String) async throws -> [Double] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestPayload(for: range, input: input, cacheKey: cacheKey))

        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [[String: Any]] else {
            throw AdSkippingError.unsupportedResponse
        }
        var byName: [String: Double] = [:]
        for answer in answers {
            guard let name = answer["name"] as? String else { continue }
            // A refused cue counts as content: never skip what the model wouldn't judge.
            if answer["type"] as? String == "predicate", let probability = answer["probability"] as? Double,
               probability.isFinite, (0...1).contains(probability) {
                byName[name] = probability
            } else {
                byName[name] = 0
            }
        }
        return try range.map { index in
            guard let probability = byName[Self.cueID(index)] else { throw AdSkippingError.unsupportedResponse }
            return probability
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw AdSkippingError.unsupportedResponse }
            if [429, 500, 502, 503, 504].contains(http.statusCode), attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String }
                throw NSError(domain: "OpenAIDecisions", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: message ?? "OpenAI Decisions request failed (HTTP \(http.statusCode))."
                ])
            }
            return data
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// FNV-1a, so the cache key is the same across launches.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// Turns per-cue ad probabilities into skip ranges on the audio timeline.
public enum CueAdSegmenter {
    public static func segments(
        cues: [TranscriptChunk],
        probabilities: [Double],
        threshold: Double = 0.5,
        referencedThreshold: Double = 0.8,
        edgeThreshold: Double = 0.25,
        edgeWindow: TimeInterval = 8,
        minimumBreak: TimeInterval = 4,
        missingFromReference: [Bool]? = nil,
        reason: String,
        provider: String,
        model: String
    ) -> [AdSegment] {
        guard cues.count == probabilities.count, !cues.isEmpty else { return [] }
        // With a reliable publisher transcript, audio it lacks needs far less evidence
        // and audio it contains needs more: publishers rarely transcribe inserted ads.
        let missing = missingFromReference ?? Array(repeating: false, count: cues.count)
        let hasReference = missingFromReference != nil && missing.contains(true)
        var isAd = probabilities.indices.map { index in
            probabilities[index] >= (missing[index] ? 0.1 : hasReference ? referencedThreshold : threshold)
        }

        // Hysteresis at the edges: an ad's opening hook or closing tag often scores
        // lower than its body. Pull in nearby doubtful cues, never across content.
        let confirmed = isAd
        for index in cues.indices where confirmed[index] {
            let startsRun = index == 0 || !confirmed[index - 1]
            let endsRun = index == cues.count - 1 || !confirmed[index + 1]
            if startsRun {
                var earliest: Int?
                var probe = index - 1
                while probe >= 0, cues[index].start - cues[probe].start <= edgeWindow, !confirmed[probe] {
                    if probabilities[probe] >= edgeThreshold || missing[probe] { earliest = probe }
                    // Transcribed by the publisher and doubted by the model: that's the show.
                    else if hasReference { break }
                    probe -= 1
                }
                if let earliest { for fill in earliest..<index { isAd[fill] = true } }
            }
            if endsRun {
                var latest: Int?
                var probe = index + 1
                while probe < cues.count, cues[probe].end - cues[index].end <= edgeWindow, !confirmed[probe] {
                    if probabilities[probe] >= edgeThreshold || missing[probe] { latest = probe }
                    // Transcribed by the publisher and doubted by the model: that's the show.
                    else if hasReference { break }
                    probe += 1
                }
                if let latest { for fill in (index + 1)...latest { isAd[fill] = true } }
            }
        }

        // A short, doubtful run between two ad cues is the same break; playing a
        // few seconds of an ad back is worse than skipping one stray cue.
        var index = 0
        while index < cues.count {
            guard !isAd[index] else { index += 1; continue }
            var end = index
            while end < cues.count, !isAd[end] { end += 1 }
            if index > 0, end < cues.count,
               cues[end - 1].end - cues[index].start <= 8,
               probabilities[index..<end].allSatisfy({ $0 >= 0.15 }) {
                for fill in index..<end { isAd[fill] = true }
            }
            index = end
        }

        var segments: [AdSegment] = []
        var runStart: Int?
        func close(_ end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            // Score the break by the cues that cleared the threshold; doubtful edges and
            // holes pulled in around them must not drag a confident ad below the skip bar.
            let core = (start..<end).filter { confirmed[$0] }
            // Audio missing from a reliable publisher transcript is strong evidence on its own.
            let evidence = (core.isEmpty ? Array(start..<end) : core).map {
                missing[$0] ? max(probabilities[$0], 0.9) : probabilities[$0]
            }
            let confidence = evidence.reduce(0, +) / Double(evidence.count)
            segments.append(AdSegment(start: cues[start].start, end: cues[end - 1].end, confidence: confidence,
                                      reason: reason, provider: provider, model: model))
        }
        for position in cues.indices {
            if isAd[position] {
                // A long silence between ad cues still separates two breaks.
                if runStart != nil, cues[position].start - cues[position - 1].end > 3 {
                    close(position)
                }
                if runStart == nil { runStart = position }
            } else {
                close(position)
            }
        }
        close(cues.count)

        // A few seconds flagged on their own, away from any real break, is more
        // often a host joking about ads than an ad. Next to a break, it's the segue.
        let breaks = segments.filter { $0.end - $0.start >= minimumBreak }
        return segments.filter { segment in
            segment.end - segment.start >= minimumBreak || breaks.contains {
                $0.start - segment.end <= 10 && segment.start - $0.end <= 10
            }
        }
    }
}
