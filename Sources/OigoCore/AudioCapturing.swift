import Foundation

public protocol AudioCapturing: AnyObject {
    func start(
        to url: URL,
        onBuffer: @escaping @Sendable () -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws

    func stop() throws

    func cancel()
}
