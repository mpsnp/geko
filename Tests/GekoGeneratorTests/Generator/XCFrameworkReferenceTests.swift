import Foundation
import GekoGraph
import GekoGraphTesting
import GekoSupport
import ProjectDescription
import XCTest

@testable import GekoGenerator

final class XCFrameworkReferenceTests: XCTestCase {
    private let path: AbsolutePath = "/cache/Container.xcframework"

    func test_selectsNativeProductForEverySDK() throws {
        let destinations: [(XCFrameworkInfoPlist.Library.Platform, XCFrameworkInfoPlist.Library.PlatformVariant?, String)] = [
            (.ios, nil, "iphoneos"), (.ios, .simulator, "iphonesimulator"),
            (.tvos, nil, "appletvos"), (.tvos, .simulator, "appletvsimulator"),
            (.watchos, nil, "watchos"), (.watchos, .simulator, "watchsimulator"),
            (.visionos, nil, "xros"), (.visionos, .simulator, "xrsimulator"),
            (.macos, nil, "macosx"), (.ios, .maccatalyst, "maccatalyst"),
        ]
        let libraries = try destinations.map { platform, variant, sdk in
            try library(sdk, platform: platform, variant: variant)
        }
        let descriptor = try reference(libraries)
        XCTAssertEqual(descriptor.name, "Product.framework")
        XCTAssertEqual(descriptor.fileType, "wrapper.framework")
        XCTAssertEqual(descriptor.settingName, "GEKO_XCFRAMEWORK_" + path.pathString.md5.uppercased())
        for (_, _, sdk) in destinations {
            let selected = try resolve(
                descriptor, sdk: sdk == "maccatalyst" ? "macosx" : sdk,
                architecture: "arm64", catalyst: sdk == "maccatalyst"
            )
            XCTAssertEqual(selected, "$(SRCROOT)/../cache/Container.xcframework/\(sdk)/Product.framework")
        }
        XCTAssertNil(try resolve(descriptor, sdk: "driverkit", architecture: "arm64"))
    }

    func test_disjointArchitectureSlicesSelectByDestinationAndIgnoreMetadataOrder() throws {
        let libraries = try [
            library("sim-arm", variant: .simulator, architectures: [.arm64]),
            library("sim-intel", variant: .simulator, architectures: [.x8664, .i386]),
            library("device", architectures: [.arm64]),
        ]
        let descriptor = try reference(libraries)
        XCTAssertEqual(descriptor, try reference(Array(libraries.reversed())))
        XCTAssertEqual(try resolve(descriptor, sdk: "iphonesimulator", architecture: "arm64"),
                       "$(SRCROOT)/../cache/Container.xcframework/sim-arm/Product.framework")
        for architecture in ["x86_64", "i386"] {
            XCTAssertEqual(try resolve(descriptor, sdk: "iphonesimulator", architecture: architecture),
                           "$(SRCROOT)/../cache/Container.xcframework/sim-intel/Product.framework")
        }
        XCTAssertEqual(try resolve(descriptor, sdk: "iphoneos", architecture: "arm64"),
                       "$(SRCROOT)/../cache/Container.xcframework/device/Product.framework")
        XCTAssertNil(try resolve(descriptor, sdk: "iphonesimulator", architecture: "armv7"))
        XCTAssertNil(descriptor.settings[descriptor.settingName + "[sdk=iphonesimulator*]"])
    }

    func test_macOSAndCatalystKeepArchitectureSelectorsIndependent() throws {
        let descriptor = try reference([
            library("mac-arm", platform: .macos, architectures: [.arm64]),
            library("mac-intel", platform: .macos, architectures: [.x8664]),
            library("catalyst-arm", variant: .maccatalyst, architectures: [.arm64]),
            library("catalyst-intel", variant: .maccatalyst, architectures: [.x8664]),
        ])
        for catalyst in [false, true] {
            for (architecture, suffix) in [("arm64", "arm"), ("x86_64", "intel")] {
                let prefix = catalyst ? "catalyst" : "mac"
                XCTAssertEqual(try resolve(descriptor, sdk: "macosx", architecture: architecture, catalyst: catalyst),
                               "$(SRCROOT)/../cache/Container.xcframework/\(prefix)-\(suffix)/Product.framework")
            }
        }
    }

    func test_catalystOnlyDoesNotSelectCatalystForNativeMacOS() throws {
        let descriptor = try reference([library("catalyst", variant: .maccatalyst)])
        XCTAssertNil(try resolve(descriptor, sdk: "macosx", architecture: "arm64"))
        XCTAssertEqual(try resolve(descriptor, sdk: "macosx", architecture: "arm64", catalyst: true),
                       "$(SRCROOT)/../cache/Container.xcframework/catalyst/Product.framework")
    }

