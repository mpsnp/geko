import ProjectDescription
import GekoCore
import GekoGraph
import GekoLoader
import GekoSupport
import XCTest

import struct ProjectDescription.AbsolutePath

@testable import GekoDependencies
@testable import GekoDependenciesTesting
@testable import GekoSupportTesting

final class DependenciesControllerTests: GekoUnitTestCase {
    private var subject: DependenciesController!

    private var swiftPackageManagerInteractor: MockSwiftPackageManagerInteractor!
    private var dependenciesGraphController: MockDependenciesGraphController!

    override func setUp() {
        super.setUp()

        swiftPackageManagerInteractor = MockSwiftPackageManagerInteractor()
        dependenciesGraphController = MockDependenciesGraphController()

        subject = DependenciesController(
            swiftPackageManagerInteractor: swiftPackageManagerInteractor,
            dependenciesGraphController: dependenciesGraphController
        )
    }

    override func tearDown() {
        subject = nil

        swiftPackageManagerInteractor = nil

        super.tearDown()
    }

    // MARK: - Need fetch

    func test_needFetch_whenModuleMapIsRemoved() throws {
        let rootPath = try temporaryPath()
        let packagePath = rootPath.appending(components: ["Geko", ".build", "checkouts", "Package"])
        let moduleMapPath = packagePath.appending(component: "module.modulemap")
        try FileHandler.shared.touch(moduleMapPath)
        dependenciesGraphController.loadStub = { _ in
            .test(externalProjects: [packagePath: .test(
                path: packagePath,
                sourceRootPath: packagePath,
                targets: [.test(settings: .test(base: [
                    "MODULEMAP_FILE": "$(SRCROOT)/module.modulemap"
                ]))],
                projectType: .spm
            )])
        }
        swiftPackageManagerInteractor.needFetchResult = false

        XCTAssertFalse(try subject.needFetch(
            cocoapodsDependencies: nil, packageSettings: .test(), path: rootPath, cache: true
        ))

        try FileHandler.shared.delete(moduleMapPath)

        XCTAssertTrue(try subject.needFetch(
            cocoapodsDependencies: nil, packageSettings: .test(), path: rootPath, cache: true
        ))
    }

    func test_needFetch_whenGraphIsMissing() throws {
        dependenciesGraphController.loadStub = { _ in
            throw DependenciesGraphControllerError.dependenciesWerentFetched
        }
        swiftPackageManagerInteractor.needFetchResult = false

        XCTAssertTrue(try subject.needFetch(
            cocoapodsDependencies: nil, packageSettings: .test(), path: temporaryPath(), cache: true
        ))
    }

    func test_needFetch_withoutModuleMaps() throws {
        dependenciesGraphController.loadStub = { _ in .test(externalProjects: [:]) }
        swiftPackageManagerInteractor.needFetchResult = false

        XCTAssertFalse(try subject.needFetch(
            cocoapodsDependencies: nil, packageSettings: .test(), path: temporaryPath(), cache: true
        ))
    }

    // MARK: - Fetch

    func test_fetch_swiftPackageManger() async throws {
        // Given
        let rootPath = try temporaryPath()
        let dependenciesDirectoryPath =
            rootPath
            .appending(component: Constants.gekoDirectoryName)
            .appending(component: Constants.DependenciesDirectory.name)
        
        let stubbedPassthroughArguments = ["--replace-scm-with-registry"]
        let stubPackageSettings = PackageSettings.test(baseSettings: .default)

        swiftPackageManagerInteractor.installStub = { depDir, packageSettings, arguments, shouldUpdate, version in
            XCTAssertEqual(depDir, dependenciesDirectoryPath)
            XCTAssertEqual(packageSettings, packageSettings)
            XCTAssertEqual(arguments, stubbedPassthroughArguments)
            XCTAssertFalse(shouldUpdate)
            return .test()
        }

        swiftPackageManagerInteractor.needFetchResult = false

        // When
        let graphManifest = try await subject.fetch(
            at: rootPath,
            config: .default,
            passthroughArguments: stubbedPassthroughArguments,
            cocoapodsDependencies: nil,
            packageSettings: stubPackageSettings,
            repoUpdate: false,
            deployment: false
        )

        // Then
        XCTAssertEqual(graphManifest, .test())

        XCTAssertFalse(swiftPackageManagerInteractor.invokedClean)
        XCTAssertTrue(swiftPackageManagerInteractor.invokedInstall)
    }
    
