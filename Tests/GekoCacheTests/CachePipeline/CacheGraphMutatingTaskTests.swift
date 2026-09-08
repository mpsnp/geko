import Foundation
import GekoCore
import GekoGraph
import GekoSupport
import ProjectDescription
import XCTest
@testable import GekoCache
@testable import GekoCacheTesting
@testable import GekoGraphTesting
@testable import GekoSupportTesting

final class CacheGraphMutatingTaskTests: GekoTestCase {
    func test_consume_whenParentCachedButDependencyMissing_preservesSafeSourceClosure() async throws {
        var context = try makeContext()
        let path = context.path
        let cache = try makeCache(cachedNames: ["A"])

        try await CacheGraphMutatingTask(state: .consume, cache: cache).run(context: &context)

        let graph = try XCTUnwrap(context.graph)
        XCTAssertEqual(Set(graph.targets[path, default: [:]].keys), ["App", "A", "B"])
        XCTAssertEqual(graph.dependencies[.target(name: "App", path: path)], [.target(name: "A", path: path)])
        XCTAssertEqual(graph.dependencies[.target(name: "A", path: path)], [.target(name: "B", path: path)])
    }

    func test_consume_whenOnlyLeafCached_replacesLeafAndKeepsParentSources() async throws {
        var context = try makeContext()
        let path = context.path
        let cache = try makeCache(cachedNames: ["B"])

        try await CacheGraphMutatingTask(state: .consume, cache: cache).run(context: &context)

        let graph = try XCTUnwrap(context.graph)
        XCTAssertEqual(Set(graph.targets[path, default: [:]].keys), ["App", "A"])
        XCTAssertEqual(graph.dependencies[.target(name: "App", path: path)], [.target(name: "A", path: path)])
        let dependencies = try XCTUnwrap(graph.dependencies[.target(name: "A", path: path)])
        XCTAssertEqual(dependencies.count, 1)
        guard case let .xcframework(binary) = try XCTUnwrap(dependencies.first) else {
            return XCTFail("A must depend on the cached XCFramework")
        }
        XCTAssertEqual(binary.path, try artifactPath())
    }

    func test_consume_whenCacheEmpty_preservesSourcesAndRemovesSyntheticCacheProject() async throws {
        var context = try makeContext()
        let path = context.path
        let cachePath = path.appending(component: CacheConstants.cacheProjectName)
        XCTAssertTrue(fileHandler.exists(cachePath))

        try await CacheGraphMutatingTask(state: .consume, cache: MockCacheStorage()).run(context: &context)

        let graph = try XCTUnwrap(context.graph)
        XCTAssertEqual(Set(graph.targets[path, default: [:]].keys), ["App", "A", "B"])
        XCTAssertEqual(graph.dependencies[.target(name: "App", path: path)], [.target(name: "A", path: path)])
        XCTAssertEqual(graph.dependencies[.target(name: "A", path: path)], [.target(name: "B", path: path)])
        XCTAssertNil(graph.projects[cachePath])
        XCTAssertNil(graph.targets[cachePath])
        XCTAssertNil(graph.dependencies[.target(name: CacheConstants.cacheProjectName, path: cachePath)])
        XCTAssertEqual(graph.workspace.projects, [path])
        XCTAssertEqual(graph.workspace.schemes.map(\.name), ["App"])
        XCTAssertFalse(fileHandler.exists(cachePath))
    }

    func test_consume_whenFocusedTargetCached_keepsFocusedTargetAndItsParentAsSources() async throws {
        var context = try makeContext(focusedTargets: ["B"])
        let path = context.path
        let cache = try makeCache(cachedNames: ["A", "B"])

        try await CacheGraphMutatingTask(state: .consume, cache: cache).run(context: &context)

        let graph = try XCTUnwrap(context.graph)
        XCTAssertEqual(Set(graph.targets[path, default: [:]].keys), ["App", "A", "B"])
        XCTAssertEqual(graph.dependencies[.target(name: "A", path: path)], [.target(name: "B", path: path)])
    }

    private func artifactPath() throws -> AbsolutePath {
        fixturePath(path: try RelativePath(validating: "MyFramework.xcframework"))
    }

    private func makeCache(cachedNames: Set<String>) throws -> MockCacheStorage {
        let artifact = try artifactPath()
        let cache = MockCacheStorage()
        cache.existsStub = { name, hash in cachedNames.contains(name) && hash == "hash-\(name)" }
        cache.fetchStub = { _, _ in artifact }
        return cache
    }

    private func makeContext(focusedTargets: Set<String> = ["App"]) throws -> CacheContext {
        let path = try temporaryPath()
        let cachePath = path.appending(component: CacheConstants.cacheProjectName)
        try fileHandler.createFolder(cachePath)
        let app = Target.test(name: "App", platform: .iOS, product: .app)
        let a = Target.test(name: "A", platform: .iOS, product: .framework)
        let b = Target.test(name: "B", platform: .iOS, product: .framework)
        let synthetic = Target.test(name: CacheConstants.cacheProjectName, platform: .iOS, product: .framework)
        let targets = [app, a, b]
        let graph = Graph.test(
            path: path,
            workspace: .test(path: path, projects: [path, cachePath], schemes: [
                .test(name: "App", buildAction: .test(targets: [.init(projectPath: path, name: "App")])),
                .test(name: CacheConstants.cacheProjectName, buildAction: .test(targets: [
                    .init(projectPath: cachePath, name: CacheConstants.cacheProjectName),
                ])),
            ]),
            projects: [
                path: .test(path: path, targets: targets),
                cachePath: .test(path: cachePath, name: CacheConstants.cacheProjectName, targets: [synthetic]),
            ],
            targets: [path: Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) }), cachePath: [synthetic.name: synthetic]],
            dependencies: [
                .target(name: "App", path: path): [.target(name: "A", path: path)],
                .target(name: "A", path: path): [.target(name: "B", path: path)],
                .target(name: "B", path: path): [],
                .target(name: synthetic.name, path: cachePath): [.target(name: "A", path: path)],
            ]
        )
        var sideTable = GraphSideTable()
        sideTable.workspace.focusedTargets = focusedTargets
        return CacheContext(
            path: path,
            config: .test(generationOptions: .test(enforceExplicitDependencies: true)),
            cacheProfile: .init(name: "Debug", configuration: "Debug", platforms: [.iOS: .options(arch: .arm64)]),
            outputType: .xcframework,
            destination: .simulator,
            userFocusedTargets: focusedTargets,
            focusDirectDependencies: false,
            focusTests: false,
            unsafe: false,
            dependenciesOnly: false,
            scheme: nil,
            graph: graph,
            sideTable: sideTable,
            hashesByCacheableTarget: ["A": "hash-A", "B": "hash-B"]
        )
    }
}
