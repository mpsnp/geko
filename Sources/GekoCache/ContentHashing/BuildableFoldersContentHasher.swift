import Foundation
import GekoCore
import GekoGraph
import GekoSupport
import ProjectDescription

public protocol BuildableFoldersContentHashing {
    func hash(
        buildableFolders: [BuildableFolder]
    ) throws -> (
        hash: String,
        buildableFolderHashes: [String: String],
        sourceHashes: [String: String]
    )
}

public final class BuildableFoldersContentHasher: BuildableFoldersContentHashing {
    private let contentHasher: ContentHashing
    private let relativePathConverter: RelativePathConverting
    private let fileHandler: FileHandling

    // MARK: - Init

    public init(
        contentHasher: ContentHashing,
        relativePathConverter: RelativePathConverting = RelativePathConverter(),
        fileHandler: FileHandling = FileHandler.shared
    ) {
        self.contentHasher = contentHasher
        self.relativePathConverter = relativePathConverter
        self.fileHandler = fileHandler
    }

    public func hash(
        buildableFolders: [BuildableFolder]
    ) throws -> (
        hash: String,
        buildableFolderHashes: [String: String],
        sourceHashes: [String: String]
    ) {
        var sourceHashes: [String: String] = [:]
        var folderHashes: [String: String] = [:]
        var relativeFolderHashes: [String: String] = [:]

        for folder in buildableFolders.sorted(by: { $0.path < $1.path }) {
            var fileHashes: [String: String] = [:]

            for file in try fileHandler.filesAndDirectoriesContained(in: folder.path) ?? [] {
                guard !fileHandler.isFolder(file),
                      !folder.exceptions.contains(where: { $0.isAncestorOfOrEqual(to: file) })
                else { continue }

                let sourceHash = try contentHasher.hash(path: file)
                fileHashes[file.relative(to: folder.path).pathString] = sourceHash
                sourceHashes[relativePathConverter.convert(file).pathString] = sourceHash
            }

            let folderHash = try contentHasher.hash(fileHashes)
            folderHashes[folder.path.pathString] = folderHash
            relativeFolderHashes[relativePathConverter.convert(folder.path).pathString] = folderHash
        }

        let finalHash = try contentHasher.hash(relativeFolderHashes)
        return (finalHash, folderHashes, sourceHashes)
    }
}
