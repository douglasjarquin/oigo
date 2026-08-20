import Foundation

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
private struct OigoMacOSFloorCheck {
    static let requiredVersion = "26.0"
    static let productionSourceRoots = [
        "Sources/Oigo",
        "Sources/OigoCore",
        "Sources/OigoCapture",
        "Sources/OigoTranscription",
        "Sources/OigoInsertion",
        "Sources/OigoHotKey"
    ]

    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("SwiftPM platform is macOS 26.0", checkPackageManifest),
            ("Info.plist minimum system version is 26.0", checkInfoPlist),
            ("Xcode MACOSX_DEPLOYMENT_TARGET is 26.0", checkXcodeDeploymentTarget),
            ("every production source is in an Xcode sources phase", checkSourceMembership)
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
        let text = try String(contentsOf: repositoryRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
        let versions = try macOSPlatforms(in: text)
        guard versions == [requiredVersion] else {
            throw ContractFailure(
                message: "Package.swift platforms must be exactly macOS "
                    + requiredVersion
                    + ", found "
                    + versions.joined(separator: ", ")
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
        let objects = try xcodeObjects()
        let compiled = try compiledSwiftFileNames(in: objects)
        var missing: [String] = []
        var extra = compiled

        for relativeRoot in productionSourceRoots {
            let directory = root.appendingPathComponent(relativeRoot)
            let files = try swiftFiles(in: directory)
            guard !files.isEmpty else {
                throw ContractFailure(message: relativeRoot + " has no Swift sources")
            }
            for file in files {
                let name = file.lastPathComponent
                if compiled.contains(name) {
                    extra.remove(name)
                } else {
                    missing.append(relativeRoot + "/" + name)
                }
            }
        }

        if !missing.isEmpty || !extra.isEmpty {
            var parts: [String] = []
            if !missing.isEmpty {
                parts.append("missing from Xcode sources: " + missing.sorted().joined(separator: ", "))
            }
            if !extra.isEmpty {
                parts.append(
                    "compiled Swift names not in production sources: "
                        + extra.sorted().joined(separator: ", ")
                )
            }
            throw ContractFailure(message: parts.joined(separator: "; "))
        }
    }

    private static func macOSPlatforms(in manifest: String) throws -> [String] {
        guard let platformsKeyword = manifest.range(of: "platforms:") else {
            throw ContractFailure(message: "Package.swift has no platforms declaration")
        }
        let fromKeyword = manifest[platformsKeyword.upperBound...]
        guard let arrayStart = fromKeyword.firstIndex(of: "[") else {
            throw ContractFailure(message: "Package.swift platforms is not an array")
        }
        let afterStart = fromKeyword.index(after: arrayStart)
        guard let arrayEnd = fromKeyword[afterStart...].firstIndex(of: "]") else {
            throw ContractFailure(message: "Package.swift platforms array is unclosed")
        }
        let body = String(fromKeyword[afterStart..<arrayEnd])
        if body.contains(".iOS") || body.contains(".tvOS") || body.contains(".watchOS") || body.contains(".visionOS") {
            throw ContractFailure(message: "Package.swift platforms must declare only macOS")
        }

        var versions: [String] = []
        let stringPattern = try NSRegularExpression(pattern: #"\.macOS\("([^"]+)"\)"#)
        let stringMatches = stringPattern.matches(
            in: body,
            range: NSRange(body.startIndex..., in: body)
        )
        for match in stringMatches {
            guard let range = Range(match.range(at: 1), in: body) else { continue }
            versions.append(String(body[range]))
        }

        let enumPattern = try NSRegularExpression(pattern: #"\.macOS\(\.v(\d+)(?:_(\d+))?(?:_(\d+))?\)"#)
        let enumMatches = enumPattern.matches(
            in: body,
            range: NSRange(body.startIndex..., in: body)
        )
        for match in enumMatches {
            guard let majorRange = Range(match.range(at: 1), in: body) else { continue }
            let major = String(body[majorRange])
            let minor: String
            if match.range(at: 2).location != NSNotFound, let minorRange = Range(match.range(at: 2), in: body) {
                minor = String(body[minorRange])
            } else {
                minor = "0"
            }
            versions.append(major + "." + minor)
        }

        guard !versions.isEmpty else {
            throw ContractFailure(message: "Package.swift platforms array contains no macOS entries")
        }
        return versions
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

    private static func compiledSwiftFileNames(in objects: [String: Any]) throws -> Set<String> {
        var names = Set<String>()
        for (_, value) in objects {
            guard let phase = value as? [String: Any],
                  phase["isa"] as? String == "PBXSourcesBuildPhase",
                  let files = phase["files"] as? [String] else {
                continue
            }
            for buildFileID in files {
                guard let buildFile = objects[buildFileID] as? [String: Any],
                      let fileRefID = buildFile["fileRef"] as? String,
                      let fileRef = objects[fileRefID] as? [String: Any],
                      let path = fileRef["path"] as? String else {
                    throw ContractFailure(
                        message: "Xcode sources phase entry " + buildFileID + " is not a Swift file reference"
                    )
                }
                guard path.hasSuffix(".swift") else {
                    throw ContractFailure(message: "Xcode sources phase includes a non-Swift file: " + path)
                }
                names.insert(URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        guard !names.isEmpty else {
            throw ContractFailure(message: "Oigo.xcodeproj has no Swift sources phases")
        }
        return names
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ContractFailure(message: "could not enumerate " + directory.path)
        }
        for case let file as URL in enumerator {
            guard file.pathExtension == "swift" else { continue }
            files.append(file)
        }
        return files
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
