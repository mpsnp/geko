import Foundation

struct LinkableDependenciesMetricsSnapshot: Equatable, CustomDebugStringConvertible {
    let calls: Int
    let computations: Int
    let cacheHits: Int
    let totalComputationNanoseconds: UInt64
    let maximumComputationNanoseconds: UInt64

    var debugDescription: String {
        let averageNanoseconds = computations == 0
            ? 0
            : Double(totalComputationNanoseconds) / Double(computations)

        return [
            "calls=\(calls)",
            "computations=\(computations)",
            "cacheHits=\(cacheHits)",
            "total=\(Self.seconds(Double(totalComputationNanoseconds)))s",
            "average=\(Self.seconds(averageNanoseconds))s",
            "max=\(Self.seconds(Double(maximumComputationNanoseconds)))s",
        ].joined(separator: " ")
    }

    private static func seconds(_ nanoseconds: Double) -> String {
        String(format: "%.9f", nanoseconds / 1_000_000_000)
    }
}

final class LinkableDependenciesMetrics {
    private let lock = NSLock()
    private var calls = 0
    private var computations = 0
    private var cacheHits = 0
    private var totalComputationNanoseconds: UInt64 = 0
    private var maximumComputationNanoseconds: UInt64 = 0

    func recordCall() {
        lock.lock()
        defer { lock.unlock() }

        calls += 1
    }

    func recordComputation(durationNanoseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        computations += 1
        totalComputationNanoseconds += durationNanoseconds
        maximumComputationNanoseconds = max(maximumComputationNanoseconds, durationNanoseconds)
    }

    func recordCacheHit() {
        lock.lock()
        defer { lock.unlock() }

        cacheHits += 1
    }

    func snapshot() -> LinkableDependenciesMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return LinkableDependenciesMetricsSnapshot(
            calls: calls,
            computations: computations,
            cacheHits: cacheHits,
            totalComputationNanoseconds: totalComputationNanoseconds,
            maximumComputationNanoseconds: maximumComputationNanoseconds
        )
    }
}
