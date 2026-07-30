import GekoCore
import GekoSupport
import ProjectDescription
import XCTest

@testable import GekoCache
@testable import GekoCacheTesting
@testable import GekoCoreTesting
@testable import GekoGraph
@testable import GekoGraphTesting
@testable import GekoSupportTesting

final class CacheXCFrameworkBuilderTests: GekoUnitTestCase {
    func test_build_usesProductNameForFrameworkAndTargetNameForXCFramework() async throws {
        // Given
        let xcodeBuildController = MockXcodeBuildController()
        let subject = CacheXCFrameworkBuilder(xcodeBuildController: xcodeBuildController)
        let workDirectory = try temporaryPath()
        let outputDirectory = try temporaryPath()
        let frameworkPath = workDirectory.appending(components: [
            "\(CacheConstants.cacheProjectName)-iOS",
            "GULUserDefaults.framework",
        ])
        try FileHandler.shared.createFolder(frameworkPath)
        let target = GraphTarget.test(
            target: .test(
                name: "GoogleUtilities-UserDefaults",
                product: .staticFramework,
                productName: "GULUserDefaults"
            )
        )

        // When
        try await subject.build(
            platforms: [.iOS],
            workDirectory: workDirectory,
            outputDirectory: outputDirectory,
            cacheableTarget: [target]
        )

        // Then
        XCTAssertTrue(xcodeBuildController.invokedCreateXCFramework)
        XCTAssertEqual(
            xcodeBuildController.invokedCreateXCFrameworkOutput,
            outputDirectory.appending(components: [
                CacheConstants.xcframeworkOutputFolderName,
                "GoogleUtilities-UserDefaults.xcframework",
            ])
        )
        guard
            let argument = xcodeBuildController.invokedCreateXCFrameworkArguments?.first,
            case let .framework(gotFrameworkPath) = argument
        else {
            return XCTFail("Expected a framework argument")
        }
        XCTAssertEqual(gotFrameworkPath, frameworkPath)
    }
}

final class CacheArtifactStoringTaskTests: GekoUnitTestCase {
    func test_run_usesTargetNameForXCFrameworkPath() async throws {
        // Given
        let workDirectory = try temporaryPath()
        let xcframeworkPath = workDirectory.appending(components: [
            CacheConstants.xcframeworkOutputFolderName,
            "GoogleUtilities-UserDefaults.xcframework",
        ])
        try FileHandler.shared.createFolder(xcframeworkPath)
        let target = GraphTarget.test(
            target: .test(
                name: "GoogleUtilities-UserDefaults",
                product: .staticFramework,
                productName: "GULUserDefaults"
            )
        )
        let storage = MockCacheStorage()
        var storedPaths: [AbsolutePath] = []
        storage.storeStub = { _, _, paths in
            storedPaths = paths
        }
        let subject = CacheArtifactStoringTask(cache: GekoCache.Cache(storages: [storage]))
        let context = ArchivingContext(
            graph: .test(),
            projectPath: workDirectory,
            workDirectory: workDirectory,
            cacheProfile: ProjectDescription.Cache.Profile(
                name: "Development",
                configuration: "Debug",
                platforms: [.iOS: .options(arch: .arm64)]
            ),
            buildTargetsWithHash: [(target, "hash")],
            schemesByPlatform: [:],
            outputType: .xcframework,
            destination: .simulator
        )

        // When
        try await subject.run(context: context)

        // Then
        XCTAssertEqual(storedPaths, [xcframeworkPath])
    }
}
