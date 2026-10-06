import Foundation
import GekoCore
import GekoGraph
import GekoGraphTesting
import ProjectDescription
import XCTest
@testable import GekoGenerator
@testable import GekoSupportTesting

final class FrameworkSearchPathsGeneratorTests: GekoTestCase {
    private let subject = FrameworkSearchPathsGenerator()

    func test_generate_linksActualProductNameAndOnlyCurrentGraphArtifacts() throws {
        let artifact = try createFramework("cache/OriginalTarget/current/ProductName.framework", content: "current")
        let historical = try createFramework("cache/OriginalTarget/old/ProductName.framework", content: "historical")
        let unused = try createFramework("cache/Unused/Unused.framework", content: "unused")
        let graph = try traverser([[framework(artifact)]], targetNames: ["OriginalTarget"])

        try subject.generate(graphTraverser: graph)

        let root = try indexRoot()
        let link = root.appending(component: "ProductName.framework")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.pathString), artifact.pathString)
        XCTAssertEqual(try String(contentsOfFile: link.appending(component: "ProductName").pathString, encoding: .utf8), "current")
        XCTAssertFalse(fileHandler.exists(root.appending(component: "OriginalTarget.framework")))
        XCTAssertFalse(fileHandler.exists(root.appending(component: "Unused.framework")))
        XCTAssertEqual(try fileHandler.readTextFile(historical.appending(component: "ProductName")), "historical")
        XCTAssertEqual(try fileHandler.readTextFile(unused.appending(component: "Unused")), "unused")
    }

    func test_generate_indexesFrameworkLibraryPathWithoutBinarySuffix() throws {
        let artifact = try createFramework("cache/Target.xcframework/macos-arm64/Product.framework", content: "product")
        let dependency = try xcframework("cache/Target.xcframework", binaries: ["macosx": "macos-arm64/Product.framework"])

        try subject.generate(graphTraverser: traverser([[dependency]]))

        let link = try indexRoot().appending(components: "macosx", "Product.framework")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.pathString), artifact.pathString)
        XCTAssertEqual(try fileHandler.readTextFile(link.appending(component: "Product")), "product")
    }

    func test_generate_unionsDependenciesAcrossTargetsAndAcceptsIdenticalMappings() throws {
        let first = try createFramework("cache/First.framework", content: "first")
        let second = try createFramework("cache/Second.framework", content: "second")
        let graph = try traverser([[framework(first)], [framework(first), framework(second)]])

        try subject.generate(graphTraverser: graph)
        try subject.generate(graphTraverser: graph)

        let root = try indexRoot()
        XCTAssertEqual(try fileHandler.readTextFile(root.appending(components: "First.framework", "First")), "first")
        XCTAssertEqual(try fileHandler.readTextFile(root.appending(components: "Second.framework", "Second")), "second")
    }

    func test_generate_rejectsDistinctArtifactsWithSameProductNameDeterministically() throws {
        let first = try createFramework("cache/a/Product.framework", content: "a")
        let second = try createFramework("cache/b/Product.framework", content: "b")
        let link = try indexRoot().appending(component: "Product.framework")
        let expected = FrameworkSearchPathsGeneratorError.collision(path: link, first: first, second: second)

        for groups in [[[framework(first)], [framework(second)]], [[framework(second)], [framework(first)]]] {
            XCTAssertThrowsError(try subject.generate(graphTraverser: traverser(groups))) {
                XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, expected)
            }
        }

        XCTAssertFalse(fileHandler.exists(try indexRoot()))
        XCTAssertEqual(try fileHandler.readTextFile(first.appending(component: "Product")), "a")
        XCTAssertEqual(try fileHandler.readTextFile(second.appending(component: "Product")), "b")
    }

    func test_generate_isolatesSameFrameworkNameBySDK() throws {
        let device = try createFramework("cache/Device.xcframework/ios-arm64/Product.framework", content: "device")
        let simulator = try createFramework("cache/Simulator.xcframework/ios-arm64-simulator/Product.framework", content: "simulator")
        let deviceDependency = try xcframework("cache/Device.xcframework", binaries: ["iphoneos": "ios-arm64/Product.framework/Product"])
        let simulatorDependency = try xcframework("cache/Simulator.xcframework", binaries: ["iphonesimulator": "ios-arm64-simulator/Product.framework/Product"])

        try subject.generate(graphTraverser: traverser([[deviceDependency, simulatorDependency]]))

        let root = try indexRoot()
        for (relativePath, artifact, content) in [
            ("iphoneos/Product.framework", device, "device"),
            ("iphonesimulator/Product.framework", simulator, "simulator"),
        ] {
            let link = root.appending(try RelativePath(validating: relativePath))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.pathString), artifact.pathString)
            XCTAssertEqual(try fileHandler.readTextFile(link.appending(component: "Product")), content)
        }
    }

    func test_generate_rejectsPlainFrameworkShadowingSDKFramework() throws {
        let plain = try createFramework("cache/a/Product.framework", content: "plain")
        let slice = try createFramework("cache/b.xcframework/macos/Product.framework", content: "slice")
        let dependency = try xcframework("cache/b.xcframework", binaries: ["macosx": "macos/Product.framework/Product"])
        let link = try indexRoot().appending(components: "macosx", "Product.framework")

        for dependencies in [[framework(plain), dependency], [dependency, framework(plain)]] {
            XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([dependencies]))) {
                XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .collision(path: link, first: plain, second: slice))
            }
        }
        XCTAssertFalse(fileHandler.exists(try indexRoot()))
    }

    func test_generate_rejectsXCFrameworkCollisionWithinSameSDK() throws {
        let first = try createFramework("cache/a.xcframework/ios/Product.framework", content: "a")
        let second = try createFramework("cache/b.xcframework/ios/Product.framework", content: "b")
        let dependencies = try [
            xcframework("cache/a.xcframework", binaries: ["iphoneos": "ios/Product.framework/Product"]),
            xcframework("cache/b.xcframework", binaries: ["iphoneos": "ios/Product.framework/Product"]),
        ]
        let link = try indexRoot().appending(components: "iphoneos", "Product.framework")

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([dependencies]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .collision(path: link, first: first, second: second))
        }
        XCTAssertFalse(fileHandler.exists(try indexRoot()))
    }

    func test_generate_doesNotIndexStaticLibrarySlicesOrMutateTheirFiles() throws {
        let library = try createFiles(["cache/Library.xcframework/ios/libLibrary.a"], content: "library")[0]
        let headers = try createFiles(["cache/Library.xcframework/ios/Headers/Library.h"], content: "header")[0]
        let rawLibrary = try createFiles(["cache/libRaw.a"], content: "raw")[0]
        let xcDependency = try xcframework("cache/Library.xcframework", binaries: ["iphoneos": "ios/libLibrary.a"], linking: .static)

        try subject.generate(graphTraverser: traverser([[xcDependency, .testLibrary(path: rawLibrary, linking: .static)]]))

        let root = try indexRoot()
        XCTAssertFalse(fileHandler.exists(root.appending(component: "iphoneos")))
        XCTAssertFalse(fileHandler.exists(root.appending(component: "libRaw.a")))
        XCTAssertEqual(try fileHandler.readTextFile(library), "library")
        XCTAssertEqual(try fileHandler.readTextFile(headers), "header")
        XCTAssertEqual(try fileHandler.readTextFile(rawLibrary), "raw")
    }

    func test_generate_isolatesCatalystFromMacOSUsingLibraryMetadata() throws {
        let mac = try createFramework("cache/Bundle.xcframework/macos/Product.framework", content: "mac")
        let catalyst = try createFramework("cache/Bundle.xcframework/catalyst/Product.framework", content: "catalyst")
        let dependency = try xcframework("cache/Bundle.xcframework", libraries: [
            .test(identifier: "macos", path: try RelativePath(validating: "Product.framework"), platform: .macos),
            .test(identifier: "catalyst", path: try RelativePath(validating: "Product.framework/Versions/A/Product"),
                  platform: .ios, platformVariant: .maccatalyst),
        ])

        try subject.generate(graphTraverser: traverser([[dependency]]))

        let root = try indexRoot()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(components: "macosx", "Product.framework").pathString), mac.pathString)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(components: "maccatalyst", "Product.framework").pathString), catalyst.pathString)
    }

    func test_generate_indexesDisjointArchitectureSlicesForSimulatorAndCatalyst() throws {
        for (sdk, variant) in [("iphonesimulator", XCFrameworkInfoPlist.Library.PlatformVariant.simulator), ("maccatalyst", .maccatalyst)] {
            let arm = try createFramework("cache/\(sdk).xcframework/arm/Product.framework", content: "arm")
            let intel = try createFramework("cache/\(sdk).xcframework/intel/Product.framework", content: "intel")
            let dependency = try xcframework("cache/\(sdk).xcframework", libraries: [
                .test(identifier: "arm", path: try RelativePath(validating: "Product.framework"),
                      architectures: [.arm64], platform: .ios, platformVariant: variant),
                .test(identifier: "intel", path: try RelativePath(validating: "Product.framework/Product"),
                      architectures: [.x8664], platform: .ios, platformVariant: variant),
            ])

            try subject.generate(graphTraverser: traverser([[dependency]]))

            let root = try indexRoot()
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(components: sdk, "arm64", "Product.framework").pathString), arm.pathString)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(components: sdk, "x86_64", "Product.framework").pathString), intel.pathString)
            XCTAssertFalse(fileHandler.exists(root.appending(components: sdk, "Product.framework")))
        }
    }

    func test_generate_rejectsArchitectureSliceCollisionWithoutMutatingArtifacts() throws {
        let first = try createFramework("cache/Bundle.xcframework/a/Product.framework", content: "a")
        let second = try createFramework("cache/Bundle.xcframework/b/Product.framework", content: "b")
        let libraries: [XCFrameworkInfoPlist.Library] = try ["a", "b"].map {
            .test(identifier: $0, path: try RelativePath(validating: "Product.framework"),
                  architectures: [.arm64], platform: .ios, platformVariant: .maccatalyst)
        }
        let collision = try indexRoot().appending(components: "maccatalyst", "arm64", "Product.framework")
        for metadata in [libraries, libraries.reversed().map { $0 }] {
            let dependency = try xcframework("cache/Bundle.xcframework", libraries: metadata)
            XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[dependency]]))) {
                XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .collision(path: collision, first: first, second: second))
            }
        }
        XCTAssertFalse(fileHandler.exists(try indexRoot()))
        XCTAssertEqual(try fileHandler.readTextFile(first.appending(component: "Product")), "a")
        XCTAssertEqual(try fileHandler.readTextFile(second.appending(component: "Product")), "b")
    }

    func test_generate_rejectsOrdinarySDKFrameworkShadowingArchitectureSlice() throws {
        let ordinary = try createFramework("cache/a.xcframework/ios/Product.framework", content: "ordinary")
        let arm = try createFramework("cache/b.xcframework/arm/Product.framework", content: "arm")
        _ = try createFramework("cache/b.xcframework/intel/Product.framework", content: "intel")
        let single = try xcframework("cache/a.xcframework", binaries: ["iphonesimulator": "ios/Product.framework"])
        let multi = try xcframework("cache/b.xcframework", libraries: [
            .test(identifier: "arm", path: try RelativePath(validating: "Product.framework"),
                  architectures: [.arm64], platform: .ios, platformVariant: .simulator),
            .test(identifier: "intel", path: try RelativePath(validating: "Product.framework"),
                  architectures: [.x8664], platform: .ios, platformVariant: .simulator),
        ])
        let link = try indexRoot().appending(components: "iphonesimulator", "arm64", "Product.framework")

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[single, multi]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .collision(path: link, first: ordinary, second: arm))
        }
        XCTAssertFalse(fileHandler.exists(try indexRoot()))
    }

    func test_generate_cleansStaleArchitectureLinksAndPreservesUnownedContents() throws {
        let libraries: [XCFrameworkInfoPlist.Library] = try [
            .test(identifier: "arm", path: RelativePath(validating: "Product.framework"),
                  architectures: [.arm64], platform: .ios, platformVariant: .maccatalyst),
            .test(identifier: "intel", path: RelativePath(validating: "Product.framework"),
                  architectures: [.x8664], platform: .ios, platformVariant: .maccatalyst),
        ]
        for library in libraries {
            _ = try createFramework("cache/Bundle.xcframework/\(library.identifier)/Product.framework", content: library.identifier)
        }
        let dependency = try xcframework("cache/Bundle.xcframework", libraries: libraries)
        try subject.generate(graphTraverser: traverser([[dependency]]))
        let root = try indexRoot()
        let userFile = root.appending(components: "maccatalyst", "arm64", "keep.txt")
        try fileHandler.write("keep", path: userFile, atomically: true)

        try subject.generate(graphTraverser: traverser([[]]))

        for arch in ["arm64", "x86_64"] {
            XCTAssertFalse(fileHandler.exists(root.appending(components: "maccatalyst", arch, "Product.framework")))
        }
        XCTAssertEqual(try fileHandler.readTextFile(userFile), "keep")
    }

    func test_generate_doesNotFollowSymlinkedArchitectureAncestors() throws {
        let outside = try createFolders(["outside"])[0]
        let root = try indexRoot()
        try fileHandler.createFolder(root)
        let sdk = root.appending(component: "maccatalyst")
        try fileHandler.createSymbolicLink(at: sdk, destination: outside)
        let dependency = try xcframework("cache/Bundle.xcframework", libraries: [
            .test(identifier: "arm", path: try RelativePath(validating: "Product.framework"),
                  architectures: [.arm64], platform: .ios, platformVariant: .maccatalyst),
            .test(identifier: "intel", path: try RelativePath(validating: "Product.framework"),
                  architectures: [.x8664], platform: .ios, platformVariant: .maccatalyst),
        ])

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[dependency]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(sdk))
        }
        XCTAssertEqual(try fileHandler.contentsOfDirectory(outside), [])
    }

    func test_generate_doesNotIndexCatalystArchives() throws {
        let archive = try createFiles(["cache/Bundle.xcframework/catalyst/libProduct.a"], content: "archive")[0]
        let dependency = try xcframework("cache/Bundle.xcframework", libraries: [
            .test(identifier: "catalyst", path: try RelativePath(validating: "libProduct.a"),
                  architectures: [.arm64], platform: .ios, platformVariant: .maccatalyst),
        ], linking: .static)

        try subject.generate(graphTraverser: traverser([[dependency]]))

        XCTAssertFalse(fileHandler.exists(try indexRoot()))
        XCTAssertEqual(try fileHandler.readTextFile(archive), "archive")
    }

    func test_generate_updatesChangedArtifactAndRemovesStaleOwnedLinks() throws {
        let original = try createFramework("cache/old/Product.framework", content: "old")
        let updated = try createFramework("cache/new/Product.framework", content: "new")
        let stale = try createFramework("cache/Stale.framework", content: "stale")
        let staleSlice = try createFramework("cache/Old.xcframework/ios/Old.framework", content: "old slice")
        let xcDependency = try xcframework("cache/Old.xcframework", binaries: ["iphoneos": "ios/Old.framework/Old"])
        try subject.generate(graphTraverser: traverser([[framework(original), framework(stale), xcDependency]]))

        try subject.generate(graphTraverser: traverser([[framework(updated)]]))

        let root = try indexRoot()
        let link = root.appending(component: "Product.framework")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.pathString), updated.pathString)
        XCTAssertEqual(try fileHandler.readTextFile(link.appending(component: "Product")), "new")
        XCTAssertFalse(fileHandler.exists(root.appending(component: "Stale.framework")))
        XCTAssertFalse(fileHandler.exists(root.appending(components: "iphoneos", "Old.framework")))
        XCTAssertEqual(try fileHandler.readTextFile(original.appending(component: "Product")), "old")
        XCTAssertEqual(try fileHandler.readTextFile(stale.appending(component: "Stale")), "stale")
        XCTAssertEqual(try fileHandler.readTextFile(staleSlice.appending(component: "Old")), "old slice")
    }

    func test_generate_removesDanglingOwnedLinks() throws {
        let artifact = try createFramework("cache/Product.framework", content: "product")
        try subject.generate(graphTraverser: traverser([[framework(artifact)]]))
        try fileHandler.delete(artifact)

        try subject.generate(graphTraverser: traverser([[]]))

        let link = try indexRoot().appending(component: "Product.framework")
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: link.pathString))
    }

    func test_generate_preservesUnownedContentsDuringCleanup() throws {
        let artifact = try createFramework("cache/Bundle.xcframework/ios/Product.framework", content: "product")
        let dependency = try xcframework("cache/Bundle.xcframework", binaries: ["iphoneos": "ios/Product.framework/Product"])
        try subject.generate(graphTraverser: traverser([[dependency]]))
        let root = try indexRoot()
        let userFile = root.appending(component: "notes.txt")
        try fileHandler.write("user notes", path: userFile, atomically: true)
        let userDirectory = root.appending(components: "iphoneos", "User.framework")
        try fileHandler.createFolder(userDirectory)
        let userFileInDirectory = userDirectory.appending(component: "keep")
        try fileHandler.write("keep", path: userFileInDirectory, atomically: true)
        let userLink = root.appending(component: "UserLink.framework")
        try fileHandler.createSymbolicLink(at: userLink, destination: artifact)

        try subject.generate(graphTraverser: traverser([[]]))

        XCTAssertEqual(try fileHandler.readTextFile(userFile), "user notes")
        XCTAssertEqual(try fileHandler.readTextFile(userFileInDirectory), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: userLink.pathString), artifact.pathString)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(components: "iphoneos", "Product.framework").pathString))
    }

    func test_generate_rejectsUnownedFrameworkEvenWhenLinkDestinationMatches() throws {
        let artifact = try createFramework("cache/Product.framework", content: "product")
        let root = try indexRoot()
        try fileHandler.createFolder(root)
        let link = root.appending(component: "Product.framework")
        try fileHandler.createSymbolicLink(at: link, destination: artifact)

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[framework(artifact)]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(link))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.pathString), artifact.pathString)
    }

    func test_generate_doesNotReplaceUnownedFrameworkDirectory() throws {
        let artifact = try createFramework("cache/Product.framework", content: "product")
        let link = try indexRoot().appending(component: "Product.framework")
        try fileHandler.createFolder(link)
        let sentinel = link.appending(component: "keep")
        try fileHandler.write("user framework", path: sentinel, atomically: true)

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[framework(artifact)]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(link))
        }
        XCTAssertEqual(try fileHandler.readTextFile(sentinel), "user framework")
    }

    func test_generate_preservesOwnedLocationReplacedByUserContent() throws {
        let artifact = try createFramework("cache/Product.framework", content: "product")
        try subject.generate(graphTraverser: traverser([[framework(artifact)]]))
        let link = try indexRoot().appending(component: "Product.framework")
        try fileHandler.delete(link)
        try fileHandler.write("user content", path: link, atomically: true)

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(link))
        }
        XCTAssertEqual(try fileHandler.readTextFile(link), "user content")
        XCTAssertEqual(try fileHandler.readTextFile(artifact.appending(component: "Product")), "product")
    }

    func test_generate_doesNotFollowSymlinkedSDKDirectory() throws {
        let outside = try createFolders(["outside"])[0]
        let root = try indexRoot()
        try fileHandler.createFolder(root)
        let sdk = root.appending(component: "iphoneos")
        try fileHandler.createSymbolicLink(at: sdk, destination: outside)
        _ = try createFramework("cache/Bundle.xcframework/ios/Product.framework", content: "product")
        let dependency = try xcframework("cache/Bundle.xcframework", binaries: ["iphoneos": "ios/Product.framework/Product"])

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[dependency]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(sdk))
        }
        XCTAssertEqual(try fileHandler.contentsOfDirectory(outside), [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sdk.pathString), outside.pathString)
    }

    func test_generate_doesNotFollowSymlinkedIndexParent() throws {
        let outside = try createFolders(["outside"])[0]
        let root = try indexRoot()
        try fileHandler.createSymbolicLink(at: root.parentDirectory, destination: outside)
        let artifact = try createFramework("cache/Product.framework", content: "product")

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[framework(artifact)]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(root.parentDirectory))
        }
        XCTAssertEqual(try fileHandler.contentsOfDirectory(outside), [])
    }

    func test_generate_preservesRetargetedOwnedLinkDuringCleanup() throws {
        let original = try createFramework("cache/original/Product.framework", content: "original")
        let userArtifact = try createFramework("user/Product.framework", content: "user")
        try subject.generate(graphTraverser: traverser([[framework(original)]]))
        let link = try indexRoot().appending(component: "Product.framework")
        try fileHandler.delete(link)
        try fileHandler.createSymbolicLink(at: link, destination: userArtifact)

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(link))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.pathString), userArtifact.pathString)
        XCTAssertEqual(try fileHandler.readTextFile(userArtifact.appending(component: "Product")), "user")
    }

    func test_generate_doesNotFollowReplacedSDKDirectoryDuringStaleCleanup() throws {
        let artifact = try createFramework("cache/Bundle.xcframework/ios/Product.framework", content: "product")
        let dependency = try xcframework("cache/Bundle.xcframework", binaries: ["iphoneos": "ios/Product.framework/Product"])
        try subject.generate(graphTraverser: traverser([[dependency]]))
        let outside = try createFolders(["outside"])[0]
        let outsideLink = outside.appending(component: "Product.framework")
        try fileHandler.createSymbolicLink(at: outsideLink, destination: artifact)
        let sdk = try indexRoot().appending(component: "iphoneos")
        try fileHandler.delete(sdk)
        try fileHandler.createSymbolicLink(at: sdk, destination: outside)

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unownedPath(sdk))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: outsideLink.pathString), artifact.pathString)
    }

    func test_generate_preservesInvalidManifest() throws {
        let root = try indexRoot()
        try fileHandler.createFolder(root)
        let manifest = root.appending(component: ".manifest.json")
        try fileHandler.write("user contents", path: manifest, atomically: true)
        let artifact = try createFramework("cache/Product.framework", content: "product")

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[framework(artifact)]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .invalidManifest(manifest))
        }
        XCTAssertEqual(try fileHandler.readTextFile(manifest), "user contents")
        XCTAssertFalse(fileHandler.exists(root.appending(component: "Product.framework")))
    }

    func test_generate_rejectsUnsafeSDKBeforeCreatingIndex() throws {
        _ = try createFramework("cache/Bundle.xcframework/ios/Product.framework", content: "product")
        let dependency = try xcframework("cache/Bundle.xcframework", binaries: ["../outside": "ios/Product.framework/Product"])

        XCTAssertThrowsError(try subject.generate(graphTraverser: traverser([[dependency]]))) {
            XCTAssertEqual($0 as? FrameworkSearchPathsGeneratorError, .unsafePath("../outside"))
        }
        XCTAssertFalse(fileHandler.exists(try indexRoot()))
    }

    private func indexRoot() throws -> AbsolutePath {
        FrameworkSearchPathsGenerator.rootPath(workspacePath: try temporaryPath())
    }

    private func createFramework(_ relativePath: String, content: String) throws -> AbsolutePath {
        let path = try temporaryPath().appending(try RelativePath(validating: relativePath))
        try fileHandler.createFolder(path)
        try fileHandler.write(content, path: path.appending(component: path.basenameWithoutExt), atomically: true)
        return path
    }

    private func framework(_ path: AbsolutePath) -> GraphDependency {
        .testFramework(path: path, binaryPath: path.appending(component: path.basenameWithoutExt))
    }

    private func xcframework(
        _ relativePath: String,
        binaries: [String: String],
        linking: BinaryLinking = .dynamic
    ) throws -> GraphDependency {
        let path = try temporaryPath().appending(try RelativePath(validating: relativePath))
        let searchPaths = try binaries.mapValues { try RelativePath(validating: $0) }
        let firstBinary = try XCTUnwrap(searchPaths.values.first)
        return .testXCFramework(
            path: path,
            infoPlist: XCFrameworkInfoPlist(libraries: [], searchPathPlatforms: searchPaths),
            primaryBinaryPath: path.appending(firstBinary),
            linking: linking
        )
    }

    private func xcframework(
        _ relativePath: String,
        libraries: [XCFrameworkInfoPlist.Library],
        linking: BinaryLinking = .dynamic
    ) throws -> GraphDependency {
        let path = try temporaryPath().appending(try RelativePath(validating: relativePath))
        let library = try XCTUnwrap(libraries.first)
        return .testXCFramework(
            path: path,
            infoPlist: .test(libraries: libraries),
            primaryBinaryPath: path.appending(component: library.identifier).appending(library.path),
            linking: linking
        )
    }

    private func traverser(_ groups: [[GraphDependency]], targetNames: [String]? = nil) throws -> GraphTraverser {
        let path = try temporaryPath()
        let targets = groups.indices.map { Target.test(name: targetNames?[$0] ?? "Consumer\($0)") }
        let project = Project.test(path: path, targets: targets)
        var dependencies: [GraphDependency: Set<GraphDependency>] = [:]
        for (index, target) in targets.enumerated() {
            dependencies[.target(name: target.name, path: path)] = Set(groups[index])
        }
        return GraphTraverser(graph: .test(
            path: path,
            projects: [path: project],
            targets: [path: Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })],
            dependencies: dependencies
        ))
    }
}
