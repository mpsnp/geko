import Foundation
import GekoGraph
import GekoSupport
import ProjectDescription
import XcodeProj

enum XCFrameworkReferenceError: FatalError {
    case invalidMetadata(AbsolutePath, String)
    case conflictingDefinition(AbsolutePath)
    case conflictingBuildSetting(String)
    case unsupportedPlatformVariant(String)

    var description: String {
        switch self {
        case let .invalidMetadata(path, reason):
            return "Cannot reference XCFramework \(path): \(reason)"
        case let .conflictingDefinition(path):
            return "Conflicting native slice definitions for XCFramework \(path)"
        case let .conflictingBuildSetting(key):
            return "Conflicting generated XCFramework build setting \(key)"
        case let .unsupportedPlatformVariant(identifier):
            return "Unsupported XCFramework platform variant in \(identifier)"
        }
    }

    var type: ErrorType { .abort }
}

/// A native product reference whose absolute path is selected by the build destination.
/// The XCFramework container remains the graph identity, not an Xcode file reference.
struct XCFrameworkReference: Equatable {
    let settingName: String
    let name: String
    let fileType: String
    let settings: [String: SettingValue]

    init(path: AbsolutePath, infoPlist: XCFrameworkInfoPlist, sourceRootPath: AbsolutePath) throws {
        guard !infoPlist.libraries.isEmpty else {
            throw XCFrameworkReferenceError.invalidMetadata(path, "AvailableLibraries is empty")
        }
        settingName = Self.settingName(for: path)
        var productName: String?
        var productType: String?
        var librariesBySDK: [String: [XCFrameworkInfoPlist.Library]] = [:]
        var slicePaths: [String: [String: String]] = [:]
        var settingNames = [settingName]
        if infoPlist.libraries.contains(where: { $0.debugSymbolsPath != nil }) {
            settingNames.append(settingName + "_DEBUG_SYMBOLS")
        }
        if infoPlist.libraries.contains(where: { $0.bitcodeSymbolMapsPath != nil }) {
            settingNames.append(settingName + "_BITCODE_SYMBOL_MAPS")
        }

        // Sorting makes both validation failures and conditional setting generation deterministic.
        for library in infoPlist.libraries.sorted(by: { $0.identifier < $1.identifier }) {
            let identifierComponents = library.identifier.split(separator: "/", omittingEmptySubsequences: false)
            guard identifierComponents.count == 1,
                  let identifier = identifierComponents.first,
                  !identifier.isEmpty, identifier != ".", identifier != "..",
                  slicePaths[library.identifier] == nil
            else {
                throw XCFrameworkReferenceError.invalidMetadata(path, "invalid or duplicate LibraryIdentifier \(library.identifier)")
            }
            let components = library.path.pathString.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !library.architectures.isEmpty
            else {
                throw XCFrameworkReferenceError.invalidMetadata(path, "invalid library path or empty architectures in \(library.identifier)")
            }
            let normalizedPath: RelativePath
            if let frameworkIndex = components.firstIndex(where: { $0.hasSuffix(".framework") }) {
                normalizedPath = try RelativePath(validating: components[...frameworkIndex].joined(separator: "/"))
            } else {
                normalizedPath = library.path
            }
            guard let ext = normalizedPath.extension,
                  ["framework", "a", "dylib"].contains(ext),
                  let type = Xcode.filetype(extension: ext)
            else {
                throw XCFrameworkReferenceError.invalidMetadata(path, "unsupported native library \(library.path)")
            }
            if let productName, productName != normalizedPath.basename {
                throw XCFrameworkReferenceError.invalidMetadata(path, "libraries have inconsistent product names")
            }
            if let productType, productType != type {
                throw XCFrameworkReferenceError.invalidMetadata(path, "libraries have inconsistent product types")
            }
            productName = normalizedPath.basename
            productType = type
            let sdk = try Self.sdkName(for: library)
            librariesBySDK[sdk, default: []].append(library)
            let sliceRoot = path.appending(component: library.identifier)
            var values = [
                settingName: "$(SRCROOT)/" + sliceRoot.appending(normalizedPath).relative(to: sourceRootPath).pathString,
            ]
            for (suffix, symbolPath) in [
                ("_DEBUG_SYMBOLS", library.debugSymbolsPath),
                ("_BITCODE_SYMBOL_MAPS", library.bitcodeSymbolMapsPath),
            ] {
                guard let symbolPath else { continue }
                let components = symbolPath.pathString.split(separator: "/", omittingEmptySubsequences: false)
                guard !components.isEmpty,
                      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
                else {
                    throw XCFrameworkReferenceError.invalidMetadata(path, "invalid symbol directory in \(library.identifier)")
                }
                values[settingName + suffix] = "$(SRCROOT)/" + sliceRoot.appending(symbolPath)
                    .relative(to: sourceRootPath).pathString
            }
            slicePaths[library.identifier] = values
        }

        var result: [String: SettingValue] = [:]
        // Optional symbols must expand empty when a destination has no symbol directory.
        for name in settingNames.dropFirst() {
            result[name] = .string("")
            result[name + "_MACOS_NO"] = .string("")
            result[name + "_MACOS_YES"] = .string("")
        }
        for sdk in librariesBySDK.keys.sorted() {
            let libraries = librariesBySDK[sdk]!
            let sdkCondition = "[sdk=\(sdk == "maccatalyst" ? "macosx" : sdk)*]"
            var architectures: Set<BinaryArchitecture> = []
            for library in libraries {
                let supported = Set(library.architectures)
                guard architectures.isDisjoint(with: supported) else {
                    throw XCFrameworkReferenceError.invalidMetadata(path, "ambiguous architectures for \(sdk)")
                }
                architectures.formUnion(supported)
                for name in settingNames {
                    let key: String
                    switch sdk {
                    case "macosx": key = name + "_MACOS_NO"
                    case "maccatalyst": key = name + "_MACOS_YES"
                    default: key = name
                    }
                    let value = SettingValue.string(slicePaths[library.identifier]![name] ?? "")
                    if libraries.count == 1 {
                        result[key + sdkCondition] = value
                    } else {
                        for architecture in supported.sorted(by: { $0.rawValue < $1.rawValue }) {
                            result[key + sdkCondition + "[arch=\(architecture.rawValue)]"] = value
                        }
                    }
                }
            }
        }
        if librariesBySDK["macosx"] != nil || librariesBySDK["maccatalyst"] != nil {
            for name in settingNames {
                result[name + "[sdk=macosx*]"] = .string("$(\(name)_MACOS_$(IS_MACCATALYST))")
            }
        }
        // At least one validated library exists, so these names are independent of destination.
        name = productName!
        fileType = productType!
        settings = result
    }

    static func settingName(for path: AbsolutePath) -> String {
        "GEKO_XCFRAMEWORK_" + path.pathString.md5.uppercased()
    }

    static func sdkName(for library: XCFrameworkInfoPlist.Library) throws -> String {
        switch (library.platform, library.platformVariant) {
        case (.ios, nil): return "iphoneos"
        case (.ios, .simulator): return "iphonesimulator"
        case (.ios, .maccatalyst): return "maccatalyst"
        case (.tvos, nil): return "appletvos"
        case (.tvos, .simulator): return "appletvsimulator"
        case (.watchos, nil): return "watchos"
        case (.watchos, .simulator): return "watchsimulator"
        case (.visionos, nil): return "xros"
        case (.visionos, .simulator): return "xrsimulator"
        case (.macos, nil): return "macosx"
        default:
            throw XCFrameworkReferenceError.unsupportedPlatformVariant(library.identifier)
        }
    }
}
