import Foundation
import GekoCore
import GekoGraph
import GekoGraphTesting
import ProjectDescription
import XcodeProj
import XCTest
@testable import GekoCoreTesting
@testable import GekoGenerator
@testable import GekoSupportTesting

final class LinkGeneratorPathTests: GekoUnitTestCase {
    func test_xcodeValue() {
        let path = try! AbsolutePath(validating: "/my-path")
        XCTAssertEqual(LinkGeneratorPath.absolutePath(path).xcodeValue(sourceRootPath: .root), "$(SRCROOT)/my-path")
        XCTAssertEqual(
            LinkGeneratorPath.string("$(DEVELOPER_FRAMEWORKS_DIR)").xcodeValue(sourceRootPath: .root),
            "$(DEVELOPER_FRAMEWORKS_DIR)"
        )
    }
}

final class LinkGeneratorTests: XCTestCase {
    var embedScriptGenerator: MockEmbedScriptGenerator!
    var subject: LinkGenerator!

    override func setUp() {
        super.setUp()
        embedScriptGenerator = MockEmbedScriptGenerator()
        subject = LinkGenerator(embedScriptGenerator: embedScriptGenerator)
    }

    override func tearDown() {
        subject = nil
        embedScriptGenerator = nil
        super.tearDown()
    }

    func test_linkGeneratorError_description() {
        XCTAssertEqual(
            LinkGeneratorError.missingProduct(name: "name").description,
            "Couldn't find a reference for the product name."
        )
        XCTAssertEqual(
            LinkGeneratorError.missingReference(path: try AbsolutePath(validating: "/")).description,
            "Couldn't find a reference for the file at path /."
        )
        XCTAssertEqual(
            LinkGeneratorError.missingConfigurationList(targetName: "target").description,
            "The target target doesn't have a configuration list."
        )
    }

    func test_linkGeneratorError_type() {
        XCTAssertEqual(LinkGeneratorError.missingProduct(name: "name").type, .bug)
        XCTAssertEqual(LinkGeneratorError.missingReference(path: try AbsolutePath(validating: "/")).type, .bug)
        XCTAssertEqual(LinkGeneratorError.missingConfigurationList(targetName: "target").type, .bug)
    }

    func test_generateEmbedPhase() throws {
        // Given
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.testFramework())
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework"
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let wakaFile = PBXFileReference()
        pbxproj.add(object: wakaFile)
        fileElements.products["Test"] = wakaFile
        let sourceRootPath = try AbsolutePath(validating: "/")
        embedScriptGenerator.scriptStub = .success(EmbedScript(
            script: "script",
            inputPaths: [try RelativePath(validating: "frameworks/A.framework")],
            outputPaths: ["output/A.framework"]
        ))

        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedEmbeddableFrameworksResult = dependencies

        // When
        try subject.generateEmbedPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let scriptBuildPhase: PBXShellScriptBuildPhase? = pbxTarget.buildPhases.first as? PBXShellScriptBuildPhase
        XCTAssertEqual(scriptBuildPhase?.name, "Embed Precompiled Frameworks")
        XCTAssertEqual(scriptBuildPhase?.shellScript, "script")
        XCTAssertEqual(scriptBuildPhase?.inputPaths, ["$(SRCROOT)/frameworks/A.framework"])
        XCTAssertEqual(scriptBuildPhase?.outputPaths, ["output/A.framework"])

