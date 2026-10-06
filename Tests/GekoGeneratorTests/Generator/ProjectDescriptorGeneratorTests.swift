import Foundation
import ProjectDescription
import GekoCore
import GekoCoreTesting
import GekoGraph
import GekoGraphTesting
import GekoSupport
import XcodeProj
import XCTest
@testable import GekoGenerator
@testable import GekoSupportTesting

final class ProjectDescriptorGeneratorTests: GekoUnitTestCase {
    var subject: ProjectDescriptorGenerator!

    override func setUp() {
        super.setUp()
        system.swiftVersionStub = { "5.2" }
        subject = ProjectDescriptorGenerator(enforceExplicitDependencies: false)
    }

    override func tearDown() {
        subject = nil
        super.tearDown()
    }

    func test_generate_testTargetIdentity() throws {
        // Given
        let temporaryPath = try temporaryPath()
        let app = Target.test(
            name: "App",
            platform: .iOS,
            product: .app
        )
        let test = Target.test(
            name: "Tests",
            platform: .iOS,
            product: .unitTests
        )
        let project = Project.test(
            path: temporaryPath,
            sourceRootPath: temporaryPath,
            name: "Project",
            targets: [app, test]
        )

        let testGraphTarget = GraphTarget(
            path: project.path,
            target: test,
            project: project
        )
        let appGraphTarget = GraphTarget(path: project.path, target: app, project: project)

        let graph = Graph.test(
            projects: [project.path: project],
            targets: [
                project.path: [
                    testGraphTarget.target.name: testGraphTarget.target,
                    appGraphTarget.target.name: appGraphTarget.target,
                ],
            ],
            dependencies: [
                .target(name: testGraphTarget.target.name, path: testGraphTarget.path): [
                    .target(name: appGraphTarget.target.name, path: appGraphTarget.path),
                ],
            ]
        )
        let graphTraverser = GraphTraverser(graph: graph)

        // When
        let generatedProject = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxproj = generatedProject.xcodeProj.pbxproj
        let pbxproject = try pbxproj.rootProject()
        let nativeTargets = pbxproj.nativeTargets
        let attributes = pbxproject?.targetAttributes ?? [:]
        let appTarget = nativeTargets.first(where: { $0.name == "App" })
        XCTAssertTrue(attributes.contains { attribute in

            guard case let .targetReference(testTargetID) = attribute.value["TestTargetID"] else {
                return false
            }

            return attribute.key.name == "Tests" && testTargetID == appTarget

        }, "Test target is missing from target attributes.")
    }

    func test_objectVersion_when_xcode11() throws {
        xcodeController.selectedVersionStub = .success(Version(11, 0, 0))

        // Given
        let temporaryPath = try temporaryPath()
        let project = Project.test(
            path: temporaryPath,
            name: "Project",
            targets: []
        )
        let graph = Graph.test(
            projects: [project.path: project]
        )
        let graphTraverser = GraphTraverser(graph: graph)

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxproj = got.xcodeProj.pbxproj
        XCTAssertEqual(pbxproj.objectVersion, 55)
        XCTAssertEqual(pbxproj.archiveVersion, Xcode.LastKnown.archiveVersion)
    }

    func test_objectVersion_when_xcode10() throws {
        xcodeController.selectedVersionStub = .success(Version(10, 2, 1))

        // Given
        let temporaryPath = try temporaryPath()
        let project = Project.test(
            path: temporaryPath,
            name: "Project",
            targets: []
        )
        let graph = Graph.test(
            projects: [project.path: project]
        )
        let graphTraverser = GraphTraverser(graph: graph)

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxproj = got.xcodeProj.pbxproj
        XCTAssertEqual(pbxproj.objectVersion, 55)
        XCTAssertEqual(pbxproj.archiveVersion, Xcode.LastKnown.archiveVersion)
    }

