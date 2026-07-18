import Darwin
import Foundation
import Testing
@testable import LeChatonCore

@Suite("Verified process-tree cleanup", .serialized)
struct ProcessTreeTerminatorTests {
    @Test("Tracked identities survive reparenting and process-group changes")
    func reparentingAndGroupChanges() async {
        let root = identity(100, 1)
        let child = identity(101, 2)
        let grandchild = identity(102, 3)
        let system = FakeProcessSystem(snapshots: [
            snapshot(root, parent: 1, group: 100),
            snapshot(child, parent: 100, group: 100),
        ])
        let terminator = ProcessTreeTerminator(root: root, system: system)

        #expect(await terminator.refresh() == [root, child])

        system.replaceSnapshots([
            snapshot(root, parent: 1, group: 100),
            snapshot(child, parent: 1, group: 777),
            snapshot(grandchild, parent: 101, group: 777),
        ])

        #expect(await terminator.refresh() == [root, child, grandchild])
        #expect(await terminator.liveDescendantIdentities() == [child, grandchild])
    }

    @Test("A tracked reparented child can prove a grandchild after the root exits")
    func grandchildAfterRootExit() async {
        let root = identity(100, 1)
        let child = identity(101, 2)
        let grandchild = identity(102, 3)
        let system = FakeProcessSystem(snapshots: [
            snapshot(root, parent: 1, group: 100),
            snapshot(child, parent: 100, group: 100),
        ])
        let terminator = ProcessTreeTerminator(root: root, system: system)
        _ = await terminator.refresh()

        system.replaceSnapshots([
            snapshot(child, parent: 1, group: 700),
            snapshot(grandchild, parent: 101, group: 701),
        ])

        #expect(await terminator.refresh() == [child, grandchild])
        let report = await terminateQuickly(terminator)
        #expect(Array(system.deliveredSignals.prefix(2)).map(\.identity) == [grandchild, child])
        #expect(report.survivors.isEmpty)
    }

    @Test("A reused PID cannot seed an unrelated descendant tree or receive a signal")
    func pidReuseIsRejected() async {
        let root = identity(100, 1)
        let child = identity(101, 2)
        let reusedChild = identity(101, 99)
        let unrelated = identity(102, 100)
        let system = FakeProcessSystem(snapshots: [
            snapshot(root, parent: 1, group: 100),
            snapshot(child, parent: 100, group: 100),
        ])
        let terminator = ProcessTreeTerminator(root: root, system: system)
        _ = await terminator.refresh()

        system.replaceSnapshots([
            snapshot(root, parent: 1, group: 100),
            snapshot(reusedChild, parent: 1, group: 101),
            snapshot(unrelated, parent: 101, group: 101),
        ])
        let report = await terminateQuickly(terminator)

        #expect(report.survivors.isEmpty)
        #expect(system.deliveredSignals.map(\.identity) == [root])
        #expect(!system.deliveredSignals.contains { $0.identity == reusedChild || $0.identity == unrelated })
    }

    @Test("TERM and KILL run bottom-up and TERM-resistant descendants are force-killed")
    func bottomUpAndTermResistance() async {
        let root = identity(100, 1)
        let child = identity(101, 2)
        let grandchild = identity(102, 3)
        let system = FakeProcessSystem(snapshots: [
            snapshot(root, parent: 1, group: 500),
            snapshot(child, parent: 100, group: 800),
            snapshot(grandchild, parent: 101, group: 999),
        ])
        system.termResistant = [child]
        let terminator = ProcessTreeTerminator(root: root, system: system)

        let report = await terminateQuickly(terminator)

        #expect(Array(system.deliveredSignals.prefix(3)).map(\.identity) == [grandchild, child, root])
        #expect(Array(system.deliveredSignals.prefix(3)).allSatisfy { $0.signal == SIGTERM })
        #expect(system.deliveredSignals.last == SignalDelivery(signal: SIGKILL, identity: child))
        #expect(report.signalled == [root, child, grandchild])
        #expect(report.forceKilled == [child])
        #expect(report.survivors.isEmpty)
    }

    @Test("TERM rescan discovers a late child before the root exits")
    func lateChildIsTrackedDuringTermination() async {
        let root = identity(100, 1)
        let lateChild = identity(103, 4)
        let system = FakeProcessSystem(snapshots: [snapshot(root, parent: 1, group: 100)])
        system.termResistant = [root]
        system.injectOnTerm[root] = snapshot(lateChild, parent: 100, group: 321)
        let terminator = ProcessTreeTerminator(root: root, system: system)

        let report = await terminateQuickly(terminator)

        #expect(system.deliveredSignals.contains(SignalDelivery(signal: SIGTERM, identity: lateChild)))
        #expect(system.deliveredSignals.contains(SignalDelivery(signal: SIGKILL, identity: root)))
        #expect(report.survivors.isEmpty)
    }

    @Test("KILL confirmation rescans live tracked descendants")
    func killPhaseRescans() async {
        let root = identity(100, 1)
        let child = identity(101, 2)
        let lateGrandchild = identity(104, 5)
        let system = FakeProcessSystem(snapshots: [
            snapshot(root, parent: 1, group: 100),
            snapshot(child, parent: 100, group: 100),
        ])
        system.termResistant = [root, child]
        system.killResistant = [child]
        system.injectOnKill[child] = snapshot(lateGrandchild, parent: 101, group: 444)
        let terminator = ProcessTreeTerminator(root: root, system: system)

        let report = await terminateQuickly(terminator)

        #expect(system.deliveredSignals.contains(SignalDelivery(signal: SIGKILL, identity: lateGrandchild)))
        #expect(report.survivors == [child])
    }

