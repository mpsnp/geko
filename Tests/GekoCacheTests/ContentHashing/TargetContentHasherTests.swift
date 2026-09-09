import GekoCore
import GekoGraph
import GekoGraphTesting
import ProjectDescription
import XCTest
@testable import GekoCache
@testable import GekoSupportTesting

final class TargetContentHasherTests: GekoUnitTestCase {
    func test_projectTestabilityChangesTargetHash() throws {
        XCTAssertNotEqual(try hash(project: .test(base: ["ENABLE_TESTABILITY": "NO"])),
                          try hash(project: .test(base: ["ENABLE_TESTABILITY": "YES"])))
    }

    func test_projectSelectedConfigurationChangesTargetHash() throws {
        let disabled = Settings.test(configurations: [.debug: .init(settings: ["ENABLE_TESTABILITY": "NO"])])
        let enabled = Settings.test(configurations: [.debug: .init(settings: ["ENABLE_TESTABILITY": "YES"])])
        XCTAssertNotEqual(try hash(project: disabled), try hash(project: enabled))
    }

    func test_unselectedProjectConfigurationDoesNotChangeHash() throws {
        let a = Settings.test(configurations: [.debug: .init(settings: [:]), .release: .init(settings: ["OTHER_SWIFT_FLAGS": "-DA"])])
        let b = Settings.test(configurations: [.debug: .init(settings: [:]), .release: .init(settings: ["OTHER_SWIFT_FLAGS": "-DB"])])
        XCTAssertEqual(try hash(project: a), try hash(project: b))
    }

    func test_targetDebugBaseSettingsChangeDebugHash() throws {
        XCTAssertNotEqual(try hash(target: .test(baseDebug: ["ENABLE_TESTABILITY": "NO"], configurations: [.debug: .init(settings: [:])])),
                          try hash(target: .test(baseDebug: ["ENABLE_TESTABILITY": "YES"], configurations: [.debug: .init(settings: [:])])))
    }

    private func hash(project: Settings = .test(), target: Settings = .test()) throws -> String {
        let graphTarget = GraphTarget.test(
            target: .test(product: .framework, infoPlist: nil, entitlements: nil, settings: target),
            project: .test(settings: project)
        )
        return try TargetContentHasher(contentHasher: ContentHasher()).contentHash(
            for: graphTarget, cacheProfile: .test(configuration: "Debug")
        ).hash
    }
}
