public struct AppDelegateFinishIntent {
    private var requestedHandle: AppOperationHandle?

    public init() {}

    public mutating func request(for handle: AppOperationHandle) {
        requestedHandle = handle
    }

    public mutating func consumeAfterSuccessfulStart(for handle: AppOperationHandle) -> Bool {
        guard requestedHandle == handle else {
            return false
        }
        requestedHandle = nil
        return true
    }

    public mutating func clear(for handle: AppOperationHandle) {
        guard requestedHandle == handle else {
            return
        }
        requestedHandle = nil
    }

    public mutating func clear() {
        requestedHandle = nil
    }
}