    func test_macOSOnlyDoesNotSelectNativeMacOSSliceForCatalyst() throws {
        let descriptor = try reference([library("mac", platform: .macos)])
        XCTAssertEqual(try resolve(descriptor, sdk: "macosx", architecture: "arm64"),
                       "$(SRCROOT)/../cache/Container.xcframework/mac/Product.framework")
        XCTAssertNil(try resolve(descriptor, sdk: "macosx", architecture: "arm64", catalyst: true))
    }

    func test_frameworkBinaryPathsNormalizeToBundleAndArchivesRemainNative() throws {
        for libraryPath in ["Product.framework", "Product.framework/Product", "Product.framework/Versions/A/Product"] {
            let descriptor = try reference([library("ios", product: libraryPath)])
            XCTAssertEqual(descriptor.name, "Product.framework")
            XCTAssertEqual(try resolve(descriptor, sdk: "iphoneos", architecture: "arm64"),
                           "$(SRCROOT)/../cache/Container.xcframework/ios/Product.framework")
        }
        for (product, type) in [("libProduct.a", "archive.ar"), ("libProduct.dylib", "compiled.mach-o.dylib")] {
            let descriptor = try reference([library("ios", product: product)])
            XCTAssertEqual(descriptor.name, product)
            XCTAssertEqual(descriptor.fileType, type)
            XCTAssertEqual(try resolve(descriptor, sdk: "iphoneos", architecture: "arm64"),
                           "$(SRCROOT)/../cache/Container.xcframework/ios/\(product)")
        }
    }

    func test_overlappingArchitecturesFailDeterministicallyInsteadOfChoosingFirstSlice() throws {
        let libraries = try [
            library("one", variant: .simulator, architectures: [.arm64, .x8664]),
            library("two", variant: .simulator, architectures: [.arm64]),
        ]
        var descriptions: [String] = []
        for ordered in [libraries, Array(libraries.reversed())] {
            XCTAssertThrowsError(try reference(ordered)) { error in
                descriptions.append((error as? XCFrameworkReferenceError)?.description ?? "unexpected error")
            }
        }
        XCTAssertEqual(descriptions.count, 2)
        XCTAssertEqual(descriptions.first, descriptions.last)
        XCTAssertTrue(descriptions[0].contains("ambiguous architectures for iphonesimulator"))
    }

    func test_invalidMetadataNeverFallsBackToContainer() throws {
        let invalidLibraries: [[XCFrameworkInfoPlist.Library]] = try [
            [],
            [library("ios", product: "unrecognized")],
            [library("ios", architectures: [])],
            [library("ios"), library("ios", variant: .simulator)],
            [library("ios"), library("sim", product: "Other.framework", variant: .simulator)],
            [library("mac", platform: .macos, variant: .simulator)],
            [library("../escape")],
        ]
        for libraries in invalidLibraries {
            XCTAssertThrowsError(try reference(libraries))
        }
    }

    func test_symbolDirectoriesFollowSDKAndArchitectureAndAreEmptyWhenAbsent() throws {
        let descriptor = try reference([
            library("device", debugSymbols: "dSYMs", bitcodeSymbolMaps: "BCSymbolMaps"),
            library("sim-arm", variant: .simulator, architectures: [.arm64], debugSymbols: "ArmSymbols"),
            library("sim-intel", variant: .simulator, architectures: [.x8664]),
        ])
        XCTAssertEqual(try resolve(descriptor, sdk: "iphoneos", architecture: "arm64", suffix: "_DEBUG_SYMBOLS"),
                       "$(SRCROOT)/../cache/Container.xcframework/device/dSYMs")
        XCTAssertEqual(try resolve(descriptor, sdk: "iphoneos", architecture: "arm64", suffix: "_BITCODE_SYMBOL_MAPS"),
                       "$(SRCROOT)/../cache/Container.xcframework/device/BCSymbolMaps")
        XCTAssertEqual(try resolve(descriptor, sdk: "iphonesimulator", architecture: "arm64", suffix: "_DEBUG_SYMBOLS"),
                       "$(SRCROOT)/../cache/Container.xcframework/sim-arm/ArmSymbols")
        XCTAssertEqual(try resolve(descriptor, sdk: "iphonesimulator", architecture: "x86_64", suffix: "_DEBUG_SYMBOLS"), "")
        XCTAssertEqual(try resolve(descriptor, sdk: "iphonesimulator", architecture: "arm64", suffix: "_BITCODE_SYMBOL_MAPS"), "")
        XCTAssertEqual(try resolve(descriptor, sdk: "watchos", architecture: "arm64", suffix: "_DEBUG_SYMBOLS"), "")
    }

