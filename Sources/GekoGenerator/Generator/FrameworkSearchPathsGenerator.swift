import Foundation
import GekoCore
import GekoGraph
import GekoSupport
import ProjectDescription

enum FrameworkSearchPathsGeneratorError: FatalError, Equatable {
    case collision(path: AbsolutePath, first: AbsolutePath, second: AbsolutePath)
    case unownedPath(AbsolutePath)
    case unsafePath(String)
    case invalidManifest(AbsolutePath)

    var type: ErrorType { .abort }

    var description: String {
        switch self {
        case let .collision(path, first, second):
            return "Framework search index collision at \(path.pathString): \(first.pathString) and \(second.pathString). Use distinct framework product names for artifacts searched on the same SDK."
        case let .unownedPath(path):
            return "Cannot update the framework search index at \(path.pathString): it contains an unowned or modified item. Move that item out of the index and regenerate."
        case let .unsafePath(path):
            return "Cannot index the unsafe framework or SDK path \(path)."
        case let .invalidManifest(path):
            return "Cannot read the framework search index ownership manifest at \(path.pathString). Move the index aside and regenerate; its existing contents were preserved."
        }
    }
}

/// A workspace-wide index of only the frameworks searchable in the current graph.
/// The manifest owns individual links, never directories or their other contents.
final class FrameworkSearchPathsGenerator {
    struct SliceSearchPath {
        let sdk: String
        let architecture: String?
        let libraryPath: RelativePath
    }

    static func sliceSearchPaths(infoPlist: XCFrameworkInfoPlist) throws -> [SliceSearchPath] {
        // Map-only fixtures remain useful for index ownership tests.
        guard !infoPlist.libraries.isEmpty else {
            return infoPlist.searchPathPlatforms.keys.sorted().map {
                SliceSearchPath(sdk: $0, architecture: nil, libraryPath: infoPlist.searchPathPlatforms[$0]!)
            }
        }
        var librariesBySDK: [String: [XCFrameworkInfoPlist.Library]] = [:]
        for library in infoPlist.libraries {
            let sdk = try XCFrameworkReference.sdkName(for: library)
            librariesBySDK[sdk, default: []].append(library)
        }
        var slices: [SliceSearchPath] = []
        for sdk in librariesBySDK.keys.sorted() {
            let libraries = librariesBySDK[sdk]!.sorted {
                ($0.identifier, $0.path.pathString) < ($1.identifier, $1.path.pathString)
            }
            for library in libraries {
                let components = library.path.pathString.split(separator: "/")
                let libraryPath: RelativePath
                if let framework = components.firstIndex(where: { $0.hasSuffix(".framework") }) {
                    libraryPath = try RelativePath(validating: components[...framework].joined(separator: "/"))
                } else {
                    libraryPath = library.path
                }
                let path = try RelativePath(validating: library.identifier).appending(libraryPath)
                if libraries.count == 1 {
                    slices.append(SliceSearchPath(sdk: sdk, architecture: nil, libraryPath: path))
                } else {
                    for architecture in Set(library.architectures.map(\.rawValue)).sorted() {
                        slices.append(SliceSearchPath(sdk: sdk, architecture: architecture, libraryPath: path))
                    }
                }
            }
        }
        return slices
    }

    private struct Manifest: Codable {
        let version: Int
        let links: [String: String]
    }

    private let fileManager: FileManager
    private let manifestName = ".manifest.json"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func rootPath(workspacePath: AbsolutePath) -> AbsolutePath {
        workspacePath.appending(components: ".geko", "FrameworkSearchPaths")
    }

