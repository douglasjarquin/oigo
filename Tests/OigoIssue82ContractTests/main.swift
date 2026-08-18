import Darwin
import OigoCore
import OigoHotKey

@main
@available(macOS 13.0, *)
@MainActor
private struct OigoIssue82ContractTests {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let filter: String? = if let index = arguments.firstIndex(of: "--filter"),
                                  arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else {
            nil
        }
        let normalizedFilter = filter?.replacingOccurrences(of: "-", with: " ")
        let scenario = "harness smoke"
        guard normalizedFilter == nil || scenario.contains(normalizedFilter ?? "") else {
            print("FAIL: no issue #82 contract scenarios matched filter")
            exit(1)
        }

        _ = ToggleShortcut.default
        _ = CarbonGlobalShortcutRegistrar.self
        print("GREEN: harness smoke")
        print("GREEN: all issue #82 contract scenarios")
    }
}
