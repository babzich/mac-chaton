import Darwin
import Foundation
import GRDB

enum PersistenceTestSupport {
    static func makeApplicationSupportRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonPersistence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func makeRepository(name: String = "Repository") throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonRepo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repository = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init"], at: repository)
        try git(["config", "user.name", "LeChaton Tests"], at: repository)
        try git(["config", "user.email", "tests@example.invalid"], at: repository)
        try git(["config", "commit.gpgsign", "false"], at: repository)
        try Data("seed\n".utf8).write(to: repository.appending(path: "seed.txt"))
        try git(["add", "seed.txt"], at: repository)
        try git(["commit", "-m", "seed"], at: repository)
        return repository
    }

    static func canonicalPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else {
            throw PersistenceFixtureError.canonicalization(url.path, errno)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func databaseQueue(at databaseURL: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    }

    @discardableResult
    static func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw PersistenceFixtureError.git(
                arguments,
                String(decoding: errorData, as: UTF8.self)
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}

enum PersistenceFixtureError: Error {
    case git([String], String)
    case injected(String)
    case canonicalization(String, Int32)
}
