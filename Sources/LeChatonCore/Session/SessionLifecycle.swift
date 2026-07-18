import Foundation

public enum SessionLifecycle: Equatable, Hashable, Sendable {
    case unloaded
    case loadingHistory
    case idle
    case prompting
    case cancelling
    case replacingThread
    case validatingExecutable
    case swappingExecutable
    case reloadRequired
    case cleanupRequired
    case swapFailed
    case failed(String)

    public var permitsInteractivePrompt: Bool { self == .idle }
}