    @Test("EPERM remains a live survivor and the owner process is never signalled")
    func permissionDeniedAndOwnerProtection() async {
        let root = identity(100, 1)
        let deniedChild = identity(101, 2)
        let owner = identity(900, 9)
        let system = FakeProcessSystem(
            owner: owner,
            snapshots: [
                snapshot(owner, parent: 1, group: 900),
                snapshot(root, parent: 900, group: 900),
                snapshot(deniedChild, parent: 100, group: 900),
            ]
        )
        system.permissionDenied = [deniedChild]
        let terminator = ProcessTreeTerminator(root: root, system: system)

        let report = await terminateQuickly(terminator)

        #expect(report.permissionDenied == [deniedChild])
        #expect(report.survivors == [deniedChild])
        #expect(!system.deliveredSignals.contains { $0.identity == owner })
        #expect(!system.deliveredSignals.contains { $0.identity == deniedChild })
    }

    @Test("Identity is checked again immediately before signalling")
    func identityChangesAtSignalBoundary() async {
        let root = identity(100, 1)
        let replacement = snapshot(identity(100, 55), parent: 1, group: 100)
        let system = FakeProcessSystem(snapshots: [snapshot(root, parent: 1, group: 100)])
        system.replaceBeforeSignal[root] = replacement
        let terminator = ProcessTreeTerminator(root: root, system: system)

        let report = await terminateQuickly(terminator)

        #expect(system.deliveredSignals.isEmpty)
        #expect(report.signalled.isEmpty)
        #expect(report.forceKilled.isEmpty)
        #expect(report.survivors.isEmpty)
    }

    private func terminateQuickly(_ terminator: ProcessTreeTerminator) async -> ProcessCleanupReport {
        await terminator.terminate(
            gracePeriod: .milliseconds(3),
            rescanInterval: .milliseconds(1),
            killConfirmationPeriod: .milliseconds(3)
        )
    }
}

private struct SignalDelivery: Equatable, Sendable {
    let signal: Int32
    let identity: ProcessIdentity
}

private final class FakeProcessSystem: ProcessSystem, @unchecked Sendable {
    let ownerProcessID: pid_t
    let ownerProcessGroupID: pid_t

    var termResistant: Set<ProcessIdentity> = []
    var killResistant: Set<ProcessIdentity> = []
    var permissionDenied: Set<ProcessIdentity> = []
    var injectOnTerm: [ProcessIdentity: ProcessSnapshot] = [:]
    var injectOnKill: [ProcessIdentity: ProcessSnapshot] = [:]
    var replaceBeforeSignal: [ProcessIdentity: ProcessSnapshot] = [:]

    private let lock = NSLock()
    private var snapshotsByPID: [pid_t: ProcessSnapshot]
    private var recordedDeliveries: [SignalDelivery] = []

    init(owner: ProcessIdentity = ProcessIdentity(pid: 900, processStartTime: 9), snapshots: [ProcessSnapshot]) {
        ownerProcessID = owner.pid
        ownerProcessGroupID = owner.pid
        snapshotsByPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity.pid, $0) })
    }

    var deliveredSignals: [SignalDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDeliveries
    }

    func replaceSnapshots(_ snapshots: [ProcessSnapshot]) {
        lock.lock()
        snapshotsByPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity.pid, $0) })
        lock.unlock()
    }

    func snapshot(pid: pid_t) -> ProcessSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotsByPID[pid]
    }

    func allSnapshots() -> [ProcessSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotsByPID.values.sorted { $0.identity.pid < $1.identity.pid }
    }

    func signal(_ signal: Int32, identity: ProcessIdentity) -> ProcessSignalDisposition {
        lock.lock()
        defer { lock.unlock() }

        if let replacement = replaceBeforeSignal.removeValue(forKey: identity) {
            snapshotsByPID[identity.pid] = replacement
            return .identityChanged
        }
        guard let current = snapshotsByPID[identity.pid] else { return .missing }
        guard current.identity == identity else { return .identityChanged }
        guard !permissionDenied.contains(identity) else { return .permissionDenied }

        recordedDeliveries.append(SignalDelivery(signal: signal, identity: identity))
        if signal == SIGTERM, let injected = injectOnTerm.removeValue(forKey: identity) {
            snapshotsByPID[injected.identity.pid] = injected
        }
        if signal == SIGKILL, let injected = injectOnKill.removeValue(forKey: identity) {
            snapshotsByPID[injected.identity.pid] = injected
        }
        if signal == SIGTERM, termResistant.contains(identity) { return .sent }
        if signal == SIGKILL, killResistant.contains(identity) { return .sent }
        snapshotsByPID.removeValue(forKey: identity.pid)
        return .sent
    }
}

private func identity(_ pid: pid_t, _ start: UInt64) -> ProcessIdentity {
    ProcessIdentity(pid: pid, processStartTime: start)
}

private func snapshot(_ identity: ProcessIdentity, parent: pid_t, group: pid_t) -> ProcessSnapshot {
    ProcessSnapshot(identity: identity, parentPID: parent, processGroupID: group)
}