        let embedBuildPhase = try XCTUnwrap(pbxTarget.embedFrameworksBuildPhases().first)
        XCTAssertEqual(embedBuildPhase.name, "Embed Frameworks")
        XCTAssertEqual(embedBuildPhase.dstPath, "")
        XCTAssertEqual(embedBuildPhase.dstSubfolderSpec, .frameworks)
        XCTAssertEqual(embedBuildPhase.files?.map(\.file), [
            wakaFile,
        ])
        XCTAssertEqual(embedBuildPhase.files?.compactMap(\.settings), [
            ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]],
        ])
    }

    func test_generateEmbedPhaseWithNoEmbeddableFrameworks() throws {
        // Given
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework"
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let wakaFile = PBXFileReference()
        pbxproj.add(object: wakaFile)
        fileElements.products["Test"] = wakaFile
        let sourceRootPath = try AbsolutePath(validating: "/")

        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedEmbeddableFrameworksResult = dependencies

        // When
        try subject.generateEmbedPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let scriptBuildPhase: PBXShellScriptBuildPhase? = pbxTarget.buildPhases.first as? PBXShellScriptBuildPhase
        XCTAssertNil(scriptBuildPhase)

        let embedBuildPhase = try XCTUnwrap(pbxTarget.embedFrameworksBuildPhases().first)
        XCTAssertEqual(embedBuildPhase.name, "Embed Frameworks")
        XCTAssertEqual(embedBuildPhase.dstPath, "")
        XCTAssertEqual(embedBuildPhase.dstSubfolderSpec, .frameworks)
        XCTAssertEqual(embedBuildPhase.files?.map(\.file), [
            wakaFile,
        ])
        XCTAssertEqual(embedBuildPhase.files?.compactMap(\.settings), [
            ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]],
        ])
    }

    func test_generateEmbedPhase_includesSymbols_when_nonTestTarget() throws {
        try Product.allCases.filter { !$0.testsBundle }.forEach { product in
            // Given

            var dependencies: Set<GraphDependencyReference> = []
            dependencies.insert(GraphDependencyReference.testFramework())
            dependencies.insert(GraphDependencyReference.product(
                target: "Test",
                productName: "Test.framework"
            ))
            let pbxproj = PBXProj()
            let (pbxTarget, target) = createTargets(product: product)
            let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
            let wakaFile = PBXFileReference()
            pbxproj.add(object: wakaFile)
            fileElements.products["Test"] = wakaFile
            let sourceRootPath = try AbsolutePath(validating: "/")
            embedScriptGenerator.scriptStub = .success(EmbedScript(
                script: "script",
                inputPaths: [try RelativePath(validating: "frameworks/A.framework")],
                outputPaths: ["output/A.framework"]
            ))
            let path = try AbsolutePath(validating: "/path/")
            let graphTraverser = MockGraphTraverser()
            graphTraverser.stubbedEmbeddableFrameworksResult = dependencies

            // When
            try subject.generateEmbedPhase(
                target: target,
                pbxTarget: pbxTarget,
                pbxproj: pbxproj,
                fileElements: fileElements,
                sourceRootPath: sourceRootPath,
                path: path,
                graphTraverser: graphTraverser
            )

            XCTAssert(
                embedScriptGenerator.scriptArgs.last?.2 == true,
                "Expected `includeSymbolsInFileLists == true` for product `\(product)`"
            )
        }
    }

    func test_generateEmbedPhase_doesNot_includesSymbols_when_testTarget() throws {
        for product in Product.allCases.filter(\.testsBundle) {
            // Given

            var dependencies: Set<GraphDependencyReference> = []
            dependencies.insert(GraphDependencyReference.testFramework())
            dependencies.insert(GraphDependencyReference.product(
                target: "Test",
                productName: "Test.framework"
            ))
            let pbxproj = PBXProj()
            let (pbxTarget, target) = createTargets(product: product)
            let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
            let wakaFile = PBXFileReference()
            pbxproj.add(object: wakaFile)
            fileElements.products["Test"] = wakaFile
            let sourceRootPath = try AbsolutePath(validating: "/")
            embedScriptGenerator.scriptStub = .success(EmbedScript(
                script: "script",
                inputPaths: [try RelativePath(validating: "frameworks/A.framework")],
                outputPaths: ["output/A.framework"]
            ))
            let path = try AbsolutePath(validating: "/path/")
            let graphTraverser = MockGraphTraverser()
            graphTraverser.stubbedEmbeddableFrameworksResult = dependencies

            // When
            try subject.generateEmbedPhase(
                target: target,
                pbxTarget: pbxTarget,
                pbxproj: pbxproj,
                fileElements: fileElements,
                sourceRootPath: sourceRootPath,
                path: path,
                graphTraverser: graphTraverser
            )

            XCTAssert(
                embedScriptGenerator.scriptArgs.last?.2 == false,
                "Expected `includeSymbolsInFileLists == false` for product `\(product)`"
            )
        }
    }

    func test_generateEmbedPhase_throws_when_aProductIsMissing() throws {
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework"
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let sourceRootPath = try AbsolutePath(validating: "/")
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedEmbeddableFrameworksResult = dependencies

        XCTAssertThrowsError(try subject.generateEmbedPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )) {
            XCTAssertEqual($0 as? LinkGeneratorError, LinkGeneratorError.missingProduct(name: "Test"))
        }
    }

    func test_generateEmbedPhase_setupEmbedFrameworksBuildPhase_whenXCFrameworkIsPresent() throws {
        // Given
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.testXCFramework(path: "/Frameworks/Test.xcframework", condition: .when([.ios])))
        let pbxproj = PBXProj()
        let pbxTarget = PBXNativeTarget(name: "Test")
        let target = Target.test(name: "Test", destinations: [.iPhone, .mac], product: .framework)
        let sourceRootPath = try AbsolutePath(validating: "/")

        let group = PBXGroup()
        pbxproj.add(object: group)

        let fileAbsolutePath = try AbsolutePath(validating: "/Frameworks/Test.xcframework")
        let fileElements = createFileElements(fileAbsolutePath: fileAbsolutePath)
        let nativeReference = PBXFileReference(
            sourceTree: .absolute,
            name: "Test.framework",
            lastKnownFileType: "wrapper.framework",
            path: "$(GEKO_XCFRAMEWORK_TEST)"
        )
        fileElements.elements[fileAbsolutePath] = nativeReference
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedEmbeddableFrameworksResult = dependencies

        // When
        try subject.generateEmbedPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let copyBuildPhase = try XCTUnwrap(pbxTarget.embedFrameworksBuildPhases().first)
        XCTAssertEqual(copyBuildPhase.name, "Embed Frameworks")
        let buildFiles = try XCTUnwrap(copyBuildPhase.files)
        XCTAssertEqual(buildFiles.map(\.file), [nativeReference])
        XCTAssertEqual(buildFiles.map { $0.file?.path }, ["$(GEKO_XCFRAMEWORK_TEST)"])
        XCTAssertEqual(buildFiles.map(\.platformFilter), ["ios"])
        XCTAssertEqual(pbxTarget.buildPhases.count, 1)
        XCTAssertEqual(buildFiles.map(\.settings), [
            ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]],
        ])
    }

    func test_setupRunPathSearchPath() throws {
        // Given
        let paths = [
            try AbsolutePath(validating: "/path/Dependencies/Frameworks/"),
            try AbsolutePath(validating: "/path/Dependencies/XCFrameworks/"),
        ].shuffled()
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        xcodeprojElements.config.buildSettings["LD_RUNPATH_SEARCH_PATHS"] = .array(["my/custom/path"])
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedRunPathSearchPathsResult = Set(paths)

        // When
        try subject.setupRunPathSearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertEqual(config.buildSettings["LD_RUNPATH_SEARCH_PATHS"]?.arrayValue, [
            "$(inherited)",
            "my/custom/path",
            "$(SRCROOT)/Dependencies/Frameworks",
            "$(SRCROOT)/Dependencies/XCFrameworks",
        ])
    }

    func test_setupFrameworkSearchPath() throws {
        // Given
        let dependencies = [
            GraphDependencyReference.testFramework(path: "/path/Dependencies/Frameworks/A.framework"),
            GraphDependencyReference.testFramework(path: "/path/OtherArtifacts/B.framework"),
            GraphDependencyReference.testLibrary(path: "/path/Dependencies/Libraries/libC.a"),
            GraphDependencyReference.testLibrary(path: "/path/Dependencies/Libraries/libD.a"),
            GraphDependencyReference.testXCFramework(path: "/path/Dependencies/XCFrameworks/E.xcframework"),
            GraphDependencyReference.testSDK(path: "/libc++.tbd"),
            GraphDependencyReference.testSDK(path: "/CloudKit.framework"),
            GraphDependencyReference.testSDK(path: "/XCTest.framework", source: .developer),
            GraphDependencyReference.testProduct(target: "Foo", productName: "Foo.framework"),
        ].shuffled()
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        xcodeprojElements.config.buildSettings["FRAMEWORK_SEARCH_PATHS"] = "my/custom/path"
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedSearchablePathDependenciesResult = Set(dependencies)
        // When
        try subject.setupFrameworkSearchPath(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            searchablePathDependencies: graphTraverser.searchablePathDependencies(path: path, name: target.name).sorted(),
            sharedRoot: FrameworkSearchPathsGenerator.rootPath(workspacePath: path)
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertEqual(config.buildSettings["FRAMEWORK_SEARCH_PATHS"]?.arrayValue, [
            "$(inherited)",
            "my/custom/path",
            "$(PLATFORM_DIR)/Developer/Library/Frameworks",
            "$(SRCROOT)/.geko/FrameworkSearchPaths",
            "$(SRCROOT)/Dependencies/Libraries",
        ])
    }

    func test_setupPlatformDependentSearchPath() throws {
        // Given
        let dependencies = [
            GraphDependencyReference.testFramework(path: "/path/Dependencies/Frameworks/A.framework"),
            GraphDependencyReference.testFramework(path: "/path/Dependencies/Frameworks/B.framework"),
            GraphDependencyReference.testLibrary(path: "/path/Dependencies/Libraries/libC.a"),
            GraphDependencyReference.testLibrary(path: "/path/Dependencies/Libraries/libD.a"),
            GraphDependencyReference.testSDK(path: "/libc++.tbd"),
            GraphDependencyReference.testSDK(path: "/CloudKit.framework"),
            GraphDependencyReference.testSDK(path: "/XCTest.framework", source: .developer),
            GraphDependencyReference.testProduct(target: "Foo", productName: "Foo.framework"),
            GraphDependencyReference.testXCFramework(
                path: "/path/Dependencies/XCFrameworks/E.xcframework",
                infoPlist: .test(libraries: [
                    .test(
                        identifier: "ios-arm64",
                        path: try! RelativePath(validating: "E.framework/E"),
                        mergeable: false,
                        architectures: [.arm64],
                        platform: .ios
                    ),
                    .test(
                        identifier: "ios-arm64_x86_64-simulator",
                        path: try! RelativePath(validating: "E.framework/E"),
                        mergeable: false,
                        architectures: [.arm64, .x8664],
                        platform: .ios,
                        platformVariant: .simulator
                    ),
                ]),
                linking: .static
            ),
            GraphDependencyReference.testXCFramework(
                path: "/path/OtherArtifacts/F.xcframework",
                infoPlist: .test(libraries: [
                    .test(
                        identifier: "ios-arm64",
                        path: try! RelativePath(validating: "F.framework/F"),
                        architectures: [.arm64],
                        platform: .ios
                    ),
                ])
            ),
            GraphDependencyReference.testXCFramework(
                path: "/path/Dependencies/Libraries/G.xcframework",
                infoPlist: .test(libraries: [
                    .test(
                        identifier: "ios-arm64",
                        path: try! RelativePath(validating: "libG.a"),
                        architectures: [.arm64],
                        platform: .ios
                    ),
                ]),
                linking: .static
            ),
        ]
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        xcodeprojElements.config.buildSettings["FRAMEWORK_SEARCH_PATHS"] = "my/custom/path"
        xcodeprojElements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]"] = "my/device/path"
        xcodeprojElements.config.buildSettings["LIBRARY_SEARCH_PATHS[sdk=iphoneos*]"] = "my/library/path"
        xcodeprojElements.config.buildSettings["SWIFT_INCLUDE_PATHS[sdk=iphoneos*]"] = "my/swift/path"
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedSearchablePathDependenciesResult = Set(dependencies)

        // When
        try subject.setupPlatformDependentFrameworkSearchPath(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            searchablePathDependencies: graphTraverser.searchablePathDependencies(path: path, name: target.name).sorted(),
            sharedRoot: FrameworkSearchPathsGenerator.rootPath(workspacePath: path)
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertEqual(config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]"]?.arrayValue, [
            "$(inherited)",
            "my/device/path",
            "$(SRCROOT)/.geko/FrameworkSearchPaths/iphoneos",
        ])
        XCTAssertEqual(config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]"]?.arrayValue, [
            "$(inherited)",
            "$(SRCROOT)/.geko/FrameworkSearchPaths/iphonesimulator",
        ])
        XCTAssertEqual(config.buildSettings["FRAMEWORK_SEARCH_PATHS"], "my/custom/path")
        XCTAssertEqual(config.buildSettings["LIBRARY_SEARCH_PATHS[sdk=iphoneos*]"]?.arrayValue, [
            "$(inherited)",
            "my/library/path",
            "$(SRCROOT)/Dependencies/Libraries/G.xcframework/ios-arm64",
        ])
        XCTAssertEqual(config.buildSettings["SWIFT_INCLUDE_PATHS[sdk=iphoneos*]"]?.arrayValue, [
            "$(inherited)",
            "my/swift/path",
            "$(SRCROOT)/Dependencies/Libraries/G.xcframework/ios-arm64",
        ])
    }

    func test_setupPlatformDependentSearchPath_selectsCatalystWithoutMacOSShadowing() throws {
        let dependencies = [GraphDependencyReference.testXCFramework(
            path: "/path/Bundle.xcframework",
            infoPlist: .test(libraries: [
                .test(identifier: "mac", path: try RelativePath(validating: "Product.framework"), platform: .macos),
                .test(identifier: "catalyst", path: try RelativePath(validating: "Product.framework/Product"),
                      platform: .ios, platformVariant: .maccatalyst),
            ])
        )]
        let elements = createXcodeprojElements()
        elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS"] = "my/common/path"
        elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=macosx*]"] = "my/mac/path"

        try setupSliceSearchPaths(dependencies, elements: elements)

        XCTAssertEqual(elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS"], "my/common/path")
        XCTAssertEqual(elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=macosx*]"]?.arrayValue, [
            "$(inherited)", "my/mac/path", "$(GEKO_FRAMEWORK_SEARCH_PATHS_MACOS_$(IS_MACCATALYST))",
        ])
        XCTAssertEqual(elements.config.buildSettings["GEKO_FRAMEWORK_SEARCH_PATHS_MACOS_NO"]?.arrayValue, [
            "$(SRCROOT)/.geko/FrameworkSearchPaths/macosx",
        ])
        XCTAssertEqual(elements.config.buildSettings["GEKO_FRAMEWORK_SEARCH_PATHS_MACOS_YES"]?.arrayValue, [
            "$(SRCROOT)/.geko/FrameworkSearchPaths/maccatalyst",
        ])
        XCTAssertNil(elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=maccatalyst*]"])
    }

    func test_setupPlatformDependentSearchPath_preservesPureMacOSPaths() throws {
        let dependencies = [GraphDependencyReference.testXCFramework(
            path: "/path/Bundle.xcframework",
            infoPlist: .test(libraries: [
                .test(identifier: "mac", path: try RelativePath(validating: "Product.framework"), platform: .macos),
            ])
        )]
        let elements = createXcodeprojElements()
        elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=macosx*]"] = "my/mac/path"

        try setupSliceSearchPaths(dependencies, elements: elements)

        XCTAssertEqual(elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=macosx*]"]?.arrayValue, [
            "$(inherited)", "my/mac/path", "$(SRCROOT)/.geko/FrameworkSearchPaths/macosx",
        ])
        XCTAssertNil(elements.config.buildSettings["GEKO_FRAMEWORK_SEARCH_PATHS_MACOS_NO"])
    }

    func test_setupPlatformDependentSearchPath_preservesCatalystArchiveSearchAndSwiftImports() throws {
        let dependencies = [GraphDependencyReference.testXCFramework(
            path: "/path/Bundle.xcframework",
            infoPlist: .test(libraries: [
                .test(identifier: "mac", path: try RelativePath(validating: "libProduct.a"), platform: .macos),
                .test(identifier: "catalyst", path: try RelativePath(validating: "libProduct.a"),
                      platform: .ios, platformVariant: .maccatalyst),
            ]),
            linking: .static
        )]
        let elements = createXcodeprojElements()
        for setting in ["LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"] {
            elements.config.buildSettings["\(setting)[sdk=macosx*]"] = "my/custom/path"
        }

        try setupSliceSearchPaths(dependencies, elements: elements)

        for setting in ["LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"] {
            XCTAssertEqual(elements.config.buildSettings["\(setting)[sdk=macosx*]"]?.arrayValue, [
                "$(inherited)", "my/custom/path", "$(GEKO_\(setting)_MACOS_$(IS_MACCATALYST))",
            ])
            XCTAssertEqual(elements.config.buildSettings["GEKO_\(setting)_MACOS_NO"]?.arrayValue, [
                "$(SRCROOT)/Bundle.xcframework/mac",
            ])
            XCTAssertEqual(elements.config.buildSettings["GEKO_\(setting)_MACOS_YES"]?.arrayValue, [
                "$(SRCROOT)/Bundle.xcframework/catalyst",
            ])
        }
        XCTAssertNil(elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=macosx*]"])
    }

    func test_setupPlatformDependentSearchPath_selectsDisjointArchitectureFrameworkImports() throws {
        let dependencies = [GraphDependencyReference.testXCFramework(
            path: "/path/Bundle.xcframework",
            infoPlist: .test(libraries: [
                .test(identifier: "arm", path: try RelativePath(validating: "Product.framework"),
                      architectures: [.arm64], platform: .ios, platformVariant: .simulator),
                .test(identifier: "intel", path: try RelativePath(validating: "Product.framework"),
                      architectures: [.x8664], platform: .ios, platformVariant: .simulator),
            ])
        )]
        let elements = createXcodeprojElements()
        elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]"] = "my/sdk/path"
        elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*][arch=arm64]"] = "my/arm/path"

        try setupSliceSearchPaths(dependencies, elements: elements)

        for arch in ["arm64", "x86_64"] {
            let actual = try XCTUnwrap(elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*][arch=\(arch)]"]?.arrayValue)
            var expected: Set<String> = [
                "$(inherited)", "my/sdk/path", "$(SRCROOT)/.geko/FrameworkSearchPaths/iphonesimulator",
                "$(SRCROOT)/.geko/FrameworkSearchPaths/iphonesimulator/\(arch)",
            ]
            if arch == "arm64" { expected.insert("my/arm/path") }
            XCTAssertEqual(Set(actual), expected)
        }
    }

    func test_setupPlatformDependentSearchPath_selectsCatalystArchitectureWithoutMacOSSlice() throws {
        let dependencies = [GraphDependencyReference.testXCFramework(
            path: "/path/Bundle.xcframework",
            infoPlist: .test(libraries: [
                .test(identifier: "mac", path: try RelativePath(validating: "Product.framework"), platform: .macos),
                .test(identifier: "arm", path: try RelativePath(validating: "Product.framework"),
                      architectures: [.arm64], platform: .ios, platformVariant: .maccatalyst),
                .test(identifier: "intel", path: try RelativePath(validating: "Product.framework"),
                      architectures: [.x8664], platform: .ios, platformVariant: .maccatalyst),
            ])
        )]
        let elements = createXcodeprojElements()

        try setupSliceSearchPaths(dependencies, elements: elements)

        for arch in ["arm64", "x86_64"] {
            let condition = "[sdk=macosx*][arch=\(arch)]"
            XCTAssertEqual(elements.config.buildSettings["FRAMEWORK_SEARCH_PATHS\(condition)"]?.arrayValue, [
                "$(inherited)", "$(GEKO_FRAMEWORK_SEARCH_PATHS_MACOS_$(IS_MACCATALYST))",
            ])
            XCTAssertEqual(elements.config.buildSettings["GEKO_FRAMEWORK_SEARCH_PATHS_MACOS_YES\(condition)"]?.arrayValue, [
                "$(SRCROOT)/.geko/FrameworkSearchPaths/maccatalyst",
                "$(SRCROOT)/.geko/FrameworkSearchPaths/maccatalyst/\(arch)",
            ])
            XCTAssertEqual(elements.config.buildSettings["GEKO_FRAMEWORK_SEARCH_PATHS_MACOS_NO\(condition)"]?.arrayValue, [
                "$(SRCROOT)/.geko/FrameworkSearchPaths/macosx",
            ])
        }
    }

    func test_setupPlatformDependentSearchPath_selectsDisjointArchitectureArchives() throws {
        let dependencies = [GraphDependencyReference.testXCFramework(
            path: "/path/Bundle.xcframework",
            infoPlist: .test(libraries: [
                .test(identifier: "arm", path: try RelativePath(validating: "libProduct.a"),
                      architectures: [.arm64], platform: .ios, platformVariant: .simulator),
                .test(identifier: "intel", path: try RelativePath(validating: "libProduct.a"),
                      architectures: [.x8664], platform: .ios, platformVariant: .simulator),
            ]),
            linking: .static
        )]
        let elements = createXcodeprojElements()

        try setupSliceSearchPaths(dependencies, elements: elements)

        for setting in ["LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"] {
            for (arch, identifier) in [("arm64", "arm"), ("x86_64", "intel")] {
                XCTAssertEqual(elements.config.buildSettings["\(setting)[sdk=iphonesimulator*][arch=\(arch)]"]?.arrayValue, [
                    "$(inherited)", "$(SRCROOT)/Bundle.xcframework/\(identifier)",
                ])
            }
            XCTAssertNil(elements.config.buildSettings["\(setting)[sdk=iphonesimulator*]"])
        }
    }

    func test_setupPlatformDependentSearchPath_selectsCatalystArchitectureArchives() throws {
        let dependencies = [GraphDependencyReference.testXCFramework(
            path: "/path/Bundle.xcframework",
            infoPlist: .test(libraries: [
                .test(identifier: "mac", path: try RelativePath(validating: "libProduct.a"), platform: .macos),
                .test(identifier: "arm", path: try RelativePath(validating: "libProduct.a"),
                      architectures: [.arm64], platform: .ios, platformVariant: .maccatalyst),
                .test(identifier: "intel", path: try RelativePath(validating: "libProduct.a"),
                      architectures: [.x8664], platform: .ios, platformVariant: .maccatalyst),
            ]),
            linking: .static
        )]
        let elements = createXcodeprojElements()

        try setupSliceSearchPaths(dependencies, elements: elements)

        for setting in ["LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS"] {
            for (arch, identifier) in [("arm64", "arm"), ("x86_64", "intel")] {
                let condition = "[sdk=macosx*][arch=\(arch)]"
                XCTAssertEqual(elements.config.buildSettings["\(setting)\(condition)"]?.arrayValue, [
                    "$(inherited)", "$(GEKO_\(setting)_MACOS_$(IS_MACCATALYST))",
                ])
                XCTAssertEqual(elements.config.buildSettings["GEKO_\(setting)_MACOS_YES\(condition)"]?.arrayValue, [
                    "$(SRCROOT)/Bundle.xcframework/\(identifier)",
                ])
                XCTAssertEqual(elements.config.buildSettings["GEKO_\(setting)_MACOS_NO\(condition)"]?.arrayValue, [
                    "$(SRCROOT)/Bundle.xcframework/mac",
                ])
            }
        }
    }

    func test_setupHeadersSearchPath() throws {
        let headersFolders = [try AbsolutePath(validating: "/headers")]
        let pbxproj = PBXProj()

        let pbxTarget = PBXNativeTarget(name: "Test")
        pbxproj.add(object: pbxTarget)

        let configurationList = XCConfigurationList(buildConfigurations: [])
        pbxproj.add(object: configurationList)
        pbxTarget.buildConfigurationList = configurationList

        let config = XCBuildConfiguration(name: "Debug")
        pbxproj.add(object: config)
        configurationList.buildConfigurations.append(config)

        let sourceRootPath = try AbsolutePath(validating: "/")
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesPublicHeadersFoldersResult = Set(headersFolders)

        try subject.setupHeadersSearchPath(
            target: target,
            pbxTarget: pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        let expected = ["$(inherited)", "$(SRCROOT)/headers"]
        XCTAssertEqual(config.buildSettings["HEADER_SEARCH_PATHS"]?.arrayValue, expected)
    }

    func test_setupHeadersSearchPaths_extendCustomSettings() throws {
        // Given
        let searchPaths = [
            try AbsolutePath(validating: "/path/to/libraries"),
            try AbsolutePath(validating: "/path/to/other/libraries"),
        ]
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        xcodeprojElements.config.buildSettings["HEADER_SEARCH_PATHS"] = "my/custom/path"
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesPublicHeadersFoldersResult = Set(searchPaths)

        // When
        try subject.setupHeadersSearchPath(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertEqual(config.buildSettings["HEADER_SEARCH_PATHS"]?.arrayValue, [
            "$(inherited)",
            "my/custom/path",
            "$(SRCROOT)/to/libraries",
            "$(SRCROOT)/to/other/libraries",
        ])
    }

    func test_setupHeadersSearchPaths_mergesDuplicates() throws {
        // Given
        let searchPaths = [
            try AbsolutePath(validating: "/path/to/libraries"),
            try AbsolutePath(validating: "/path/to/libraries"),
            try AbsolutePath(validating: "/path/to/libraries"),
        ]
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesPublicHeadersFoldersResult = Set(searchPaths)

        // When
        try subject.setupHeadersSearchPath(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertEqual(config.buildSettings["HEADER_SEARCH_PATHS"]?.arrayValue, [
            "$(inherited)",
            "$(SRCROOT)/to/libraries",
        ])
    }

    func test_setupHeadersSearchPath_throws_whenTheConfigurationListIsMissing() throws {
        let headersFolders = [try AbsolutePath(validating: "/headers")]
        let pbxproj = PBXProj()

        let pbxTarget = PBXNativeTarget(name: "Test")
        pbxproj.add(object: pbxTarget)
        let sourceRootPath = try AbsolutePath(validating: "/")
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesPublicHeadersFoldersResult = Set(headersFolders)

        XCTAssertThrowsError(try subject.setupHeadersSearchPath(
            target: target,
            pbxTarget: pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )) {
            XCTAssertEqual($0 as? LinkGeneratorError, LinkGeneratorError.missingConfigurationList(targetName: pbxTarget.name))
        }
    }

    func test_setupLibrarySearchPaths_multiplePaths() throws {
        // Given
        let searchPaths = [
            try AbsolutePath(validating: "/path/to/libraries"),
            try AbsolutePath(validating: "/path/to/other/libraries"),
        ]
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        let target = Target.test(product: .framework)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSearchPathsResult = Set(searchPaths)

        // When
        try subject.setupLibrarySearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        let expected = ["$(inherited)", "$(SRCROOT)/to/libraries", "$(SRCROOT)/to/other/libraries"]
        XCTAssertEqual(config.buildSettings["LIBRARY_SEARCH_PATHS"]?.arrayValue, expected)
        let expectedLdFlags = ["$(inherited)", "-L$(DT_TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)"]
        XCTAssertEqual(config.buildSettings["OTHER_LDFLAGS"]?.arrayValue, expectedLdFlags)
    }

    func test_setupLibrarySearchPaths_noPaths() throws {
        // Given
        let searchPaths: [AbsolutePath] = []
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        let target = Target.test(product: .staticLibrary)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSearchPathsResult = Set(searchPaths)

        // When
        try subject.setupLibrarySearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertNil(config.buildSettings["LIBRARY_SEARCH_PATHS"])
        XCTAssertNil(config.buildSettings["OTHER_LDFLAGS"])
    }

    func test_setupLibrarySearchPaths_noLibraryPaths_withSwiftToolchainLdFlag() throws {
        // Given: A dynamic framework with no library search paths gets the Swift toolchain
        // path added to OTHER_LDFLAGS so that auto-linked Swift compatibility libraries
        // can be found when linking with clang (ObjC-only targets)
        let searchPaths: [AbsolutePath] = []
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        let target = Target.test(product: .framework)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSearchPathsResult = Set(searchPaths)

        // When
        try subject.setupLibrarySearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertNil(config.buildSettings["LIBRARY_SEARCH_PATHS"])
        let expectedLdFlags = ["$(inherited)", "-L$(DT_TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)"]
        XCTAssertEqual(config.buildSettings["OTHER_LDFLAGS"]?.arrayValue, expectedLdFlags)
    }

    func test_setupLibrarySearchPaths_preservesExistingStringLdFlags() throws {
        // Given
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        xcodeprojElements.config.buildSettings["OTHER_LDFLAGS"] = "$(inherited) -ObjC"
        let target = Target.test(product: .framework)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSearchPathsResult = []

        // When
        try subject.setupLibrarySearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let expectedLdFlags = [
            "$(inherited) -ObjC",
            "-L$(DT_TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)",
        ]
        XCTAssertEqual(xcodeprojElements.config.buildSettings["OTHER_LDFLAGS"]?.arrayValue, expectedLdFlags)
    }

    func test_setupLibrarySearchPaths_doesNotDuplicateSwiftToolchainPath_inExistingStringLdFlags() throws {
        // Given
        let swiftToolchainSearchPath = "-L$(DT_TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)"
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        xcodeprojElements.config.buildSettings["OTHER_LDFLAGS"] = "$(inherited) -ObjC \(swiftToolchainSearchPath)"
        let target = Target.test(product: .framework)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSearchPathsResult = []

        // When
        try subject.setupLibrarySearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let expectedLdFlags = ["$(inherited) -ObjC \(swiftToolchainSearchPath)"]
        XCTAssertEqual(xcodeprojElements.config.buildSettings["OTHER_LDFLAGS"]?.arrayValue, expectedLdFlags)
    }

    func test_setupLibrarySearchPaths_preservesExistingArrayLdFlags_withoutDuplicatingSwiftToolchainPath() throws {
        // Given
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        xcodeprojElements.config.buildSettings["OTHER_LDFLAGS"] = .array(["$(inherited)", "-ObjC"])
        let target = Target.test(product: .framework)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSearchPathsResult = []

        // When
        try subject.setupLibrarySearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )
        try subject.setupLibrarySearchPaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let expectedLdFlags = [
            "$(inherited)",
            "-ObjC",
            "-L$(DT_TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)",
        ]
        XCTAssertEqual(xcodeprojElements.config.buildSettings["OTHER_LDFLAGS"]?.arrayValue, expectedLdFlags)
    }

    func test_setupSwiftIncludePaths_multiplePaths() throws {
        // Given
        let searchPaths = [
            try AbsolutePath(validating: "/path/to/libraries"),
            try AbsolutePath(validating: "/path/to/other/libraries"),
        ]
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSwiftIncludePathsResult = Set(searchPaths)

        // When
        try subject.setupSwiftIncludePaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        let expected = ["$(inherited)", "$(SRCROOT)/to/libraries", "$(SRCROOT)/to/other/libraries"]
        XCTAssertEqual(config.buildSettings["SWIFT_INCLUDE_PATHS"]?.arrayValue, expected)
    }

    func test_setupSwiftIncludePaths_noPaths() throws {
        // Given
        let searchPaths: [AbsolutePath] = []
        let sourceRootPath = try AbsolutePath(validating: "/path")
        let xcodeprojElements = createXcodeprojElements()
        let target = Target.test()
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLibrariesSwiftIncludePathsResult = Set(searchPaths)

        // When
        try subject.setupSwiftIncludePaths(
            target: target,
            pbxTarget: xcodeprojElements.pbxTarget,
            sourceRootPath: sourceRootPath,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let config = xcodeprojElements.config
        XCTAssertNil(config.buildSettings["SWIFT_INCLUDE_PATHS"])
    }

    func test_generateLinkingPhase() throws {
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.testFramework(path: "/test.framework"))
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework"
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let testFile = PBXFileReference()
        pbxproj.add(object: testFile)
        let wakaFile = PBXFileReference()
        pbxproj.add(object: wakaFile)
        fileElements.products["Test"] = wakaFile
        fileElements.elements[try AbsolutePath(validating: "/test.framework")] = testFile
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = dependencies

        try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: path,
            graphTraverser: graphTraverser
        )

        let buildPhase = try pbxTarget.frameworksBuildPhase()

        let testBuildFile: PBXBuildFile? = buildPhase?.files?.first
        let wakaBuildFile: PBXBuildFile? = buildPhase?.files?.last

        XCTAssertEqual(testBuildFile?.file, testFile)
        XCTAssertEqual(wakaBuildFile?.file, wakaFile)
    }

    func test_generateLinkingPhaseIncludesTransitiveDynamicFrameworks() throws {
        let projectPath = try AbsolutePath(validating: "/path")
        let (pbxTarget, target) = createTargets(product: .framework)
        let project = Project.test(path: projectPath, targets: [target])
        let imageSource = GraphDependency.testFramework(
            path: "/ImageSource.framework",
            binaryPath: "/ImageSource.framework/ImageSource",
            linking: .dynamic
        )
        let alamofireImage = GraphDependency.testFramework(
            path: "/AlamofireImage.framework",
            binaryPath: "/AlamofireImage.framework/AlamofireImage",
            linking: .dynamic
        )
        let alamofire = GraphDependency.testFramework(
            path: "/Alamofire.framework",
            binaryPath: "/Alamofire.framework/Alamofire",
            linking: .dynamic
        )
        let targetDependency = GraphDependency.target(name: target.name, path: projectPath)
        let graphTraverser = GraphTraverser(graph: .test(
            projects: [projectPath: project],
            targets: [projectPath: [target.name: target]],
            dependencies: [
                targetDependency: [imageSource],
                imageSource: [alamofireImage],
                alamofireImage: [alamofire],
            ]
        ))
        let pbxproj = PBXProj()
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let imageSourceFile = PBXFileReference(path: "ImageSource.framework")
        let alamofireImageFile = PBXFileReference(path: "AlamofireImage.framework")
        let alamofireFile = PBXFileReference(path: "Alamofire.framework")
        [imageSourceFile, alamofireImageFile, alamofireFile].forEach {
            pbxproj.add(object: $0)
        }
        fileElements.elements["/ImageSource.framework"] = imageSourceFile
        fileElements.elements["/AlamofireImage.framework"] = alamofireImageFile
        fileElements.elements["/Alamofire.framework"] = alamofireFile

        try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: projectPath,
            graphTraverser: graphTraverser
        )

        let files = try XCTUnwrap(pbxTarget.frameworksBuildPhase()?.files)
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.contains { $0.file === imageSourceFile })
        XCTAssertTrue(files.contains { $0.file === alamofireImageFile })
        XCTAssertTrue(files.contains { $0.file === alamofireFile })
    }

    func test_generateLinkingPhase_requiredProduct() throws {
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.testFramework(path: "/test.framework"))
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework",
            status: .required
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let testFile = PBXFileReference()
        pbxproj.add(object: testFile)
        let wakaFile = PBXFileReference()
        pbxproj.add(object: wakaFile)
        fileElements.products["Test"] = wakaFile
        fileElements.elements[try AbsolutePath(validating: "/test.framework")] = testFile
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = dependencies

        try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: path,
            graphTraverser: graphTraverser
        )

        let buildPhase = try pbxTarget.frameworksBuildPhase()

        let testBuildFile: PBXBuildFile? = buildPhase?.files?.first
        XCTAssertNil(testBuildFile?.settings?["ATTRIBUTES"])
    }

    func test_generateLinkingPhase_optionalProduct() throws {
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.testFramework(path: "/test.framework"))
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework",
            status: .optional
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let testFile = PBXFileReference()
        pbxproj.add(object: testFile)
        let wakaFile = PBXFileReference()
        pbxproj.add(object: wakaFile)
        fileElements.products["Test"] = wakaFile
        fileElements.elements[try AbsolutePath(validating: "/test.framework")] = testFile
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = dependencies

        try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: path,
            graphTraverser: graphTraverser
        )

        let buildPhase = try pbxTarget.frameworksBuildPhase()

        let testBuildFile: PBXBuildFile? = buildPhase?.files?.first
        let attributes: [String]? = testBuildFile?.settings?["ATTRIBUTES"]?.arrayValue
        XCTAssertEqual(attributes, ["Weak"])
    }

    func test_generateLinkingPhase_optionalFramework() throws {
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.testFramework(path: "/test.framework", status: .optional))
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework"
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let testFile = PBXFileReference()
        pbxproj.add(object: testFile)
        let wakaFile = PBXFileReference()
        pbxproj.add(object: wakaFile)
        fileElements.products["Test"] = wakaFile
        fileElements.elements[try AbsolutePath(validating: "/test.framework")] = testFile
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = dependencies

        try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: path,
            graphTraverser: graphTraverser
        )

        let buildPhase = try pbxTarget.frameworksBuildPhase()

        let testBuildFile: PBXBuildFile? = buildPhase?.files?.last
        let attributes: [String]? = testBuildFile?.settings?["ATTRIBUTES"]?.arrayValue
        XCTAssertEqual(attributes, ["Weak"])
    }

    func test_generateLinkingPhase_throws_whenFileReferenceIsMissing() throws {
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.testFramework(path: "/test.framework"))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = dependencies

        XCTAssertThrowsError(try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: path,
            graphTraverser: graphTraverser
        )) {
            XCTAssertEqual(
                $0 as? LinkGeneratorError,
                LinkGeneratorError.missingReference(path: try! AbsolutePath(validating: "/test.framework"))
            )
        }
    }

    func test_generateLinkingPhase_throws_whenProductIsMissing() throws {
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.product(
            target: "Test",
            productName: "Test.framework"
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = dependencies

        XCTAssertThrowsError(try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: path,
            graphTraverser: graphTraverser
        )) {
            XCTAssertEqual($0 as? LinkGeneratorError, LinkGeneratorError.missingProduct(name: "Test"))
        }
    }

    func test_generateLinkingPhase_sdk() throws {
        // Given
        var dependencies: Set<GraphDependencyReference> = []
        dependencies.insert(GraphDependencyReference.sdk(
            path: "/Strong/Foo.framework",
            status: .required,
            source: .developer
        ))
        dependencies.insert(GraphDependencyReference.sdk(
            path: "/Weak/Bar.framework",
            status: .optional,
            source: .developer
        ))
        let pbxproj = PBXProj()
        let (pbxTarget, target) = createTargets(product: .framework)
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        let requiredFile = PBXFileReference(name: "required")
        let optionalFile = PBXFileReference(name: "optional")
        fileElements.compiled["/Strong/Foo.framework"] = requiredFile
        fileElements.compiled["/Weak/Bar.framework"] = optionalFile
        let path = try AbsolutePath(validating: "/path/")
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = dependencies

        // When
        try subject.generateLinkingPhase(
            target: target,
            pbxTarget: pbxTarget,
            pbxproj: pbxproj,
            fileElements: fileElements,
            path: path,
            graphTraverser: graphTraverser
        )

        // Then
        let buildPhase = try pbxTarget.frameworksBuildPhase()

        XCTAssertNotNil(buildPhase)
        XCTAssertEqual(buildPhase?.files?.map(\.file), [
            requiredFile,
            optionalFile,
        ])
        XCTAssertEqual(buildPhase?.files?.map(\.settings), [
            nil,
            ["ATTRIBUTES": ["Weak"]],
        ])
    }

    func test_generateLinks_generatesAShellScriptBuildPhase_when_targetIsAMacroFramework() throws {
        // Given
        let app = Target.test(name: "app", platform: .iOS, product: .app)
        let macroFramework = Target.test(name: "framework", platform: .iOS, product: .staticFramework)
        let macroExecutable = Target.test(name: "macro", platform: .macOS, product: .macro)
        let project = Project.test(targets: [app, macroFramework, macroExecutable])

        let graph = Graph.test(path: project.path, projects: [project.path: project], targets: [
            project.path: [
                app.name: app,
                macroFramework.name: macroFramework,
                macroExecutable.name: macroExecutable,
            ],
        ], dependencies: [
            .target(name: app.name, path: project.path, status: .required): Set([.target(name: macroFramework.name, path: project.path, status: .required)]),
            .target(name: macroFramework.name, path: project.path, status: .required): Set([.target(
                name: macroExecutable.name,
                path: project.path,
                status: .required
            )]),
            .target(name: macroExecutable.name, path: project.path, status: .required): Set([]),
        ])
        let graphTraverser = GraphTraverser(graph: graph)
        let xcodeProjElements = createXcodeprojElements()
        let fileElements = createProjectFileElements(for: [app, macroFramework, macroExecutable])

        // When
        try subject.generateLinks(
            target: macroFramework,
            pbxTarget: xcodeProjElements.pbxTarget,
            pbxproj: xcodeProjElements.pbxproj,
            fileElements: fileElements,
            path: project.path,
            sourceRootPath: project.path,
            graphTraverser: graphTraverser
        )

        // Then
        let buildPhase = xcodeProjElements
            .pbxTarget
            .buildPhases
            .compactMap { $0 as? PBXShellScriptBuildPhase }
            .first(where: { $0.name() == "Copy Swift Macro executable into $BUILT_PRODUCT_DIR" })

        XCTAssertNotNil(buildPhase)

        let expectedScript =
            "if [[ -f \"$BUILD_DIR/$CONFIGURATION/macro\" && ! -f \"$BUILD_DIR/Debug$EFFECTIVE_PLATFORM_NAME/macro\" ]]; then\n    mkdir -p \"$BUILD_DIR/Debug$EFFECTIVE_PLATFORM_NAME/\"\n    cp \"$BUILD_DIR/$CONFIGURATION/macro\" \"$BUILD_DIR/Debug$EFFECTIVE_PLATFORM_NAME/macro\"\nfi"
        XCTAssertTrue(buildPhase?.shellScript?.contains(expectedScript) == true)
        XCTAssertTrue(buildPhase?.inputPaths.contains("$BUILD_DIR/$CONFIGURATION/\(macroExecutable.productName)") == true)
        XCTAssertTrue(
            buildPhase?.outputPaths
                .contains("$BUILD_DIR/Debug-iphonesimulator/\(macroExecutable.productName)") == true
        )
        XCTAssertTrue(
            buildPhase?.outputPaths
                .contains("$BUILD_DIR/Debug-iphoneos/\(macroExecutable.productName)") == true
        )
    }

    func test_generateLinkingPhase_nativeXCFrameworkReferencesPreserveStatusAndCondition() throws {
        let container: AbsolutePath = "/Frameworks/Product.xcframework"
        let disabled: AbsolutePath = "/Frameworks/Disabled.xcframework"
        let dependency = GraphDependencyReference.testXCFramework(path: container, status: .optional, condition: .when([.ios]))
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = [
            dependency, .testXCFramework(path: disabled, status: .none),
        ]
        let pbxTarget = PBXNativeTarget(name: "Consumer")
        let target = Target.test(name: "Consumer", destinations: [.iPhone, .mac], product: .app)
        let pbxproj = PBXProj()
        let nativeReference = PBXFileReference(
            sourceTree: .absolute,
            name: "Product.framework",
            lastKnownFileType: "wrapper.framework",
            path: "$(GEKO_XCFRAMEWORK_PRODUCT)"
        )
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        fileElements.elements[container] = nativeReference

        try subject.generateLinkingPhase(
            target: target, pbxTarget: pbxTarget, pbxproj: pbxproj, fileElements: fileElements,
            path: "/path", graphTraverser: graphTraverser
        )

        let phase = try XCTUnwrap(pbxTarget.buildPhases.first as? PBXFrameworksBuildPhase)
        let files = try XCTUnwrap(phase.files)
        XCTAssertEqual(files.map(\.file), [nativeReference])
        XCTAssertEqual(files.map(\.settings), [["ATTRIBUTES": ["Weak"]]])
        XCTAssertEqual(files.map(\.platformFilter), ["ios"])
        XCTAssertEqual(pbxTarget.buildPhases.count, 1)
    }

    func test_generateLinkingPhase_nativeXCFrameworkArchiveConsumesContainerLogicalKey() throws {
        let container: AbsolutePath = "/Frameworks/Product.xcframework"
        let graphTraverser = MockGraphTraverser()
        graphTraverser.stubbedLinkableDependenciesResult = [.testXCFramework(path: container, linking: .static)]
        let pbxTarget = PBXNativeTarget(name: "Consumer")
        let target = Target.test(name: "Consumer", product: .staticFramework)
        let pbxproj = PBXProj()
        let nativeReference = PBXFileReference(
            sourceTree: .absolute,
            name: "libProduct.a",
            lastKnownFileType: "archive.ar",
            path: "$(GEKO_XCFRAMEWORK_PRODUCT)"
        )
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        fileElements.elements[container] = nativeReference

        try subject.generateLinkingPhase(
            target: target, pbxTarget: pbxTarget, pbxproj: pbxproj, fileElements: fileElements,
            path: "/path", graphTraverser: graphTraverser
        )

        let phase = try XCTUnwrap(pbxTarget.buildPhases.first as? PBXFrameworksBuildPhase)
        let files = try XCTUnwrap(phase.files)
        XCTAssertEqual(files.map(\.file), [nativeReference])
        XCTAssertEqual(files.map(\.settings), [nil])
        XCTAssertEqual(pbxTarget.buildPhases.count, 1)
    }


    private func setupSliceSearchPaths(_ dependencies: [GraphDependencyReference], elements: XcodeprojElements) throws {
        try subject.setupPlatformDependentFrameworkSearchPath(
            target: .test(), pbxTarget: elements.pbxTarget, sourceRootPath: "/path", path: "/path",
            searchablePathDependencies: dependencies,
            sharedRoot: FrameworkSearchPathsGenerator.rootPath(workspacePath: "/path")
        )
    }

    // MARK: - Helpers

    struct XcodeprojElements {
        var pbxproj: PBXProj
        var pbxTarget: PBXNativeTarget
        var config: XCBuildConfiguration
    }

    func createXcodeprojElements() -> XcodeprojElements {
        let pbxproj = PBXProj()
        let pbxTarget = PBXNativeTarget(name: "Test")
        pbxproj.add(object: pbxTarget)

        let configurationList = XCConfigurationList(buildConfigurations: [])
        pbxproj.add(object: configurationList)
        pbxTarget.buildConfigurationList = configurationList

        let config = XCBuildConfiguration(name: "Debug")
        pbxproj.add(object: config)
        configurationList.buildConfigurations.append(config)

        return XcodeprojElements(
            pbxproj: pbxproj,
            pbxTarget: pbxTarget,
            config: config
        )
    }

    func createProjectFileElements(for targets: [Target]) -> ProjectFileElements {
        let projectFileElements = ProjectFileElements(enforceExplicitDependencies: false)
        for target in targets {
            projectFileElements.products[target.name] = PBXFileReference(path: target.productNameWithExtension)
        }

        return projectFileElements
    }

    func createProjectFileElements(
        for dependencies: [GraphDependency],
        projectPath: AbsolutePath
    ) -> ProjectFileElements {
        let projectFileElements = ProjectFileElements(enforceExplicitDependencies: false)
        for dependency in dependencies {
            switch dependency {
            case let .xcframework(xcframework):
                projectFileElements.elements[xcframework.path] = PBXFileReference(
                    path: xcframework.path.relative(to: projectPath).pathString
                )
            default:
                fatalError("Scenarios not handled in this test stub")
            }
        }
        return projectFileElements
    }

    private func createTargets(product: Product) -> (PBXTarget, Target) {
        (
            PBXNativeTarget(name: "Test"),
            Target.test(name: "Test", product: product)
        )
    }

    private func createFileElements(fileAbsolutePath: AbsolutePath) -> ProjectFileElements {
        let fileElements = ProjectFileElements(enforceExplicitDependencies: false)
        fileElements.elements[fileAbsolutePath] = PBXFileReference(path: fileAbsolutePath.basename)
        return fileElements
    }
}
