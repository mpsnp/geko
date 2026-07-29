import XCTest
@testable import GekoCore

final class LinkableDependenciesMetricsTests: XCTestCase {
    func test_snapshotAggregatesCallsComputationsAndCacheHits() {
        let subject = LinkableDependenciesMetrics()

        subject.recordCall()
        subject.recordCall()
        subject.recordComputation(durationNanoseconds: 10)
        subject.recordComputation(durationNanoseconds: 25)
        subject.recordCacheHit()

        XCTAssertEqual(
            subject.snapshot(),
            LinkableDependenciesMetricsSnapshot(
                calls: 2,
                computations: 2,
                cacheHits: 1,
                totalComputationNanoseconds: 35,
                maximumComputationNanoseconds: 25
            )
        )
    }

    func test_debugDescriptionFormatsAggregateDurations() {
        let snapshot = LinkableDependenciesMetricsSnapshot(
            calls: 2,
            computations: 2,
            cacheHits: 1,
            totalComputationNanoseconds: 35,
            maximumComputationNanoseconds: 25
        )

        XCTAssertEqual(
            snapshot.debugDescription,
            "calls=2 computations=2 cacheHits=1 total=0.000000035s average=0.000000018s max=0.000000025s"
        )
    }

    func test_debugDescriptionUsesZeroAverageWithoutComputations() {
        let snapshot = LinkableDependenciesMetricsSnapshot(
            calls: 0,
            computations: 0,
            cacheHits: 0,
            totalComputationNanoseconds: 0,
            maximumComputationNanoseconds: 0
        )

        XCTAssertEqual(
            snapshot.debugDescription,
            "calls=0 computations=0 cacheHits=0 total=0.000000000s average=0.000000000s max=0.000000000s"
        )
    }
}
