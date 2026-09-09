import Foundation
import GekoCore
import GekoGraph
import GekoSupport
import ProjectDescription
import XCTest
@testable import GekoCache

final class BuildableFoldersContentHasherTests: XCTestCase {
    func test_contentAdditionRemovalRenameAndExceptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("A.swift")
        let excluded = root.appendingPathComponent("Excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let ignored = excluded.appendingPathComponent("Ignored.swift")
        try "ignored".write(to: ignored, atomically: true, encoding: .utf8)
        let subject = BuildableFoldersContentHasher(contentHasher: ContentHasher())
        let folder = BuildableFolder(.init(root.path), exceptions: [.init(excluded.path)])
        func hash() throws -> String { try subject.hash(buildableFolders: [folder]).hash }
        let empty = try hash()
        try "let a = 1".write(to: file, atomically: true, encoding: .utf8)
        let added = try hash()
        XCTAssertNotEqual(empty, added)
        try "let a = 2".write(to: file, atomically: true, encoding: .utf8)
        let changed = try hash()
        XCTAssertNotEqual(added, changed)
        try "changed ignored".write(to: ignored, atomically: true, encoding: .utf8)
        XCTAssertEqual(changed, try hash())
        let renamed = root.appendingPathComponent("B.swift")
        try FileManager.default.moveItem(at: file, to: renamed)
        XCTAssertNotEqual(changed, try hash())
        try FileManager.default.removeItem(at: renamed)
        XCTAssertEqual(empty, try hash())
    }

    func test_noExceptionsAndMultipleFoldersRetainAllSourceHashes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var folders: [BuildableFolder] = []
        for name in ["Sources", "PrimarySources"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "let value = 1".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            folders.append(BuildableFolder(.init(dir.path), exceptions: []))
        }
        let subject = BuildableFoldersContentHasher(contentHasher: ContentHasher())
        let result = try subject.hash(buildableFolders: folders)
        XCTAssertEqual(result.sourceHashes.count, 2)
        XCTAssertEqual(result.buildableFolderHashes.count, 2)
        XCTAssertEqual(result.hash, try subject.hash(buildableFolders: folders.reversed()).hash)
    }
}
