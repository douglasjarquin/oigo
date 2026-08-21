import AppKit
import ApplicationServices
import Foundation

@MainActor
public enum AccessibilityHUDGeometryCapture {
    public typealias Capture = @MainActor (UInt64) -> HUDTargetGeometrySnapshot

    public static func makeSession(capture syntheticCapture: Capture? = nil) -> HUDTargetGeometrySession {
        HUDTargetGeometrySession(capture: syntheticCapture ?? Self.capture(generation:))
    }

    public static func capture(generation: UInt64) -> HUDTargetGeometrySnapshot {
        let token = UUID()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let processIdentifier = frontmostApplication?.processIdentifier ?? 0
        let mainDisplayID = displayID(for: NSScreen.main)
        guard generation > 0, processIdentifier > 0 else {
            return HUDTargetGeometrySnapshot(
                generation: generation,
                captureToken: token,
                fieldFrame: nil,
                windowFrame: nil,
                targetDisplayID: mainDisplayID
            )
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        guard let focusedElement = copyElement(kAXFocusedUIElementAttribute, from: application) else {
            return HUDTargetGeometrySnapshot(
                generation: generation,
                captureToken: token,
                fieldFrame: nil,
                windowFrame: nil,
                targetDisplayID: mainDisplayID
            )
        }

        let fieldFrame = frame(of: focusedElement)
        let windowFrame = copyElement(kAXWindowAttribute, from: focusedElement).flatMap(frame(of:))
        let targetDisplayID = displayID(containing: fieldFrame ?? windowFrame) ?? mainDisplayID
        return HUDTargetGeometrySnapshot(
            generation: generation,
            captureToken: token,
            fieldFrame: fieldFrame,
            windowFrame: windowFrame,
            targetDisplayID: targetDisplayID
        )
    }

    public static func displayGeometry() -> [HUDDisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            return HUDDisplayGeometry(id: id, visibleFrame: rect(screen.visibleFrame))
        }
    }

    private static func copyElement(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func frame(of element: AXUIElement) -> HUDRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }
        let frame = HUDRect(
            x: Double(position.x),
            y: Double(position.y),
            width: Double(size.width),
            height: Double(size.height)
        )
        return frame.isValid ? frame : nil
    }

    private static func pointAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGPoint? {
        guard let value = copyValue(attribute, from: element, type: .cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGSize? {
        guard let value = copyValue(attribute, from: element, type: .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func copyValue(
        _ attribute: String,
        from element: AXUIElement,
        type: AXValueType
    ) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    private static func displayID(containing frame: HUDRect?) -> UInt32? {
        guard let frame else { return nil }
        return NSScreen.screens
            .compactMap { screen -> (UInt32, Double)? in
                guard let id = displayID(for: screen) else { return nil }
                let intersection = rect(screen.frame).intersectionArea(with: frame)
                return intersection > 0 ? (id, intersection) : nil
            }
            .max { left, right in
                left.1 == right.1 ? left.0 > right.0 : left.1 < right.1
            }?.0
    }

    private static func displayID(for screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    private static func rect(_ rect: NSRect) -> HUDRect {
        HUDRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }
}
