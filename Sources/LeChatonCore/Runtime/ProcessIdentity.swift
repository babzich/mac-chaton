import Darwin
import Foundation

/// PID plus kernel start time, which prevents signalling a reused PID.
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: pid_t
    public let processStartTime: UInt64

    public init(pid: pid_t, processStartTime: UInt64) {
        self.pid = pid
        self.processStartTime = processStartTime
    }
}

public struct ProcessSnapshot: Equatable, Hashable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: pid_t
    public let processGroupID: pid_t

    public init(identity: ProcessIdentity, parentPID: pid_t, processGroupID: pid_t) {
        self.identity = identity
        self.parentPID = parentPID
        self.processGroupID = processGroupID
    }
}

public enum ProcessInspector {
    public static func snapshot(pid: pid_t) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        guard read == expected else { return nil }

        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        let identity = ProcessIdentity(
            pid: pid,
            processStartTime: seconds &* 1_000_000 &+ microseconds
        )
        return ProcessSnapshot(
            identity: identity,
            parentPID: pid_t(info.pbi_ppid),
            processGroupID: getpgid(pid)
        )
    }

    public static func allSnapshots() -> [ProcessSnapshot] {
        let estimate = max(Int(proc_listallpids(nil, 0)), 64)
        var pids = [pid_t](repeating: 0, count: estimate + 128)
        let count = pids.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap(snapshot(pid:))
    }

    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard snapshot(pid: identity.pid)?.identity == identity else { return false }
        if kill(identity.pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

enum ProcessSignalDisposition: Equatable, Sendable {
    case sent
    case missing
    case identityChanged
    case permissionDenied
    case failed(Int32)
}

/// Injectable kernel boundary used by `ProcessTreeTerminator` so ownership and
/// signalling policy can be exercised without touching the host process table.
protocol ProcessSystem: Sendable {
    var ownerProcessID: pid_t { get }
    var ownerProcessGroupID: pid_t { get }

    func snapshot(pid: pid_t) -> ProcessSnapshot?
    func allSnapshots() -> [ProcessSnapshot]
    func signal(_ signal: Int32, identity: ProcessIdentity) -> ProcessSignalDisposition
}

struct DarwinProcessSystem: ProcessSystem {
    let ownerProcessID: pid_t
    let ownerProcessGroupID: pid_t

    init() {
        ownerProcessID = getpid()
        ownerProcessGroupID = getpgrp()
    }

    func snapshot(pid: pid_t) -> ProcessSnapshot? {
        ProcessInspector.snapshot(pid: pid)
    }

    func allSnapshots() -> [ProcessSnapshot] {
        ProcessInspector.allSnapshots()
    }

    /// Re-checks the start time immediately before each signal. macOS does not
    /// expose pidfds, so this is the narrowest available PID-reuse guard.
    func signal(_ signal: Int32, identity: ProcessIdentity) -> ProcessSignalDisposition {
        guard let current = snapshot(pid: identity.pid) else { return .missing }
        guard current.identity == identity else { return .identityChanged }

        while true {
            if kill(identity.pid, signal) == 0 { return .sent }
            switch errno {
            case EINTR:
                continue
            case ESRCH:
                return .missing
            case EPERM:
                return .permissionDenied
            default:
                return .failed(errno)
            }
        }
    }
}
