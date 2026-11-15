import Foundation

/// Deterministic choices for the publish kit. The same seed must give the same text on
/// every run and every Swift version, so this avoids `Hasher` (randomised per process)
/// and the standard library's `random(in:using:)` (its algorithm isn't promised).
struct KitRandom: RandomNumberGenerator {
    private var state: UInt64

    /// A generator for one part of one version's kit, e.g. ("title", version id).
    init(seed: UInt64, _ parts: String...) {
        state = parts.reduce(seed) { $0 ^ Self.fnv1a($1) &* 0x9E37_79B9_7F4A_7C15 }
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[Int(next() % UInt64(items.count))]
    }

    /// A stable 64-bit hash of `text` (FNV-1a).
    static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }
}
