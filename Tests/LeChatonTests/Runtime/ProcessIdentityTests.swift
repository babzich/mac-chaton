import Darwin
import Testing
@testable import LeChatonCore

@Suite("Process identity")
struct ProcessIdentityTests {
    @Test("The current process identity is stable and a mismatched start time is rejected")
    func startTimeGuardsPIDReuse() throws {
        let snapshot = try #require(ProcessInspector.snapshot(pid: getpid()))
        #expect(ProcessInspector.isAlive(snapshot.identity))
        let stale = ProcessIdentity(
            pid: snapshot.identity.pid,
            processStartTime: snapshot.identity.processStartTime &+ 1
        )
        #expect(!ProcessInspector.isAlive(stale))
    }
}
