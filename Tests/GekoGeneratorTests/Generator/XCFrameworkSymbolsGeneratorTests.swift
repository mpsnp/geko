import Foundation
import GekoCore
import GekoCoreTesting
import GekoGraph
import GekoGraphTesting
import ProjectDescription
import XCTest
import XcodeProj
@testable import GekoGenerator
@testable import GekoSupportTesting

final class XCFrameworkSymbolsGeneratorTests: GekoTestCase {
    func test_selectedSymbolsAreCopiedWithoutDeletingOtherProducts() throws {
        let root = try temporaryPath()
        let source = root.appending(component: "selected symbols")
        let destination = root.appending(component: "products")
        try fileHandler.createFolder(source.appending(component: "Product.framework.dSYM"))
        try fileHandler.createFolder(destination)
        try fileHandler.write("selected UUID", path: source.appending(components: "Product.framework.dSYM", "symbol"), atomically: true)
        try fileHandler.write("other product", path: destination.appending(component: "unrelated"), atomically: true)
        let container = root.appending(component: "Target.xcframework")
        let script = try symbolScript(container: container)
        let variable = XCFrameworkReference.settingName(for: container) + "_DEBUG_SYMBOLS"

        try execute(script, environment: [variable: source.pathString, "DWARF_DSYM_FOLDER_PATH": destination.pathString])

        XCTAssertEqual(try fileHandler.readTextFile(destination.appending(components: "Product.framework.dSYM", "symbol")), "selected UUID")
        XCTAssertEqual(try fileHandler.readTextFile(destination.appending(component: "unrelated")), "other product")
        XCTAssertEqual(try fileHandler.readTextFile(source.appending(components: "Product.framework.dSYM", "symbol")), "selected UUID")
    }

    func test_destinationWithoutSymbolsDoesNotCreateProductsDirectory() throws {
        let root = try temporaryPath()
        let destination = root.appending(component: "products")
        let container = root.appending(component: "Target.xcframework")
        let script = try symbolScript(container: container)
        let variable = XCFrameworkReference.settingName(for: container) + "_DEBUG_SYMBOLS"

        try execute(script, environment: [variable: "", "DWARF_DSYM_FOLDER_PATH": destination.pathString])

        XCTAssertFalse(fileHandler.exists(destination))
    }

    private func symbolScript(container: AbsolutePath) throws -> String {
        let library = XCFrameworkInfoPlist.Library(
            identifier: "ios-arm64",
            path: "Product.framework",
            mergeable: false,
            architectures: [.arm64],
            platform: .ios,
            platformVariant: nil,
            debugSymbolsPath: "dSYMs"
        )
        let dependency = GraphDependencyReference.testXCFramework(
            path: container, infoPlist: .test(libraries: [library])
        )
        let target = PBXNativeTarget(name: "Client")
        let pbxproj = PBXProj()
        XCFrameworkSymbolsGenerator().generate(dependencies: [dependency], pbxTarget: target, pbxproj: pbxproj)
        return try XCTUnwrap(pbxproj.shellScriptBuildPhases.first?.shellScript)
    }

    private func execute(_ script: String, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, selected in selected }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
    }
}