    func generate(graphTraverser: GraphTraversing) throws {
        let root = Self.rootPath(workspacePath: graphTraverser.path)
        var dependencies = Set<GraphDependencyReference>()
        for target in graphTraverser.allTargets() {
            dependencies.formUnion(try graphTraverser.searchablePathDependencies(path: target.path, name: target.target.name))
        }

        var links: [String: String] = [:]
        for dependency in dependencies.sorted() {
            switch dependency {
            case let .framework(path, _, _, _, _, _, _, _, _):
                try addLink(to: path, sdk: nil, root: root, links: &links)
            case let .xcframework(path, plist, _, _, _, _):
                for slice in try Self.sliceSearchPaths(infoPlist: plist) {
                    let libraryPath = path.appending(slice.libraryPath)
                    let framework = libraryPath.extension == "framework" ? libraryPath : libraryPath.parentDirectory
                    // Static library slices keep their original library/include search paths.
                    if framework.extension == "framework" {
                        try addLink(to: framework, sdk: slice.sdk, architecture: slice.architecture, root: root, links: &links)
                    }
                }
            default:
                continue
            }
        }

        // Source-only graphs need no index; an existing one still needs stale-link cleanup.
        if links.isEmpty, try itemType(at: root) == nil { return }

        // Check every parent before reading or writing beneath it; never follow an index directory symlink.
        try validateDirectory(root.parentDirectory)
        try validateDirectory(root)
        let manifestPath = root.appending(component: manifestName)
        let previous = try readManifest(at: manifestPath)
        let names = Set(previous.keys).union(links.keys).sorted()
        for name in names {
            let path = root.appending(try RelativePath(validating: name))
            try validateParents(of: path, root: root)
            guard let type = try itemType(at: path) else { continue }
            guard type == .typeSymbolicLink,
                  let previousDestination = previous[name],
                  try fileManager.destinationOfSymbolicLink(atPath: path.pathString) == previousDestination
            else {
                throw FrameworkSearchPathsGeneratorError.unownedPath(path)
            }
        }

        try fileManager.createDirectory(atPath: root.pathString, withIntermediateDirectories: true)
        for name in names {
            let path = root.appending(try RelativePath(validating: name))
            let existingType = try itemType(at: path)
            if let destination = links[name] {
                if existingType != nil, previous[name] == destination { continue }
                if existingType != nil { try fileManager.removeItem(atPath: path.pathString) }
                try fileManager.createDirectory(atPath: path.parentDirectory.pathString, withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: path.pathString, withDestinationPath: destination)
            } else if existingType != nil {
                try fileManager.removeItem(atPath: path.pathString)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Manifest(version: 1, links: links))
        try data.write(to: URL(fileURLWithPath: manifestPath.pathString), options: .atomic)
    }

    private func addLink(
        to framework: AbsolutePath,
        sdk: String?,
        architecture: String? = nil,
        root: AbsolutePath,
        links: inout [String: String]
    ) throws {
        guard isFrameworkName(framework.basename), sdk.map(isSDKName) ?? true,
              architecture.map(isSDKName) ?? true else {
            throw FrameworkSearchPathsGeneratorError.unsafePath(architecture ?? sdk ?? framework.pathString)
        }
        let name = ([sdk, architecture].compactMap { $0 } + [framework.basename]).joined(separator: "/")
        let conflict: (key: String, value: String)?
        if let destination = links[name], destination != framework.pathString {
            conflict = (name, destination)
        } else if sdk != nil, let destination = links[framework.basename], destination != framework.pathString {
            conflict = (framework.basename, destination)
        } else if let sdk, architecture != nil, let destination = links["\(sdk)/\(framework.basename)"], destination != framework.pathString {
            conflict = ("\(sdk)/\(framework.basename)", destination)
        } else if let sdk, architecture == nil {
            conflict = links.lazy
                .filter { $0.key.hasPrefix("\(sdk)/") && $0.key.hasSuffix("/\(framework.basename)") && $0.value != framework.pathString }
                .min { $0.key < $1.key }
        } else if sdk == nil {
            let suffix = "/\(framework.basename)"
            conflict = links.lazy
                .filter { $0.key.hasSuffix(suffix) && $0.value != framework.pathString }
                .min { $0.key < $1.key }
        } else {
            conflict = nil
        }
        if let conflict {
            let artifacts = [conflict.value, framework.pathString].sorted()
            let collisionName = sdk == nil ? conflict.key : name
            throw FrameworkSearchPathsGeneratorError.collision(
                path: root.appending(try RelativePath(validating: collisionName)),
                first: try AbsolutePath(validating: artifacts[0]),
                second: try AbsolutePath(validating: artifacts[1])
            )
        }
        links[name] = framework.pathString
    }

    private func readManifest(at path: AbsolutePath) throws -> [String: String] {
        guard let type = try itemType(at: path) else { return [:] }
        guard type == .typeRegular else { throw FrameworkSearchPathsGeneratorError.unownedPath(path) }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path.pathString)))
        } catch {
            throw FrameworkSearchPathsGeneratorError.invalidManifest(path)
        }
        guard manifest.version == 1 else { throw FrameworkSearchPathsGeneratorError.invalidManifest(path) }
        for (name, destination) in manifest.links {
            let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard (components.count == 1 && isFrameworkName(components[0])) ||
                (components.count == 2 && isSDKName(components[0]) && isFrameworkName(components[1])) ||
                (components.count == 3 && isSDKName(components[0]) && isSDKName(components[1]) && isFrameworkName(components[2])),
                let absoluteDestination = try? AbsolutePath(validating: destination),
                absoluteDestination.pathString == destination
            else {
                throw FrameworkSearchPathsGeneratorError.invalidManifest(path)
            }
        }
        return manifest.links
    }

    private func validateParents(of path: AbsolutePath, root: AbsolutePath) throws {
        var parents: [AbsolutePath] = []
        var parent = path.parentDirectory
        while parent != root {
            parents.append(parent)
            parent = parent.parentDirectory
        }
        for directory in parents.reversed() {
            try validateDirectory(directory)
        }
    }

    private func validateDirectory(_ path: AbsolutePath) throws {
        if let type = try itemType(at: path), type != .typeDirectory {
            throw FrameworkSearchPathsGeneratorError.unownedPath(path)
        }
    }

    private func itemType(at path: AbsolutePath) throws -> FileAttributeType? {
        do {
            return try fileManager.attributesOfItem(atPath: path.pathString)[.type] as? FileAttributeType
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }

    private func isFrameworkName(_ name: String) -> Bool {
        name.hasSuffix(".framework") && name != ".framework" &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private func isSDKName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
