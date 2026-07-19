import Darwin
import Foundation
import LeChatonCore

struct ConfigurationJournal: Codable, Sendable {
    struct OriginalValue: Codable, Sendable {
        let optionID: String
        let value: JSONValue
    }

    let formatVersion: Int
    let executablePath: String
    let workingDirectory: String
    let sessionID: String
    let createdAtUnixMilliseconds: Int64
    let model: OriginalValue
    let thinking: OriginalValue
    var workerProcessIdentities: [ProcessIdentity]? = nil
}

enum ConfigurationJournalStore {
    static func save(_ journal: ConfigurationJournal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(journal)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)

        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func load(from url: URL) throws -> ConfigurationJournal {
        try JSONDecoder().decode(
            ConfigurationJournal.self,
            from: Data(contentsOf: url)
        )
    }

    static func updateWorkerIdentities(
        _ identities: Set<ProcessIdentity>,
        at url: URL
    ) throws {
        var journal = try load(from: url)
        journal.workerProcessIdentities = identities.sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.processStartTime < $1.processStartTime
        }
        try save(journal, to: url)
    }

    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func synchronizeDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = Darwin.close(descriptor)
    }
}