    func test_fetch_swiftPackageManger_with_passthroughArguments() async throws {
        // Given
        let rootPath = try temporaryPath()
        let dependenciesDirectoryPath =
            rootPath
            .appending(component: Constants.gekoDirectoryName)
            .appending(component: Constants.DependenciesDirectory.name)
        
        let stubbedPassthroughArguments = ["--replace-scm-with-registry"]
        let stubPackageSettings = PackageSettings.test(baseSettings: .default)
        let config = Config(
            compatibleXcodeVersions: .all,
            cloud: nil,
            cache: nil,
            swiftVersion: nil,
            plugins: [],
            generationOptions: .options(
                resolveDependenciesWithSystemScm: false,
                disablePackageVersionLocking: false,
                staticSideEffectsWarningTargets: .all
            ),
            installOptions: .options(passthroughSwiftPackageManagerArguments: ["--test"]),
            preFetchScripts: [],
            preGenerateScripts: [],
            postGenerateScripts: [],
            cocoapodsUseBundler: false
        )
        
        swiftPackageManagerInteractor.installStub = { depDir, packageSettings, arguments, shouldUpdate, version in
            XCTAssertEqual(depDir, dependenciesDirectoryPath)
            XCTAssertEqual(packageSettings, packageSettings)
            XCTAssertEqual(arguments, ["--test"] + stubbedPassthroughArguments)
            XCTAssertFalse(shouldUpdate)
            return .test()
        }

        swiftPackageManagerInteractor.needFetchResult = false

        // When
        let graphManifest = try await subject.fetch(
            at: rootPath,
            config: config,
            passthroughArguments: stubbedPassthroughArguments,
            cocoapodsDependencies: nil,
            packageSettings: stubPackageSettings,
            repoUpdate: false,
            deployment: false
        )

        // Then
        XCTAssertEqual(graphManifest, .test())

        XCTAssertFalse(swiftPackageManagerInteractor.invokedClean)
        XCTAssertTrue(swiftPackageManagerInteractor.invokedInstall)
    }

    func test_save() throws {
        // Given
        let rootPath = try temporaryPath()

        let dependenciesGraph = GekoGraph.DependenciesGraph(
            externalDependencies: [
                "library": [.xcframework(path: "/library.xcframework", status: .required)],
                "anotherLibrary": [.project(target: "Target", path: "/anotherLibrary")],
            ],
            externalProjects: [
                "/anotherLibrary": .test()
            ],
            externalFrameworkDependencies: [:],
            tree: [:]
        )

        dependenciesGraphController.saveStub = { arg0, arg1 in
            XCTAssertEqual(arg0, dependenciesGraph)
            XCTAssertEqual(arg1, rootPath)
        }

        // When
        try subject.save(dependenciesGraph: dependenciesGraph, to: rootPath)

        // Then
        XCTAssertFalse(dependenciesGraphController.invokedClean)
        XCTAssertTrue(dependenciesGraphController.invokedSave)
    }

    func test_save_no_dependencies() throws {
        // Given
        let rootPath = try temporaryPath()

        dependenciesGraphController.saveStub = { arg0, arg1 in
            XCTAssertEqual(arg0, .none)
            XCTAssertEqual(arg1, rootPath)
        }

        // When
        try subject.save(dependenciesGraph: .none, to: rootPath)

        // Then
        XCTAssertFalse(dependenciesGraphController.invokedClean)
        XCTAssertTrue(dependenciesGraphController.invokedSave)
    }
}
