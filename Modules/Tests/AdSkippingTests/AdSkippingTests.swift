import Foundation
import XCTest
@testable import AdSkipping

final class AdSkippingTests: XCTestCase {
    /// The default skip threshold in the app.
    private let skipThreshold = 0.8

    /// One cue every five seconds.
    private func cues(_ count: Int) -> [TranscriptChunk] {
        (0..<count).map { TranscriptChunk(start: Double($0) * 5, end: Double($0) * 5 + 5, text: "cue \($0)") }
    }

    private func segments(_ probabilities: [Double], missing: [Bool]? = nil) -> [AdSegment] {
        CueAdSegmenter.segments(
            cues: cues(probabilities.count), probabilities: probabilities,
            missingFromReference: missing, reason: "test", provider: "test", model: "test"
        )
    }

    // MARK: CueAdSegmenter

    func testConfidentRunBecomesOneSegment() {
        let result = segments([0, 0, 0.9, 0.95, 0.9, 0, 0])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.start, 10)
        XCTAssertEqual(result.first?.end, 25)
        XCTAssertEqual(result.first?.confidence ?? 0, 0.9167, accuracy: 0.001)
    }

    func testDoubtfulHookNextToBreakIsPulledIn() {
        let result = segments([0, 0.05, 0.3, 0.9, 0.9, 0.3, 0.05, 0])
        XCTAssertEqual(result.map(\.start), [10])
        XCTAssertEqual(result.map(\.end), [30])
        // The doubtful edges widen the skip but don't lower its confidence below the core's.
        XCTAssertEqual(result.first?.confidence ?? 0, 0.9, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.first?.confidence ?? 0, skipThreshold)
    }

    func testShortDoubtfulHoleInsideBreakIsFilled() {
        let result = segments([0, 0.9, 0.9, 0.2, 0.9, 0.9, 0])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.start, 5)
        XCTAssertEqual(result.first?.end, 30)
    }

    func testContentBetweenBreaksIsNotFilled() {
        let result = segments([0.9, 0.9, 0.01, 0.9, 0.9])
        XCTAssertEqual(result.count, 2)
    }

    func testIsolatedShortRunIsDropped() {
        let cues = [
            TranscriptChunk(start: 0, end: 10, text: "story"),
            TranscriptChunk(start: 10, end: 12, text: "more ads, ha"),
            TranscriptChunk(start: 12, end: 30, text: "story")
        ]
        let result = CueAdSegmenter.segments(
            cues: cues, probabilities: [0, 0.9, 0], reason: "test", provider: "test", model: "test"
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testReferenceRaisesBarForTranscribedCuesAndLowersItForMissingOnes() {
        // 0.6 would pass alone, but the publisher transcribed it: content.
        // 0.12 would fail alone, but the publisher left it out: ad.
        let result = segments(
            [0, 0.6, 0.6, 0, 0, 0.12, 0.12, 0],
            missing: [false, false, false, false, false, true, true, false]
        )
        XCTAssertEqual(result.map(\.start), [25])
        XCTAssertEqual(result.map(\.end), [35])
        // The publisher's evidence carries the break past the default skip threshold.
        XCTAssertGreaterThanOrEqual(result.first?.confidence ?? 0, skipThreshold)
    }

    func testMismatchedLengthsReturnNothing() {
        XCTAssertTrue(CueAdSegmenter.segments(
            cues: cues(3), probabilities: [0.9], reason: "", provider: "", model: ""
        ).isEmpty)
    }

    // MARK: ReferenceAdSegments

    func testReferenceGapsBridgeAndDropSlivers() {
        let result = ReferenceAdSegments.segments(from: [
            TranscriptGap(start: 100, end: 130),
            TranscriptGap(start: 10, end: 40),
            TranscriptGap(start: 42, end: 60),
            TranscriptGap(start: 200, end: 203)
        ])
        XCTAssertEqual(result.map(\.start), [10, 100])
        XCTAssertEqual(result.map(\.end), [60, 130])
        XCTAssertEqual(result.first?.provider, "publisher-transcript")
    }

    // MARK: OpenAIDecisionsAdClassifier

    func testRequestShapeAndAnswerParsing() async throws {
        let recorder = RequestRecorder()
        let classifier = OpenAIDecisionsAdClassifier(questionsPerRequest: 2, transport: { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            await recorder.record(request, body: body)
            let questions = try XCTUnwrap(body["questions"] as? [[String: Any]])
            let answers: [[String: Any]] = questions.map { question in
                let name = question["name"] as! String
                if name == "c1" { return ["type": "refusal", "name": name] }
                return ["type": "predicate", "name": name, "probability": name == "c2" ? 0.9 : 0.1]
            }
            let data = try JSONSerialization.data(withJSONObject: ["answers": Array(answers.reversed())])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let probabilities = try await classifier.cueProbabilities(cues(3), apiKey: "key")
        XCTAssertEqual(probabilities, [0.1, 0, 0.9])

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first.path, "/v1/decisions")
        XCTAssertEqual(first.authorization, "Bearer key")
        XCTAssertEqual(first.model, "gpt-6-luna")
        XCTAssertEqual(first.roles, ["developer", "user"])
        XCTAssertTrue(first.transcript.contains("[c2] 0:00:10 cue 2"))
        // Every batch shares the transcript, so they share one cache key.
        let keys = Set(requests.map(\.cacheKey))
        XCTAssertEqual(keys.count, 1)
        XCTAssertLessThanOrEqual(keys.first?.count ?? 99, 64)
    }

    func testMissingAnswerIsAnError() async {
        let classifier = OpenAIDecisionsAdClassifier(transport: { request in
            let data = try JSONSerialization.data(withJSONObject: ["answers": []])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await classifier.cueProbabilities(cues(2), apiKey: "key")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? AdSkippingError, .unsupportedResponse)
        }
    }

    // MARK: AdDetector

    /// Cues of distinct words, so a publisher transcript can be aligned against them.
    private func wordCues(_ count: Int) -> [TranscriptChunk] {
        (0..<count).map { index in
            TranscriptChunk(start: Double(index) * 5, end: Double(index) * 5 + 5,
                            text: ["a", "b", "c", "d", "e", "f"].map { "w\(index)\($0)" }.joined(separator: " "))
        }
    }

    private func failingClassifier() -> OpenAIDecisionsAdClassifier {
        OpenAIDecisionsAdClassifier(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
    }

    func testFallsBackToPublisherTranscriptGapsWhenClassifierFails() async throws {
        let cues = wordCues(20)
        // The publisher left out 20-60 s, where the inserted ad sits.
        let publisher = cues.enumerated().filter { !(4..<12).contains($0.offset) }.map(\.element.text).joined(separator: " ")
        let result = try await AdDetector(classifier: failingClassifier())
            .detectAds(in: cues, publisherTranscript: publisher, apiKey: "bad")
        XCTAssertTrue(result.usedPublisherTranscript)
        XCTAssertEqual(result.segments.map(\.start), [20])
        XCTAssertEqual(result.segments.map(\.end), [60])
        XCTAssertEqual(result.segments.first?.provider, "publisher-transcript")
    }

    func testClassifierFailureWithoutPublisherTranscriptIsReported() async {
        do {
            _ = try await AdDetector(classifier: failingClassifier())
                .detectAds(in: cues(4), publisherTranscript: nil, apiKey: "bad")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual((error as NSError).code, 401)
        }
    }

    func testMissingKeyWithoutPublisherTranscriptIsReported() async {
        do {
            _ = try await AdDetector().detectAds(in: cues(4), publisherTranscript: nil, apiKey: " ")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? AdSkippingError, .apiKeyMissing)
        }
    }

    // MARK: AdSegmentStore

    func testStoreRoundTripsAndForgetsResults() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdSegmentStore(directory: directory)
        let result = AdDetector.Result(
            segments: [AdSegment(start: 1, end: 9, confidence: 0.9, reason: "", provider: "test", model: "test")],
            cueCount: 3, usedPublisherTranscript: false, analyzedAt: Date(timeIntervalSince1970: 0)
        )
        try store.save(result, for: "episode-1")
        XCTAssertEqual(AdSegmentStore(directory: directory).result(for: "episode-1"), result)
        store.remove("episode-1")
        XCTAssertNil(AdSegmentStore(directory: directory).result(for: "episode-1"))
    }
}

private struct RecordedRequest: Sendable {
    var path: String?
    var authorization: String?
    var model: String?
    var roles: [String]
    var transcript: String
    var cacheKey: String
}

private actor RequestRecorder {
    var requests: [RecordedRequest] = []

    nonisolated func record(_ request: URLRequest, body: [String: Any]) async {
        let input = body["input"] as? [[String: String]] ?? []
        let recorded = RecordedRequest(
            path: request.url?.path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            model: body["model"] as? String,
            roles: input.compactMap { $0["role"] },
            transcript: input.last?["content"] ?? "",
            cacheKey: body["prompt_cache_key"] as? String ?? ""
        )
        await append(recorded)
    }

    private func append(_ request: RecordedRequest) {
        requests.append(request)
    }
}