    func test_knownRegions() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let resources = [
            "resources/en.lproj/App.strings",
            "resources/en.lproj/Extension.strings",
            "resources/fr.lproj/App.strings",
            "resources/fr.lproj/Extension.strings",
            "resources/Base.lproj/App.strings",
            "resources/Base.lproj/Extension.strings",
        ]
        let project = Project.test(
            path: path,
            targets: [
                .test(resources: try resources.map {
                    .file(path: path.appending(try RelativePath(validating: $0)))
                }),
            ]
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        XCTAssertEqual(pbxProject.knownRegions, [
            "Base",
            "en",
            "fr",
        ])
    }

    func test_generate_setsDefaultKnownRegions() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let project = Project.test(
            path: path,
            targets: []
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        XCTAssertEqual(pbxProject.knownRegions, [
            "Base",
            "en",
        ])
    }

    func test_generate_setsCustomDefaultKnownRegions() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let project = Project.test(
            path: path,
            options: .options(defaultKnownRegions: ["Base", "en-GB"]),
            targets: []
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        XCTAssertEqual(pbxProject.knownRegions, ["Base", "en-GB"])
    }

    func test_generate_setsOrganizationName() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let project = Project.test(
            path: path,
            organizationName: "geko",
            targets: []
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        let attributes = try XCTUnwrap(pbxProject.attributes)
        XCTAssertEqual(attributes, [
            "BuildIndependentTargetsInParallel": "YES",
            "ORGANIZATIONNAME": "geko",
        ])
    }

    func test_generate_setsResourcesTagsName() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let resources: [ResourceFileElement] = [
            .file(path: "/", tags: ["fileTag", "commonTag"]),
            .folderReference(path: "/", tags: ["folderTag", "commonTag"]),
        ]
        let project = Project.test(
            path: path,
            targets: [.test(resources: resources)]
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        let attributes = try XCTUnwrap(pbxProject.attributes)
        XCTAssertEqual(attributes, [
            "BuildIndependentTargetsInParallel": "YES",
            "KnownAssetTags": .array(["fileTag", "folderTag", "commonTag"].sorted()),
        ])
    }

    func test_generate_setsDefaultDevelopmentRegion() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let project = Project.test(
            path: path,
            targets: []
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        XCTAssertEqual(pbxProject.developmentRegion, "en")
    }

    func test_generate_setsDevelopmentRegion() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let project = Project.test(
            path: path,
            options: .options(developmentRegion: "de"),
            targets: []
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        XCTAssertEqual(pbxProject.developmentRegion, "de")
    }

    func test_generate_setsLastUpgradeCheck() throws {
        // Given
        let path = try temporaryPath()
        let graph = Graph.test(path: path)
        let graphTraverser = GraphTraverser(graph: graph)
        let project = Project.test(
            path: path,
            targets: [],
            lastUpgradeCheck: .init(12, 5, 1)
        )

        // When
        let got = try subject.generate(project: project, graphTraverser: graphTraverser)

        // Then
        let pbxProject = try XCTUnwrap(try got.xcodeProj.pbxproj.rootProject())
        let attributes = try XCTUnwrap(pbxProject.attributes)
        XCTAssertEqual(attributes, [
            "BuildIndependentTargetsInParallel": "YES",
            "LastUpgradeCheck": "1251",
        ])
    }
    func test_generate_nativeXCFrameworkSettingsAreProjectWideAndPreserveUserSettings() throws {
        let (project, traverser, reference) = try xcframeworkProject()
        let generated = try subject.generate(project: project, graphTraverser: traverser)
        let pbxproj = generated.xcodeProj.pbxproj
        let pbxProject = try XCTUnwrap(try pbxproj.rootProject())
        let configurations = try XCTUnwrap(pbxProject.buildConfigurationList).buildConfigurations
        XCTAssertEqual(Set(configurations.map(\.name)), ["Debug", "Release"])
        for configuration in configurations {
            XCTAssertEqual(configuration.buildSettings["USER_PROJECT_SETTING"], .string("preserved"))
            for (key, value) in reference.settings.toBuildSettings() {
                XCTAssertEqual(configuration.buildSettings[key], value)
            }
        }
        XCTAssertEqual(pbxproj.nativeTargets.count, 2)
        for target in pbxproj.nativeTargets {
            for configuration in try XCTUnwrap(target.buildConfigurationList).buildConfigurations {
                XCTAssertFalse(configuration.buildSettings.keys.contains { $0.hasPrefix("GEKO_XCFRAMEWORK_") })
            }
        }
        let nativeReferences = pbxproj.fileReferences.filter { $0.path == "$(\(reference.settingName))" }
        XCTAssertEqual(nativeReferences.count, 1)
        XCTAssertEqual(nativeReferences.first?.lastKnownFileType, "wrapper.framework")
        XCTAssertFalse(pbxproj.fileReferences.contains { $0.lastKnownFileType == "wrapper.xcframework" })
        for target in pbxproj.nativeTargets {
            let phase = try XCTUnwrap(target.buildPhases.compactMap { $0 as? PBXFrameworksBuildPhase }.first)
            XCTAssertTrue(phase.files?.contains { $0.file === nativeReferences.first } == true)
        }
    }

