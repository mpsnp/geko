import GekoCache
import GekoGraphTesting
import GekoSupportTesting
import ProjectDescription
import XCTest

@testable import GekoKit

final class CacheWarmServiceTests: GekoUnitTestCase {
    func test_consumePipeline_neverBuildsArtifactsAndGeneratesOnlyFinalProject() throws {
        let tasks = try CacheWarmService().pipelineTasks(
            config: .test(),
            profile: .test(),
            cacheOutputType: .xcframework,
            destination: .simulator,
            ignoreRemoteCache: true,
            noOpen: true,
            cacheOnly: true
        )

        XCTAssertFalse(tasks.contains { $0 is CacheArchivingPipelineTask })
        XCTAssertFalse(tasks.contains { $0 is SwiftModuleCachingTask })
        XCTAssertEqual(tasks.filter { $0 is GenerateCacheGraphTask }.count, 1)
        XCTAssertEqual(tasks.filter { $0 is CacheGraphMutatingTask }.count, 1)
        XCTAssertTrue(tasks.last is GenerateCacheGraphTask)
    }

    func test_warmPipeline_keepsArtifactBuildingAndIntermediateGeneration() throws {
        let tasks = try CacheWarmService().pipelineTasks(
            config: .test(),
            profile: .test(),
            cacheOutputType: .xcframework,
            destination: .simulator,
            ignoreRemoteCache: true,
            noOpen: true,
            cacheOnly: false
        )

        XCTAssertTrue(tasks.contains { $0 is CacheArchivingPipelineTask })
        XCTAssertTrue(tasks.contains { $0 is SwiftModuleCachingTask })
        XCTAssertEqual(tasks.filter { $0 is GenerateCacheGraphTask }.count, 2)
    }
}