    func test_symbolDirectoriesKeepMacOSAndCatalystArchitectureSelectionIndependent() throws {
        let descriptor = try reference([
            library("mac-arm", platform: .macos, architectures: [.arm64], debugSymbols: "dSYMs"),
            library("mac-intel", platform: .macos, architectures: [.x8664], debugSymbols: "dSYMs"),
            library("catalyst-arm", variant: .maccatalyst, architectures: [.arm64], debugSymbols: "CatalystSymbols"),
            library("catalyst-intel", variant: .maccatalyst, architectures: [.x8664]),
        ])
        for (architecture, slice) in [("arm64", "mac-arm"), ("x86_64", "mac-intel")] {
            XCTAssertEqual(try resolve(descriptor, sdk: "macosx", architecture: architecture, suffix: "_DEBUG_SYMBOLS"),
                           "$(SRCROOT)/../cache/Container.xcframework/\(slice)/dSYMs")
        }
        XCTAssertEqual(try resolve(descriptor, sdk: "macosx", architecture: "arm64", catalyst: true, suffix: "_DEBUG_SYMBOLS"),
                       "$(SRCROOT)/../cache/Container.xcframework/catalyst-arm/CatalystSymbols")
        XCTAssertEqual(try resolve(descriptor, sdk: "macosx", architecture: "x86_64", catalyst: true, suffix: "_DEBUG_SYMBOLS"), "")
        let catalystOnly = try reference([library("catalyst", variant: .maccatalyst, debugSymbols: "dSYMs")])
        XCTAssertEqual(try resolve(catalystOnly, sdk: "macosx", architecture: "arm64", suffix: "_DEBUG_SYMBOLS"), "")
    }

    func test_symbolFreeMetadataProducesNoSymbolVariables() throws {
        let descriptor = try reference([library("device")])
        XCTAssertFalse(descriptor.settings.keys.contains { $0.contains("_DEBUG_SYMBOLS") || $0.contains("_BITCODE_SYMBOL_MAPS") })
    }

    private func library(
        _ identifier: String,
        product: String = "Product.framework",
        platform: XCFrameworkInfoPlist.Library.Platform = .ios,
        variant: XCFrameworkInfoPlist.Library.PlatformVariant? = nil,
        architectures: [BinaryArchitecture] = [.arm64],
        debugSymbols: String? = nil,
        bitcodeSymbolMaps: String? = nil
    ) throws -> XCFrameworkInfoPlist.Library {
        .init(identifier: identifier, path: try RelativePath(validating: product), mergeable: false,
              architectures: architectures, platform: platform, platformVariant: variant,
              debugSymbolsPath: try debugSymbols.map { try RelativePath(validating: $0) },
              bitcodeSymbolMapsPath: try bitcodeSymbolMaps.map { try RelativePath(validating: $0) })
    }

    private func reference(_ libraries: [XCFrameworkInfoPlist.Library]) throws -> XCFrameworkReference {
        try XCFrameworkReference(path: path, infoPlist: .init(libraries: libraries, searchPathPlatforms: [:]),
                                 sourceRootPath: "/project")
    }

    /// Evaluate the generated destination conditions and Catalyst variable indirection.
    /// Assertions compare the selected artifact, not the spelling of intermediate settings.
    private func resolve(
        _ descriptor: XCFrameworkReference,
        sdk: String,
        architecture: String,
        catalyst: Bool = false,
        suffix: String = ""
    ) throws -> String? {
        func value(for name: String) throws -> String? {
            let candidates = descriptor.settings.filter { key, _ in
                let parts = key.split(separator: "[").map(String.init)
                guard parts.first == name else { return false }
                return parts.dropFirst().allSatisfy { condition in
                    if condition.hasPrefix("sdk=") {
                        return sdk.hasPrefix(String(condition.dropFirst(4).dropLast(2)))
                    }
                    if condition.hasPrefix("arch=") {
                        return architecture == condition.dropFirst(5).dropLast()
                    }
                    return false
                }
            }
            let specificity = candidates.keys.map { $0.filter { $0 == "[" }.count }.max()
            let selected = candidates.filter { $0.key.filter { $0 == "[" }.count == specificity }
            XCTAssertLessThanOrEqual(selected.count, 1, "Ambiguous setting for \(name)")
            guard let setting = selected.first?.value else { return nil }
            let expanded = try setting.stringValue().replacingOccurrences(of: "$(IS_MACCATALYST)", with: catalyst ? "YES" : "NO")
            if expanded.hasPrefix("$(GEKO_XCFRAMEWORK_"), expanded.hasSuffix(")") {
                return try value(for: String(expanded.dropFirst(2).dropLast()))
            }
            return expanded
        }
        return try value(for: descriptor.settingName + suffix)
    }
}