    func test_generate_conflictingUserXCFrameworkSettingFailsInsteadOfOverwriting() throws {
        let (project, traverser, _) = try xcframeworkProject(settingOverride: .string("/wrong/Product.framework"))
        XCTAssertThrowsError(try subject.generate(project: project, graphTraverser: traverser)) { error in
            guard case XCFrameworkReferenceError.conflictingBuildSetting = error else {
                return XCTFail("Expected conflicting build setting, got \(error)")
            }
        }
    }

    func test_generate_identicalUserXCFrameworkSettingIsPreserved() throws {
        let (project, traverser, reference) = try xcframeworkProject(preserveGeneratedSetting: true)
        let generated = try subject.generate(project: project, graphTraverser: traverser)
        let pbxProject = try XCTUnwrap(try generated.xcodeProj.pbxproj.rootProject())
        for configuration in try XCTUnwrap(pbxProject.buildConfigurationList).buildConfigurations {
            for (key, value) in reference.settings.toBuildSettings() {
                XCTAssertEqual(configuration.buildSettings[key], value)
            }
        }
    }

    private func xcframeworkProject(
        settingOverride: SettingValue? = nil,
        preserveGeneratedSetting: Bool = false
    ) throws -> (Project, GraphTraverser, XCFrameworkReference) {
        let path = try temporaryPath()
        let container = path.appending(component: "Container.xcframework")
        let infoPlist = XCFrameworkInfoPlist.test(libraries: [
            .test(identifier: "ios", path: try RelativePath(validating: "Product.framework"), architectures: [.arm64]),
            .test(identifier: "simulator", path: try RelativePath(validating: "Product.framework"),
                  architectures: [.arm64, .x8664], platformVariant: .simulator),
        ])
        let reference = try XCFrameworkReference(path: container, infoPlist: infoPlist, sourceRootPath: path)
        var settings: [String: SettingValue] = ["USER_PROJECT_SETTING": "preserved"]
        let key = reference.settingName + "[sdk=iphoneos*]"
        if preserveGeneratedSetting {
            settings[key] = reference.settings[key]
        }
        if let settingOverride {
            settings[key] = settingOverride
        }
        let targets = [Target.test(name: "One"), Target.test(name: "Two")]
        let project = Project.test(path: path, sourceRootPath: path, name: "Project",
                                   settings: .test(base: settings, configurations: [.debug: nil, .release: nil]), targets: targets)
        let dependency = GraphDependency.testXCFramework(
            path: container, infoPlist: infoPlist,
            primaryBinaryPath: container.appending(try RelativePath(validating: "ios/Product.framework/Product")),
            linking: .static
        )
        let graph = Graph.test(
            projects: [path: project],
            targets: [path: Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })],
            dependencies: Dictionary(uniqueKeysWithValues: targets.map {
                (GraphDependency.target(name: $0.name, path: path), Set([dependency]))
            })
        )
        return (project, GraphTraverser(graph: graph), reference)
    }

}
