import GekoCore
import ProjectDescription
import XcodeProj

/// Native slice references do not run ProcessXCFramework, so copy its optional symbols explicitly.
final class XCFrameworkSymbolsGenerator {
    func generate(
        dependencies: Set<GraphDependencyReference>,
        pbxTarget: PBXTarget,
        pbxproj: PBXProj
    ) {
        var commands: [String] = []
        let symbolDependencies = dependencies.lazy.filter { dependency in
            guard case let .xcframework(_, plist, _, _, _, _) = dependency else { return false }
            return plist.libraries.contains { $0.debugSymbolsPath != nil || $0.bitcodeSymbolMapsPath != nil }
        }.sorted()
        for dependency in symbolDependencies {
            guard case let .xcframework(path, plist, _, _, _, _) = dependency else { continue }
            let name = XCFrameworkReference.settingName(for: path)
            if plist.libraries.contains(where: { $0.debugSymbolsPath != nil }) {
                commands.append("copy_symbols \"${\(name)_DEBUG_SYMBOLS:-}\" \"${DWARF_DSYM_FOLDER_PATH}\"")
            }
            if plist.libraries.contains(where: { $0.bitcodeSymbolMapsPath != nil }) {
                commands.append("copy_symbols \"${\(name)_BITCODE_SYMBOL_MAPS:-}\" \"${BUILT_PRODUCTS_DIR}\"")
            }
        }
        guard !commands.isEmpty else { return }
        let phase = PBXShellScriptBuildPhase(name: "Copy XCFramework Symbols")
        phase.shellPath = "/bin/bash"
        phase.shellScript = """
        set -euo pipefail
        copy_symbols() {
            if [[ -n "$1" ]]; then
                mkdir -p "$2"
                rsync -a "$1/" "$2/"
            fi
        }
        \(commands.joined(separator: "\n"))
        """
        // Optional symbol directories differ by destination. The script checks the selected setting,
        // and rsync's atomic file replacement permits consumers to share the products directory.
        phase.alwaysOutOfDate = true
        pbxproj.add(object: phase)
        pbxTarget.buildPhases.append(phase)
    }
}
