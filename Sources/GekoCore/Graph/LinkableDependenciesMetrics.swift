import Foundation

struct LinkableDependenciesMetricsSnapshot: Equatable {
    let calls: Int
    let computations: Int
    let cacheHits: Int
    let totalComputationNanoseconds: UInt64
    let maximumComputationNanoseconds: UInt64
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
