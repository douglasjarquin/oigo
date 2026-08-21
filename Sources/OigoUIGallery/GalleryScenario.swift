import AppKit
import ObjectiveC

@MainActor
@objcMembers
class GalleryScenario: NSObject {
    class var scenarioName: String {
        fatalError("scenario subclasses must provide a name")
    }

    class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        fatalError("scenario subclasses must create a window")
    }
}

@MainActor
enum GalleryScenarioRegistry {
    static func discover() -> [String: GalleryScenario.Type] {
        let expectedSuperclass: AnyClass = GalleryScenario.self
        let count = objc_getClassList(nil, 0)
        let classes = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(count))
        defer { classes.deallocate() }
        let loadedCount = objc_getClassList(AutoreleasingUnsafeMutablePointer(classes), count)
        var scenarios: [String: GalleryScenario.Type] = [:]
        for index in 0..<Int(loadedCount) {
            guard let candidate = classes[index], class_getSuperclass(candidate) === expectedSuperclass,
                  let scenarioType = candidate as? GalleryScenario.Type else {
                continue
            }
            scenarios[scenarioType.scenarioName] = scenarioType
        }
        return scenarios
    }
}
