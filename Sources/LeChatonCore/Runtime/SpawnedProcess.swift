import Darwin
import Foundation

enum SpawnError: Error, CustomStringConvertible {
    case pipe(Int32)
    case fileAction(Int32)
    case attributes(Int32)
    case spawn(Int32)
    case identityUnavailable(pid_t)

    var description: String {
        switch self {
        case let .pipe(code): "pipe failed: \(String(cString: strerror(code)))"
        case let .fileAction(code): "posix_spawn file action failed: \(String(cString: strerror(code)))"
        case let .attributes(code): "posix_spawn attributes failed: \(String(cString: strerror(code)))"
        case let .spawn(code): "posix_spawn failed: \(String(cString: strerror(code)))"
        case let .identityUnavailable(pid): "Could not read process identity for PID \(pid)"
        }
    }
}

struct SpawnedProcess: @unchecked Sendable {
    let identity: ProcessIdentity
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle
}

enum DirectProcessSpawner {
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL
    ) throws -> SpawnedProcess {
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdinPipe) == 0 else { throw SpawnError.pipe(errno) }
        guard pipe(&stdoutPipe) == 0 else {
            closePair(stdinPipe)
            throw SpawnError.pipe(errno)
        }
        guard pipe(&stderrPipe) == 0 else {
            closePair(stdinPipe)
            closePair(stdoutPipe)
            throw SpawnError.pipe(errno)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let actionInit = posix_spawn_file_actions_init(&actions)
        guard actionInit == 0 else {
            closePair(stdinPipe); closePair(stdoutPipe); closePair(stderrPipe)
            throw SpawnError.fileAction(actionInit)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let attributeInit = posix_spawnattr_init(&attributes)
        guard attributeInit == 0 else {
            closePair(stdinPipe); closePair(stdoutPipe); closePair(stderrPipe)
            throw SpawnError.attributes(attributeInit)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let actionsToAdd: [(Int32, Int32)] = [
            (stdinPipe[0], STDIN_FILENO),
            (stdoutPipe[1], STDOUT_FILENO),
            (stderrPipe[1], STDERR_FILENO),
        ]
        for (source, target) in actionsToAdd {
            let code = posix_spawn_file_actions_adddup2(&actions, source, target)
            guard code == 0 else {
                closePair(stdinPipe); closePair(stdoutPipe); closePair(stderrPipe)
                throw SpawnError.fileAction(code)
            }
        }
        for descriptor in [
            stdinPipe[0], stdinPipe[1],
            stdoutPipe[0], stdoutPipe[1],
            stderrPipe[0], stderrPipe[1],
        ] where descriptor != STDIN_FILENO && descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
            let code = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard code == 0 else {
                closePair(stdinPipe); closePair(stdoutPipe); closePair(stderrPipe)
                throw SpawnError.fileAction(code)
            }
        }
        let chdirCode = workingDirectory.path.withCString {
            posix_spawn_file_actions_addchdir(&actions, $0)
        }
        guard chdirCode == 0 else {
            closePair(stdinPipe); closePair(stdoutPipe); closePair(stderrPipe)
            throw SpawnError.fileAction(chdirCode)
        }

        let flagsCode = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard flagsCode == 0 else {
            closePair(stdinPipe); closePair(stdoutPipe); closePair(stderrPipe)
            throw SpawnError.attributes(flagsCode)
        }
        let groupCode = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupCode == 0 else {
            closePair(stdinPipe); closePair(stdoutPipe); closePair(stderrPipe)
            throw SpawnError.attributes(groupCode)
        }

        let argvStrings = [executableURL.path] + arguments
        let environmentStrings = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnCode = withMutableCStringArray(argvStrings) { argv in
            withMutableCStringArray(environmentStrings) { environmentPointer in
                executableURL.path.withCString { path in
                    posix_spawn(&pid, path, &actions, &attributes, argv, environmentPointer)
                }
            }
        }

        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard spawnCode == 0 else {
            close(stdinPipe[1]); close(stdoutPipe[0]); close(stderrPipe[0])
            throw SpawnError.spawn(spawnCode)
        }

        guard let identity = waitForIdentity(pid: pid) else {
            kill(pid, SIGKILL)
            close(stdinPipe[1]); close(stdoutPipe[0]); close(stderrPipe[0])
            throw SpawnError.identityUnavailable(pid)
        }

        return SpawnedProcess(
            identity: identity,
            standardInput: FileHandle(fileDescriptor: stdinPipe[1], closeOnDealloc: true),
            standardOutput: FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true),
            standardError: FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        )
    }

    private static func waitForIdentity(pid: pid_t) -> ProcessIdentity? {
        for _ in 0..<100 {
            if let identity = ProcessInspector.snapshot(pid: pid)?.identity { return identity }
            usleep(1_000)
        }
        return nil
    }

    private static func closePair(_ pair: [Int32]) {
        for descriptor in pair where descriptor >= 0 { close(descriptor) }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
