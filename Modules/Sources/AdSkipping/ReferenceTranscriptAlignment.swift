import Foundation

public struct TranscriptGap: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
}

public struct ReferenceComparison: Codable, Equatable, Sendable {
    public var matchedWordFraction: Double
    public var isReliable: Bool
    /// Possible insertions on the downloaded audio timeline; NOT confirmed ads.
    public var candidates: [TranscriptGap]
}

public enum ReferenceTranscriptAlignment {
    /// Unique five-word anchors, in order, tolerate changed ad durations without
    /// assuming a constant timestamp offset. Uncertain matches never create skips.
    public static func compare(_ transcript: [TranscriptChunk], toReferenceText referenceText: String) -> ReferenceComparison {
        let chunkWords = transcript.map { words($0.text) }
        let local = chunkWords.flatMap { $0 }
        let remote = words(referenceText)
        let width = 5
        let localIndex = uniquePhrases(local, width: width)
        let remoteIndex = uniquePhrases(remote, width: width)
        let pairs = localIndex.compactMap { phrase, position -> (Int, Int)? in
            guard let target = remoteIndex[phrase] else { return nil }
            return (position, target)
        }.sorted { $0.0 < $1.0 }

        // Longest increasing sequence keeps repeated/reordered passages from
        // anchoring to arbitrary locations. O(n log n), including long episodes.
        var tails: [Int] = []
        var previous = Array(repeating: -1, count: pairs.count)
        for index in pairs.indices {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].1 < pairs[index].1 { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var covered = Set<Int>()
        var referenceCovered = Set<Int>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            let pair = pairs[cursor]
            covered.formUnion(pair.0..<(pair.0 + width))
            referenceCovered.formUnion(pair.1..<(pair.1 + width))
            cursor = previous[cursor]
        }
        let fraction = local.isEmpty ? 0 : Double(covered.count) / Double(local.count)
        let referenceFraction = remote.isEmpty ? 0 : Double(referenceCovered.count) / Double(remote.count)
        let reliable = covered.count >= 30 && fraction >= 0.45 && referenceFraction >= 0.45
        var gaps: [TranscriptGap] = []
        var offset = 0
        if reliable {
            for (index, tokens) in chunkWords.enumerated() {
                defer { offset += tokens.count }
                let count = (offset..<(offset + tokens.count)).filter { covered.contains($0) }.count
                let chunk = transcript[index]
                guard tokens.count >= 5, Double(count) / Double(tokens.count) < 0.2,
                      chunk.start.isFinite, chunk.end.isFinite, chunk.start >= 0, chunk.end > chunk.start else { continue }
                if let last = gaps.last, chunk.start <= last.end + 1 {
                    gaps[gaps.count - 1].end = max(last.end, chunk.end)
                } else {
                    gaps.append(TranscriptGap(start: chunk.start, end: chunk.end))
                }
            }
        }
        return ReferenceComparison(matchedWordFraction: fraction,
                                   isReliable: reliable, candidates: gaps)
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func uniquePhrases(_ tokens: [String], width: Int) -> [String: Int] {
        guard tokens.count >= width else { return [:] }
        var positions: [String: Int] = [:]
        var duplicates = Set<String>()
        for index in 0...(tokens.count - width) {
            let phrase = tokens[index..<(index + width)].joined(separator: " ")
            if positions.updateValue(index, forKey: phrase) != nil { duplicates.insert(phrase) }
        }
        for phrase in duplicates { positions.removeValue(forKey: phrase) }
        return positions
    }
}

/// Skip ranges taken straight from a reliable comparison with an ad-free
/// publisher transcript: long stretches of audio the publisher never wrote down.
public enum ReferenceAdSegments {
    public static func segments(from gaps: [TranscriptGap], bridging: TimeInterval = 4, minimumDuration: TimeInterval = 8) -> [AdSegment] {
        var merged: [TranscriptGap] = []
        for gap in gaps.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, gap.start - last.end <= bridging {
                merged[merged.count - 1].end = max(last.end, gap.end)
            } else {
                merged.append(gap)
            }
        }
        return merged.filter { $0.end - $0.start >= minimumDuration }.map {
            AdSegment(start: $0.start, end: $0.end, confidence: 0.9,
                      reason: "This audio is missing from the publisher's transcript.",
                      provider: "publisher-transcript", model: "alignment")
        }
    }
}
