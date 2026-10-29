import Foundation

public enum AdSegmentMerger {
    public static func merge(_ segments: [AdSegment], gapTolerance: TimeInterval = 2) -> [AdSegment] {
        let sorted = segments
            .filter { $0.end > $0.start }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.end < rhs.end }
                return lhs.start < rhs.start
            }

        return sorted.reduce(into: []) { merged, segment in
            guard var last = merged.last else {
                merged.append(segment)
                return
            }

            if segment.start <= last.end + gapTolerance {
                last.end = max(last.end, segment.end)
                last.confidence = max(last.confidence, segment.confidence)
                if !segment.reason.isEmpty, !last.reason.contains(segment.reason) {
                    last.reason = [last.reason, segment.reason].filter { !$0.isEmpty }.joined(separator: " ")
                }
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
    }
}
