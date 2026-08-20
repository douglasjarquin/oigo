import Foundation

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

private struct DumpPackage: Decodable {
    struct Platform: Decodable {
        let platformName: String
        let version: String
    }

    let platforms: [Platform]
}

@main
private struct OigoMacOSFloorCheck {
    static let requiredVersion = "26.0"

    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("SwiftPM platform is macOS 26.0", checkPackageManifest),
            ("Info.plist minimum system version is 26.0", checkInfoPlist),
            ("Xcode MACOSX_DEPLOYMENT_TARGET is 26.0", checkXcodeDeploymentTarget),
            ("every production source is compiled into the correct Xcode target", checkSourceMembership)
        ]

        var failures = 0
        for (name, test) in cases {
            do {
                try test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        if failures == 0 {
            print("GREEN: macOS 26 floor metadata")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func checkPackageManifest() throws {
        let root = try repositoryRoot()
        let stdout = try runCommand(
            executable: "/usr/bin/env",
            arguments: ["swift", "package", "dump-package"],
            currentDirectory: root
        )
        let dump: DumpPackage
        do {
            dump = try JSONDecoder().decode(DumpPackage.self, from: Data(stdout.utf8))
        } catch {
            throw ContractFailure(
                message: "swift package dump-package JSON could not be decoded: "
                    + error.localizedDescription
            )
        }
        let versions = dump.platforms.map { platform in
            platform.platformName + " " + platform.version
        }
        guard dump.platforms.count == 1,
              dump.platforms[0].platformName.lowercased() == "macos",
              dump.platforms[0].version == requiredVersion else {
            throw ContractFailure(
                message: "swift package dump-package platforms must be exactly macos "
                    + requiredVersion
                    + ", found "
                    + (versions.isEmpty ? "<none>" : versions.joined(separator: ", "))
            )
        }
    }

    private static func checkInfoPlist() throws {
        let url = try repositoryRoot().appendingPathComponent("Oigo/Info.plist")
        let plist = try loadPlist(url)
        guard let rawVersion = plist["LSMinimumSystemVersion"] else {
            throw ContractFailure(message: "Oigo/Info.plist is missing LSMinimumSystemVersion")
        }
        let version = try stringSetting(rawVersion, key: "LSMinimumSystemVersion")
        try assertSupportedVersion(version, source: "Oigo/Info.plist LSMinimumSystemVersion")
    }

    private static func checkXcodeDeploymentTarget() throws {
        let objects = try xcodeObjects()
        var seen = 0
        for (objectID, value) in objects {
            guard let object = value as? [String: Any],
                  object["isa"] as? String == "XCBuildConfiguration" else {
                continue
            }
            let name = object["name"] as? String ?? objectID
            guard let settings = object["buildSettings"] as? [String: Any] else {
                throw ContractFailure(message: "Xcode configuration " + name + " has no buildSettings")
            }
            guard let rawVersion = settings["MACOSX_DEPLOYMENT_TARGET"] else {
                throw ContractFailure(
                    message: "Xcode configuration " + name + " is missing MACOSX_DEPLOYMENT_TARGET"
                )
            }
            let version = try stringSetting(rawVersion, key: "MACOSX_DEPLOYMENT_TARGET")
            try assertSupportedVersion(version, source: "Xcode configuration " + name)
            seen += 1
        }
        guard seen > 0 else {
            throw ContractFailure(message: "Oigo.xcodeproj has no XCBuildConfiguration objects")
        }
    }

    private static func checkSourceMembership() throws {
        let root = try repositoryRoot()
        let script = root.appendingPathComponent("Scripts/check-xcode-source-membership.py")
        _ = try runCommand(
            executable: "/usr/bin/python3",
            arguments: [script.path, root.path],
            currentDirectory: root
        )
    }

    private static func assertSupportedVersion(_ version: String, source: String) throws {
        guard version == requiredVersion else {
            throw ContractFailure(
                message: source + " must be " + requiredVersion + ", found " + version
            )
        }
    }

    private static func stringSetting(_ value: Any, key: String) throws -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            if doubleValue.rounded() == doubleValue {
                return String(Int(doubleValue)) + ".0"
            }
            return String(doubleValue)
        }
        throw ContractFailure(message: key + " is not a string or number")
    }

    private static func xcodeObjects() throws -> [String: Any] {
        let plist = try loadPlist(repositoryRoot().appendingPathComponent("Oigo.xcodeproj/project.pbxproj"))
        guard let objects = plist["objects"] as? [String: Any] else {
            throw ContractFailure(message: "Oigo.xcodeproj project.pbxproj has no objects dictionary")
        }
        return objects
    }

    private static func loadPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw ContractFailure(
                message: "could not parse " + url.lastPathComponent + " as a plist: " + error.localizedDescription
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw ContractFailure(message: url.lastPathComponent + " is not a dictionary plist")
        }
        return dictionary
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ContractFailure(message: "could not start " + executable + ": " + error.localizedDescription)
        }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let details = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ContractFailure(
                message: arguments.joined(separator: " ")
                    + " exited "
                    + String(process.terminationStatus)
                    + (details.isEmpty ? "" : ": " + details)
            )
        }
        return output
    }

    private static func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            let package = url.appendingPathComponent("Package.swift")
            let info = url.appendingPathComponent("Oigo/Info.plist")
            let project = url.appendingPathComponent("Oigo.xcodeproj/project.pbxproj")
            if FileManager.default.fileExists(atPath: package.path),
               FileManager.default.fileExists(atPath: info.path),
               FileManager.default.fileExists(atPath: project.path) {
                return url
            }
        }
        throw ContractFailure(message: "could not locate the repository root from " + #filePath)
    }
}
