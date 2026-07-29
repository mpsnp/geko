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
}
