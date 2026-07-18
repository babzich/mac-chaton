import Darwin
import Foundation

public struct ProcessCleanupReport: Equatable, Sendable {
    public let signalled: Set<ProcessIdentity>
    public let forceKilled: Set<ProcessIdentity>
    public let permissionDenied: Set<ProcessIdentity>
    public let survivors: Set<ProcessIdentity>

    public init(
        signalled: Set<ProcessIdentity>,
        forceKilled: Set<ProcessIdentity>,
        permissionDenied: Set<ProcessIdentity> = [],
        survivors: Set<ProcessIdentity>
    ) {
        self.signalled = signalled
        self.forceKilled = forceKilled
        self.permissionDenied = permissionDenied
        self.survivors = survivors
    }
}

/// Tracks a descendant closure only after a process scan proves an ancestry
/// chain to the runtime root or another already-verified identity.
public actor ProcessTreeTerminator {
    private struct TrackedProcess: Sendable {
        var latestSnapshot: ProcessSnapshot
        let verifiedParent: ProcessIdentity?
    }

    public let root: ProcessIdentity

    private let system: any ProcessSystem
    private var tracked: [ProcessIdentity: TrackedProcess] = [:]

    public init(root: ProcessIdentity) {
        self.root = root
        system = DarwinProcessSystem()
    }

    init(root: ProcessIdentity, system: any ProcessSystem) {
        self.root = root
        self.system = system
    }

    /// Refreshes current routing evidence while retaining the identity and
    /// verified ancestry of processes that later reparent or change groups.
    @discardableResult
    public func refresh() -> Set<ProcessIdentity> {
        let snapshots = system.allSnapshots()
        var byPID: [pid_t: ProcessSnapshot] = [:]
        for snapshot in snapshots {
            byPID[snapshot.identity.pid] = snapshot
        }

        if let rootSnapshot = byPID[root.pid], rootSnapshot.identity == root {
            if var existing = tracked[root] {
                existing.latestSnapshot = rootSnapshot
                tracked[root] = existing
            } else {
                tracked[root] = TrackedProcess(latestSnapshot: rootSnapshot, verifiedParent: nil)
            }
        }

        // A retained identity remains owned after reparenting or a PGID change,
        // but a reused PID cannot seed discovery for an unrelated process tree.
        for identity in Array(tracked.keys) {
            if let current = byPID[identity.pid], current.identity == identity {
                tracked[identity]?.latestSnapshot = current
            }
        }

        var ownedByPID: [pid_t: ProcessIdentity] = [:]
        for identity in tracked.keys {
            if byPID[identity.pid]?.identity == identity {
                ownedByPID[identity.pid] = identity
            }
        }

        var discovered = true
        while discovered {
            discovered = false
            for snapshot in snapshots where ownedByPID[snapshot.identity.pid] == nil {
                guard let parent = ownedByPID[snapshot.parentPID] else { continue }
                tracked[snapshot.identity] = TrackedProcess(
                    latestSnapshot: snapshot,
                    verifiedParent: parent
                )
                ownedByPID[snapshot.identity.pid] = snapshot.identity
                discovered = true
            }
        }

        return Set(liveSnapshots().map(\.identity))
    }

    public func liveIdentities() -> Set<ProcessIdentity> {
        _ = refresh()
        return Set(liveSnapshots().map(\.identity))
    }

    public func liveDescendantIdentities() -> Set<ProcessIdentity> {
        var live = liveIdentities()
        live.remove(root)
        return live
    }

    public func rootIsAlive() -> Bool {
        system.snapshot(pid: root.pid)?.identity == root
    }

    /// Signals verified identities bottom-up. The TERM wait and KILL
    /// confirmation windows both rescan so late children of the root or any
    /// still-live tracked descendant are incorporated even after reparenting.
    ///
    /// This implementation deliberately uses identity-checked per-PID signals.
    /// It never calls `killpg`, so a mixed or protected process group cannot
    /// cause LeChaton or its test runner to be signalled.
    public func terminate(
        gracePeriod: Duration = .seconds(2),
        rescanInterval: Duration = .milliseconds(25),
        killConfirmationPeriod: Duration = .milliseconds(250)
    ) async -> ProcessCleanupReport {
        let clock = ContinuousClock()
        var termAttempted: Set<ProcessIdentity> = []
        var killAttempted: Set<ProcessIdentity> = []
        var termSignalled: Set<ProcessIdentity> = []
        var forceKilled: Set<ProcessIdentity> = []
        var permissionDenied: Set<ProcessIdentity> = []

        _ = refresh()
        signalLive(
            SIGTERM,
            attempted: &termAttempted,
            sent: &termSignalled,
            permissionDenied: &permissionDenied
        )

        let termDeadline = clock.now.advanced(by: gracePeriod)
        while clock.now < termDeadline {
            _ = refresh()
            signalLive(
                SIGTERM,
                attempted: &termAttempted,
                sent: &termSignalled,
                permissionDenied: &permissionDenied
            )
            if liveSnapshots().isEmpty { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: rescanInterval)
        }

        _ = refresh()
        signalLive(
            SIGKILL,
            attempted: &killAttempted,
            sent: &forceKilled,
            permissionDenied: &permissionDenied
        )

        let killDeadline = clock.now.advanced(by: killConfirmationPeriod)
        while clock.now < killDeadline {
            _ = refresh()
            signalLive(
                SIGKILL,
                attempted: &killAttempted,
                sent: &forceKilled,
                permissionDenied: &permissionDenied
            )
            if liveSnapshots().isEmpty { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: rescanInterval)
        }

        _ = refresh()
        return ProcessCleanupReport(
            signalled: termSignalled,
            forceKilled: forceKilled,
            permissionDenied: permissionDenied,
            survivors: Set(liveSnapshots().map(\.identity))
        )
    }

    private func signalLive(
        _ signal: Int32,
        attempted: inout Set<ProcessIdentity>,
        sent: inout Set<ProcessIdentity>,
        permissionDenied: inout Set<ProcessIdentity>
    ) {
        for process in orderedBottomUp(liveSnapshots()) where !attempted.contains(process.identity) {
            attempted.insert(process.identity)
            guard safeToSignal(process.identity) else { continue }
            switch system.signal(signal, identity: process.identity) {
            case .sent:
                sent.insert(process.identity)
            case .permissionDenied:
                // EPERM proves neither death nor successful delivery. Keep the
                // identity live and surface it as a survivor after verification.
                permissionDenied.insert(process.identity)
            case .missing, .identityChanged, .failed:
                break
            }
        }
    }

    private func liveSnapshots() -> [ProcessSnapshot] {
        tracked.keys.compactMap { identity in
            guard let current = system.snapshot(pid: identity.pid), current.identity == identity else {
                return nil
            }
            return current
        }
    }

    private func safeToSignal(_ identity: ProcessIdentity) -> Bool {
        guard identity.pid > 1, identity.pid != system.ownerProcessID else { return false }
        return system.snapshot(pid: identity.pid)?.identity == identity
    }

    private func orderedBottomUp(_ snapshots: [ProcessSnapshot]) -> [ProcessSnapshot] {
        let live = Set(snapshots.map(\.identity))

        func depth(of identity: ProcessIdentity) -> Int {
            var depth = 0
            var current = identity
            var visited: Set<ProcessIdentity> = []
            while
                let parent = tracked[current]?.verifiedParent,
                live.contains(parent),
                visited.insert(parent).inserted
            {
                depth += 1
                current = parent
            }
            return depth
        }

        return snapshots.sorted {
            let leftDepth = depth(of: $0.identity)
            let rightDepth = depth(of: $1.identity)
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return $0.identity.pid > $1.identity.pid
        }
    }
}
