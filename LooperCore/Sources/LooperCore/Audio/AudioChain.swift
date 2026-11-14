import Foundation

/// One piece of audio in the output timeline.
public struct AudioPlacement: Equatable, Sendable {
    /// Which item (for a playlist: which song) plays.
    public let itemIndex: Int
    /// Output time where it starts, in seconds.
    public let start: Double
    /// How much of the item plays, from its beginning (shorter than the item when the
    /// last piece is trimmed to end with the video).
    public let length: Double
    /// Composition track, 0 or 1. Neighbours alternate so they can overlap.
    public let track: Int
    /// Crossfade with the previous piece (0 for the first).
    public let fadeIn: Double
    /// Crossfade with the next piece (0 for the last).
    public let fadeOut: Double

    public var end: Double { start + length }
}

/// Lays items end to end to fill a duration, overlapping neighbours by a crossfade.
///
/// Used for both the ambient bed (one item repeated: the overlap hides the wrap) and the
/// playlist (songs in order, cycling back to the first). Two tracks alternate so each
/// overlap has the outgoing piece on one track and the incoming one on the other.
public enum AudioChain {
    public static func placements(itemDurations: [Double], crossfade: Double, fill total: Double) -> [AudioPlacement] {
        guard !itemDurations.isEmpty, itemDurations.allSatisfy({ $0 > 0 }), total > 0 else { return [] }
        let count = itemDurations.count
        // Overlap between piece k and k+1: the requested crossfade, but never more than
        // half of either, so a piece is never overlapped on both sides at once.
        func overlap(_ k: Int) -> Double {
            min(max(crossfade, 0), itemDurations[k % count] / 2, itemDurations[(k + 1) % count] / 2)
        }

        var result: [AudioPlacement] = []
        var start = 0.0
        var k = 0
        while start < total {
            let duration = itemDurations[k % count]
            let length = min(duration, total - start)
            let isLast = start + duration >= total
            result.append(AudioPlacement(
                itemIndex: k % count, start: start, length: length, track: k % 2,
                fadeIn: k == 0 ? 0 : overlap(k - 1),
                fadeOut: isLast ? 0 : overlap(k)))
            if isLast { break }
            start += duration - overlap(k)
            k += 1
        }
        return result
    }
}
