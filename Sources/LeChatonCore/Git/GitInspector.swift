import Darwin
import Foundation

public struct GitInspectionLimits: Equatable, Sendable {
    public let maximumBytesPerFile: Int
    public let maximumLinesPerFile: Int
    public let commandTimeout: Duration

    public init(
        maximumBytesPerFile: Int = 512 * 1_024,
        maximumLinesPerFile: Int = 10_000,
        commandTimeout: Duration = .seconds(10)
    ) {
        self.maximumBytesPerFile = max(0, maximumBytesPerFile)
        self.maximumLinesPerFile = max(0, maximumLinesPerFile)
        self.commandTimeout = commandTimeout < .zero ? .zero : commandTimeout
    }
}

public enum GitStatusKind: String, Equatable, Hashable, Sendable {
    case tracked
    case unmerged
    case untracked
}

public struct GitStatusEntry: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }

    public let path: String
    public let originalPath: String?
    public let indexStatus: String
    public let worktreeStatus: String
    public let kind: GitStatusKind
    public let isSubmodule: Bool
    public let isNonRegularFile: Bool

    public init(
        path: String,
        originalPath: String?,
        indexStatus: String,
        worktreeStatus: String,
        kind: GitStatusKind,
        isSubmodule: Bool,
        isNonRegularFile: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.kind = kind
        self.isSubmodule = isSubmodule
        self.isNonRegularFile = isNonRegularFile
    }

    public var hasStagedChange: Bool { indexStatus != "." && indexStatus != "?" }
    public var hasUnstagedChange: Bool { worktreeStatus != "." || kind == .untracked }
}

public struct GitStatusSnapshot: Equatable, Sendable {
    public let repositoryRoot: URL
    public let entries: [GitStatusEntry]

    public init(repositoryRoot: URL, entries: [GitStatusEntry]) {
        self.repositoryRoot = repositoryRoot
        self.entries = entries
    }
}

public enum GitDiffSectionKind: String, Equatable, Hashable, Sendable {
    case staged
    case unstaged
    case untracked
}

public enum GitDiffPlaceholder: Equatable, Sendable {
    case binary
    case submodule
    case nonRegularFile
    case oversized(byteCount: UInt64)
    case gitError(String)
}

public enum GitRenderedDiff: Equatable, Sendable {
    case text(String)
    case truncated(prefix: String)
    case placeholder(GitDiffPlaceholder)
}

public struct GitDiffSection: Equatable, Sendable, Identifiable {
    public var id: GitDiffSectionKind { kind }

    public let kind: GitDiffSectionKind
    public let content: GitRenderedDiff

    public init(kind: GitDiffSectionKind, content: GitRenderedDiff) {
        self.kind = kind
        self.content = content
    }
}

public struct GitFileInspection: Equatable, Sendable, Identifiable {
    public var id: String { status.path }

    public let status: GitStatusEntry
    public let wasDirtyAtBaseline: Bool
    public let sections: [GitDiffSection]

    public init(status: GitStatusEntry, wasDirtyAtBaseline: Bool, sections: [GitDiffSection]) {
        self.status = status
        self.wasDirtyAtBaseline = wasDirtyAtBaseline
        self.sections = sections
    }
}

public struct GitInspection: Equatable, Sendable {
    public let baseline: GitStatusSnapshot
    public let current: GitStatusSnapshot
    public let files: [GitFileInspection]

    public init(
        baseline: GitStatusSnapshot,
        current: GitStatusSnapshot,
        files: [GitFileInspection]
    ) {
        self.baseline = baseline
        self.current = current
        self.files = files
    }
}

public enum GitInspectionError: Error, Equatable, Sendable, CustomStringConvertible {
    case gitUnavailable(String)
    case invalidRepository(String)
    case bareRepository(String)
    case missingHead(String)
    case repositoryRootMismatch(expected: String, reported: String)
    case unsafeFilterConfiguration(String)
    case malformedStatus
    case statusTooLarge
    case commandTimedOut
    case commandFailed(arguments: [String], message: String)

    public var description: String {
        switch self {
        case let .gitUnavailable(path): "Git is unavailable at \(path)"
        case let .invalidRepository(path): "Not a Git worktree: \(path)"
        case let .bareRepository(path): "Bare repositories are unsupported: \(path)"
        case let .missingHead(path): "Repository has no valid HEAD commit: \(path)"
        case let .repositoryRootMismatch(expected, reported):
            "Repository root mismatch: expected \(expected), reported \(reported)"
        case let .unsafeFilterConfiguration(path):
            "Repository config declares a clean/process filter and cannot be inspected read-only: \(path)"
        case .malformedStatus: "Git returned malformed porcelain-v2 status"
        case .statusTooLarge: "Git status exceeded the bounded inspection limit"
        case .commandTimedOut: "Git command timed out"
        case let .commandFailed(arguments, message):
            "Git \(arguments.joined(separator: " ")) failed: \(message)"
        }
    }
}

/// Read-only Git boundary. Every command uses an absolute executable, an explicit
/// working directory, and an argument vector; no shell is involved.
public actor GitInspector {
    private let executableURL: URL
    private let limits: GitInspectionLimits
    private let runner: GitCommandRunner

    public init(
        executableURL: URL = URL(filePath: "/usr/bin/git"),
        limits: GitInspectionLimits = GitInspectionLimits()
    ) {
        self.executableURL = executableURL
        self.limits = limits
        runner = GitCommandRunner(executableURL: executableURL)
    }

    public func validateRepository(_ candidate: URL) async throws -> URL {
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitInspectionError.gitUnavailable(executableURL.path)
        }

        let bareResult = try await runValidationCommand(
            ["rev-parse", "--is-bare-repository"],
            cwd: canonical
        )
        guard bareResult.exitCode == 0 else {
            throw GitInspectionError.invalidRepository(canonical.path)
        }
        let bare = try decodedValidationText(bareResult, arguments: ["rev-parse", "--is-bare-repository"])
        guard bare.trimmingCharacters(in: .whitespacesAndNewlines) == "false" else {
            throw GitInspectionError.bareRepository(canonical.path)
        }

        let insideResult = try await runValidationCommand(
            ["rev-parse", "--is-inside-work-tree"],
            cwd: canonical
        )
        guard insideResult.exitCode == 0 else {
            throw GitInspectionError.invalidRepository(canonical.path)
        }
        let inside = try decodedValidationText(
            insideResult,
            arguments: ["rev-parse", "--is-inside-work-tree"]
        )
        guard inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw GitInspectionError.invalidRepository(canonical.path)
        }
        let rootText = try await runText(["rev-parse", "--show-toplevel"], cwd: canonical)
        let reported = URL(filePath: rootText.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard reported.path == canonical.path else {
            throw GitInspectionError.repositoryRootMismatch(
                expected: canonical.path,
                reported: reported.path
            )
        }
        let headArguments = ["rev-parse", "--verify", "HEAD^{commit}"]
        let headResult = try await runValidationCommand(headArguments, cwd: canonical)
        guard headResult.exitCode == 0 else {
            throw GitInspectionError.missingHead(canonical.path)
        }
        _ = try decodedValidationText(headResult, arguments: headArguments)
        try await rejectUnsafeFiltersRecursively(root: canonical)
        return canonical
    }

    public func captureBaseline(repository: URL) async throws -> GitStatusSnapshot {
        let root = try await validateRepository(repository)
        return try await captureStatus(root: root)
    }

    public func inspect(
        repository: URL,
        baseline: GitStatusSnapshot
    ) async throws -> GitInspection {
        let root = try await validateRepository(repository)
        guard baseline.repositoryRoot.standardizedFileURL.resolvingSymlinksInPath().path == root.path else {
            throw GitInspectionError.repositoryRootMismatch(
                expected: root.path,
                reported: baseline.repositoryRoot.path
            )
        }
        let current = try await captureStatus(root: root)
        let baselinePaths = Set(baseline.entries.flatMap { [$0.path, $0.originalPath].compactMap { $0 } })
        var files: [GitFileInspection] = []
        for entry in current.entries {
            try Task.checkCancellation()
            files.append(GitFileInspection(
                status: entry,
                wasDirtyAtBaseline: baselinePaths.contains(entry.path)
                    || entry.originalPath.map(baselinePaths.contains) == true,
                sections: try await renderSections(entry: entry, root: root)
            ))
        }
        return GitInspection(baseline: baseline, current: current, files: files)
    }

    private func captureStatus(root: URL) async throws -> GitStatusSnapshot {
        let result = try await runner.run(
            arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            workingDirectory: root,
            maximumBytes: 4 * 1_024 * 1_024,
            maximumLines: 100_000,
            timeout: limits.commandTimeout
        )
        guard !result.timedOut else { throw GitInspectionError.commandTimedOut }
        guard !result.truncated else { throw GitInspectionError.statusTooLarge }
        guard !result.leftDescendants else {
            throw GitInspectionError.commandFailed(
                arguments: ["status"],
                message: "Git left a verified descendant process"
            )
        }
        guard result.exitCode == 0 else {
            throw commandError(result: result, arguments: ["status"])
        }
        return GitStatusSnapshot(repositoryRoot: root, entries: try parseStatus(result.stdout))
    }

    private func parseStatus(_ data: Data) throws -> [GitStatusEntry] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            guard let record = String(data: records[index], encoding: .utf8), let tag = record.first else {
                throw GitInspectionError.malformedStatus
            }
            switch tag {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { throw GitInspectionError.malformedStatus }
                entries.append(try trackedEntry(fields: fields, originalPath: nil, kind: .tracked))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10, index + 1 < records.count,
                      let original = String(data: records[index + 1], encoding: .utf8)
                else { throw GitInspectionError.malformedStatus }
                entries.append(try trackedEntry(fields: fields, originalPath: original, kind: .tracked))
                index += 1
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { throw GitInspectionError.malformedStatus }
                entries.append(try trackedEntry(fields: fields, originalPath: nil, kind: .unmerged))
            case "?":
                let fields = record.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2 else { throw GitInspectionError.malformedStatus }
                let path = String(fields[1])
                try validateRelativePath(path)
                entries.append(.init(
                    path: path,
                    originalPath: nil,
                    indexStatus: "?",
                    worktreeStatus: "?",
                    kind: .untracked,
                    isSubmodule: false,
                    isNonRegularFile: false
                ))
            default:
                throw GitInspectionError.malformedStatus
            }
            index += 1
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func trackedEntry(
        fields: [Substring],
        originalPath: String?,
        kind: GitStatusKind
    ) throws -> GitStatusEntry {
        guard fields.count >= 3 else { throw GitInspectionError.malformedStatus }
        let xy = fields[1]
        guard xy.count == 2 else { throw GitInspectionError.malformedStatus }
        let path = String(fields.last!)
        try validateRelativePath(path)
        if let originalPath { try validateRelativePath(originalPath) }
        let submodule = String(fields[2])
        let modes = fields.dropFirst(3).dropLast().prefix(kind == .unmerged ? 4 : 3)
        let isNonRegular = modes.contains { mode in
            mode != "000000" && mode != "100644" && mode != "100755"
        }
        return .init(
            path: path,
            originalPath: originalPath,
            indexStatus: String(xy.prefix(1)),
            worktreeStatus: String(xy.suffix(1)),
            kind: kind,
            isSubmodule: submodule.first == "S" || modes.contains("160000"),
            isNonRegularFile: isNonRegular
        )
    }

    private func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains("..") else {
            throw GitInspectionError.malformedStatus
        }
    }

    private func renderSections(entry: GitStatusEntry, root: URL) async throws -> [GitDiffSection] {
        try Task.checkCancellation()
        if entry.isSubmodule {
            let kinds: [GitDiffSectionKind] = entry.hasStagedChange && entry.hasUnstagedChange
                ? [.staged, .unstaged]
                : [entry.hasStagedChange ? .staged : .unstaged]
            return kinds.map { .init(kind: $0, content: .placeholder(.submodule)) }
        }
        if entry.isNonRegularFile {
            let kinds: [GitDiffSectionKind] = entry.hasStagedChange && entry.hasUnstagedChange
                ? [.staged, .unstaged]
                : [entry.hasStagedChange ? .staged : .unstaged]
            return kinds.map { .init(kind: $0, content: .placeholder(.nonRegularFile)) }
        }
        if entry.kind == .untracked {
            return [.init(kind: .untracked, content: renderUntracked(path: entry.path, root: root))]
        }

        var sections: [GitDiffSection] = []
        var remainingBytes = limits.maximumBytesPerFile
        var remainingLines = limits.maximumLinesPerFile
        if entry.hasStagedChange {
            let content = try await renderGitDiff(
                arguments: ["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--", entry.path],
                root: root,
                maximumBytes: remainingBytes,
                maximumLines: remainingLines
            )
            sections.append(.init(
                kind: .staged,
                content: content
            ))
            let cost = renderedCost(content)
            remainingBytes = max(remainingBytes - cost.bytes, 0)
            remainingLines = max(remainingLines - cost.lines, 0)
        }
        if entry.hasUnstagedChange {
            sections.append(.init(
                kind: .unstaged,
                content: try await renderGitDiff(
                    arguments: ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--", entry.path],
                    root: root,
                    maximumBytes: remainingBytes,
                    maximumLines: remainingLines
                )
            ))
        }
        return sections
    }

    private func renderGitDiff(
        arguments: [String],
        root: URL,
        maximumBytes: Int,
        maximumLines: Int
    ) async throws -> GitRenderedDiff {
        guard maximumBytes > 0, maximumLines > 0 else { return .truncated(prefix: "") }
        do {
            let result = try await runner.run(
                arguments: arguments,
                workingDirectory: root,
                maximumBytes: maximumBytes,
                maximumLines: maximumLines,
                timeout: limits.commandTimeout
            )
            if result.timedOut { return .placeholder(.gitError("command timed out")) }
            if result.leftDescendants {
                return .placeholder(.gitError("Git left a verified descendant process"))
            }
            guard result.exitCode == 0 else {
                return .placeholder(.gitError(sanitizedError(result.stderr)))
            }
            guard !result.stdout.contains(0),
                  let text = decodeBoundedUTF8(result.stdout, allowTrailingPartialScalar: result.truncated)
            else {
                return .placeholder(.binary)
            }
            if containsGitBinarySummary(text) { return .placeholder(.binary) }
            if result.truncated { return .truncated(prefix: text) }
            return .text(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .placeholder(.gitError(String(describing: error)))
        }
    }

    private func renderUntracked(path: String, root: URL) -> GitRenderedDiff {
        let fileURL = root.appending(path: path)
        let data: Data
        do {
            data = try readBoundedRegularFile(
                fileURL,
                maximumBytes: limits.maximumBytesPerFile
            )
        } catch let error as BoundedFileReadError {
            switch error {
            case .nonRegular:
                return .placeholder(.nonRegularFile)
            case let .oversized(byteCount):
                return .placeholder(.oversized(byteCount: byteCount))
            case let .failed(message):
                return .placeholder(.gitError(message))
            }
        } catch {
            return .placeholder(.gitError("could not read untracked file"))
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .placeholder(.binary)
        }
        var lines = text.isEmpty
            ? []
            : text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n"), lines.last?.isEmpty == true { lines.removeLast() }
        let headerLines = 5
        let availableBodyLines = max(limits.maximumLinesPerFile - headerLines, 0)
        guard lines.count <= availableBodyLines else {
            let prefix = lines.prefix(availableBodyLines).map { "+\($0)" }.joined(separator: "\n")
            return boundedText(
                syntheticHeader(path: path, lineCount: lines.count)
                    + prefix
                    + (prefix.isEmpty ? "" : "\n"),
                forceTruncated: true
            )
        }
        let body = lines.map { "+\($0)" }.joined(separator: "\n")
        return boundedText(syntheticHeader(path: path, lineCount: lines.count) + body + (body.isEmpty ? "" : "\n"))
    }

    private func syntheticHeader(path: String, lineCount: Int) -> String {
        let oldPath = quoteDiffPath("a/\(path)")
        let newPath = quoteDiffPath("b/\(path)")
        return "diff --git \(oldPath) \(newPath)\nnew file mode 100644\n--- /dev/null\n+++ \(newPath)\n@@ -0,0 +1,\(lineCount) @@\n"
    }

    private func boundedText(_ text: String, forceTruncated: Bool = false) -> GitRenderedDiff {
        let bytes = Data(text.utf8)
        var byteCount = 0
        var lineCount = 0
        for byte in bytes {
            guard byteCount < limits.maximumBytesPerFile,
                  lineCount < limits.maximumLinesPerFile
            else { break }
            byteCount += 1
            if byte == 0x0A { lineCount += 1 }
        }
        if forceTruncated || byteCount < bytes.count {
            let prefix = decodeBoundedUTF8(
                Data(bytes.prefix(byteCount)),
                allowTrailingPartialScalar: true
            ) ?? ""
            return .truncated(prefix: prefix)
        }
        return .text(text)
    }

    private func renderedCost(_ content: GitRenderedDiff) -> (bytes: Int, lines: Int) {
        let text: String
        switch content {
        case let .text(value), let .truncated(value): text = value
        case .placeholder: return (0, 0)
        }
        let newlineCount = text.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        let lineCount = text.isEmpty ? 0 : newlineCount + (text.hasSuffix("\n") ? 0 : 1)
        return (text.utf8.count, lineCount)
    }

    private func runText(_ arguments: [String], cwd: URL) async throws -> String {
        let result = try await runValidationCommand(arguments, cwd: cwd)
        guard result.exitCode == 0 else { throw commandError(result: result, arguments: arguments) }
        return try decodedValidationText(result, arguments: arguments)
    }

    /// Returns non-zero Git exits to the caller while preserving operational
    /// failures such as timeouts, truncation, and incomplete process cleanup.
    private func runValidationCommand(
        _ arguments: [String],
        cwd: URL,
        maximumBytes: Int = 128 * 1_024,
        maximumLines: Int = 10_000
    ) async throws -> GitCommandResult {
        let result = try await runner.run(
            arguments: arguments,
            workingDirectory: cwd,
            maximumBytes: maximumBytes,
            maximumLines: maximumLines,
            timeout: limits.commandTimeout
        )
        guard !result.timedOut else { throw GitInspectionError.commandTimedOut }
        guard !result.truncated else {
            throw GitInspectionError.commandFailed(
                arguments: arguments,
                message: "Git output exceeded the validation limit"
            )
        }
        guard !result.leftDescendants else {
            throw GitInspectionError.commandFailed(
                arguments: arguments,
                message: "Git left a verified descendant process"
            )
        }
        return result
    }

    private func decodedValidationText(
        _ result: GitCommandResult,
        arguments: [String]
    ) throws -> String {
        guard !result.stdout.contains(0),
              let text = String(data: result.stdout, encoding: .utf8)
        else {
            throw GitInspectionError.commandFailed(
                arguments: arguments,
                message: "Git returned non-UTF-8 validation output"
            )
        }
        return text
    }

    /// Git may invoke repository-defined clean/process filters even for status
    /// and worktree comparison. Refuse such repositories before either command
    /// so inspection remains a read-only boundary with no repository commands.
    private func rejectUnsafeFiltersRecursively(root: URL) async throws {
        var pending = [root]
        var inspectedRoots: Set<String> = []
        while let candidate = pending.popLast() {
            let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path == root.path || canonical.path.hasPrefix(root.path + "/"),
                  inspectedRoots.insert(canonical.path).inserted
            else {
                continue
            }

            if canonical.path != root.path {
                let topArguments = ["rev-parse", "--show-toplevel"]
                let topResult = try await runValidationCommand(topArguments, cwd: canonical)
                guard topResult.exitCode == 0 else { continue }
                let top = try decodedValidationText(topResult, arguments: topArguments)
                let reported = URL(filePath: top.trimmingCharacters(in: .whitespacesAndNewlines))
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard reported.path == canonical.path else { continue }
            }

            try await rejectUnsafeFilters(root: canonical)
            for path in try await gitlinkPaths(root: canonical) {
                let nested = canonical.appending(path: path)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                if FileManager.default.fileExists(atPath: nested.path) {
                    pending.append(nested)
                }
            }
        }
    }

    private func rejectUnsafeFilters(root: URL) async throws {
        let arguments = [
            "config", "--includes", "--get-regexp",
            "^filter\\..*\\.(clean|process)$",
        ]
        let result = try await runValidationCommand(
            arguments,
            cwd: root,
            maximumBytes: 64 * 1_024,
            maximumLines: 2_000
        )
        switch result.exitCode {
        case 1:
            return
        case 0:
            guard result.stdout.isEmpty else {
                throw GitInspectionError.unsafeFilterConfiguration(root.path)
            }
        default:
            throw commandError(result: result, arguments: arguments)
        }
    }

    private func gitlinkPaths(root: URL) async throws -> [String] {
        let arguments = ["ls-files", "--stage", "-z"]
        let result = try await runValidationCommand(
            arguments,
            cwd: root,
            maximumBytes: 4 * 1_024 * 1_024,
            maximumLines: 100_000
        )
        guard result.exitCode == 0 else {
            throw commandError(result: result, arguments: arguments)
        }
        var paths: [String] = []
        for record in result.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09) else {
                throw GitInspectionError.malformedStatus
            }
            let metadata = record[..<tab]
            guard metadata.starts(with: Data("160000 ".utf8)) else { continue }
            let pathBytes = record[record.index(after: tab)...]
            guard let path = String(data: pathBytes, encoding: .utf8) else {
                throw GitInspectionError.malformedStatus
            }
            try validateRelativePath(path)
            paths.append(path)
        }
        return paths
    }

    private func commandError(result: GitCommandResult, arguments: [String]) -> GitInspectionError {
        .commandFailed(arguments: arguments, message: sanitizedError(result.stderr))
    }

    private func sanitizedError(_ data: Data) -> String {
        String(decoding: data.prefix(2_048), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func decodeBoundedUTF8(
    _ data: Data,
    allowTrailingPartialScalar: Bool
) -> String? {
    if let text = String(data: data, encoding: .utf8) { return text }
    guard allowTrailingPartialScalar, !data.isEmpty else { return nil }

    let bytes = [UInt8](data)
    var scalarStart = bytes.count - 1
    while scalarStart > 0, bytes[scalarStart] & 0b1100_0000 == 0b1000_0000 {
        scalarStart -= 1
    }
    let leading = bytes[scalarStart]
    let expectedLength: Int?
    switch leading {
    case 0xC2 ... 0xDF: expectedLength = 2
    case 0xE0 ... 0xEF: expectedLength = 3
    case 0xF0 ... 0xF4: expectedLength = 4
    default: expectedLength = nil
    }
    guard let expectedLength,
          bytes.count - scalarStart < expectedLength,
          bytes[(scalarStart + 1) ..< bytes.count].allSatisfy({
              $0 & 0b1100_0000 == 0b1000_0000
          })
    else {
        return nil
    }
    return String(data: data.prefix(scalarStart), encoding: .utf8)
}

private func containsGitBinarySummary(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
        line.hasPrefix("Binary files ") && line.hasSuffix(" differ")
    }
}

/// Quotes path-bearing synthetic diff headers so legal control characters in a
/// repository filename cannot inject additional patch records.
private func quoteDiffPath(_ path: String) -> String {
    let requiresQuoting = path.unicodeScalars.contains { scalar in
        scalar.value == 0x22 || scalar.value == 0x5C
            || scalar.value < 0x20 || scalar.value == 0x7F
    }
    guard requiresQuoting else { return path }

    var escaped = ""
    for scalar in path.unicodeScalars {
        switch scalar.value {
        case 0x22: escaped += "\\\""
        case 0x5C: escaped += "\\\\"
        case 0x0A: escaped += "\\n"
        case 0x0D: escaped += "\\r"
        case 0x09: escaped += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F {
                escaped += String(format: "\\%03o", scalar.value)
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
    }
    return "\"\(escaped)\""
}

private enum BoundedFileReadError: Error {
    case nonRegular
    case oversized(byteCount: UInt64)
    case failed(String)
}

/// Opens the repository entry without following a final symlink, verifies the
/// opened identity, and reads no more than the configured bound plus one byte.
/// This avoids the lstat/read path race and prevents a growing file from causing
/// an unbounded allocation.
private func readBoundedRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
    guard maximumBytes >= 0, maximumBytes < Int.max else {
        throw BoundedFileReadError.failed("invalid untracked-file byte limit")
    }
    let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
        if errno == ELOOP || errno == EISDIR { throw BoundedFileReadError.nonRegular }
        throw BoundedFileReadError.failed(
            "could not open untracked file: \(String(cString: strerror(errno)))"
        )
    }
    defer { _ = Darwin.close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
        throw BoundedFileReadError.failed(
            "could not inspect untracked file: \(String(cString: strerror(errno)))"
        )
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
        throw BoundedFileReadError.nonRegular
    }

    let reportedByteCount = UInt64(max(info.st_size, 0))
    guard reportedByteCount <= UInt64(maximumBytes) else {
        throw BoundedFileReadError.oversized(byteCount: reportedByteCount)
    }

    let readLimit = maximumBytes + 1
    var result = Data()
    result.reserveCapacity(min(maximumBytes, 64 * 1_024))
    var storage = [UInt8](repeating: 0, count: 16 * 1_024)
    while result.count < readLimit {
        let requested = min(storage.count, readLimit - result.count)
        let count = storage.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, requested)
        }
        if count > 0 {
            result.append(contentsOf: storage.prefix(count))
            continue
        }
        if count == 0 { break }
        if errno == EINTR { continue }
        throw BoundedFileReadError.failed(
            "could not read untracked file: \(String(cString: strerror(errno)))"
        )
    }
    guard result.count <= maximumBytes else {
        throw BoundedFileReadError.oversized(
            byteCount: max(reportedByteCount, UInt64(result.count))
        )
    }
    return result
}

private struct GitCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let truncated: Bool
    let timedOut: Bool
    let leftDescendants: Bool
}

private final class GitOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumLines: Int
    private var bytes: [UInt8] = []
    private var lineCount = 0
    private(set) var truncated = false

    init(maximumBytes: Int, maximumLines: Int) {
        self.maximumBytes = maximumBytes
        self.maximumLines = maximumLines
        bytes.reserveCapacity(min(maximumBytes, 64 * 1_024))
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !truncated else { return true }
        for byte in data {
            if bytes.count >= maximumBytes || lineCount >= maximumLines {
                truncated = true
                break
            }
            bytes.append(byte)
            if byte == 0x0A { lineCount += 1 }
        }
        return truncated
    }

    func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (Data(bytes), truncated)
    }

    func isTruncated() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }
}

private struct GitCommandRunner: Sendable {
    let executableURL: URL

    func run(
        arguments: [String],
        workingDirectory: URL,
        maximumBytes: Int,
        maximumLines: Int,
        timeout: Duration
    ) async throws -> GitCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = GitOutputCollector(maximumBytes: maximumBytes, maximumLines: maximumLines)
        let stderr = GitOutputCollector(maximumBytes: 64 * 1_024, maximumLines: 2_000)

        process.executableURL = executableURL
        process.arguments = [
            "--no-pager",
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
        ] + arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = [
            "HOME": "/var/empty",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // `Process` duplicates these descriptors into the child. Closing the
        // parent's writer copies is required for the reader tasks to observe EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        let stdoutDescriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderrPipe.fileHandleForReading.fileDescriptor
        setNonBlocking(stdoutDescriptor)
        setNonBlocking(stderrDescriptor)
        let drainControl = GitPipeDrainControl()
        let stdoutTask = Task.detached {
            await drainGitPipe(
                fileDescriptor: stdoutDescriptor,
                collector: stdout,
                control: drainControl
            )
        }
        let stderrTask = Task.detached {
            await drainGitPipe(
                fileDescriptor: stderrDescriptor,
                collector: stderr,
                control: drainControl
            )
        }
        let identity = ProcessInspector.snapshot(pid: process.processIdentifier)?.identity
        let terminator = identity.map { ProcessTreeTerminator(root: $0) }
        if let terminator { _ = await terminator.refresh() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var timedOut = false
        var stoppedForLimit = false
        var cancelled = false
        while process.isRunning {
            if let terminator { _ = await terminator.refresh() }
            if stdout.isTruncated() {
                stoppedForLimit = true
                break
            }
            if Task.isCancelled {
                cancelled = true
                break
            }
            if clock.now >= deadline {
                timedOut = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        var leftDescendants = false
        if process.isRunning, timedOut || stoppedForLimit || cancelled {
            if let terminator {
                let report = await terminator.terminate(
                    gracePeriod: .milliseconds(100),
                    rescanInterval: .milliseconds(10),
                    killConfirmationPeriod: .milliseconds(100)
                )
                leftDescendants = !report.survivors.isEmpty
            } else {
                process.terminate()
            }
        }

        let exitDeadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < exitDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let killDeadline = clock.now.advanced(by: .milliseconds(500))
        while process.isRunning, clock.now < killDeadline {
            if let current = ProcessInspector.snapshot(pid: process.processIdentifier)?.identity,
               identity == nil || current == identity
            {
                _ = Darwin.kill(current.pid, SIGKILL)
            } else if identity == nil {
                process.terminate()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let rootSurvived = process.isRunning
        if rootSurvived {
            leftDescendants = true
            if let terminator {
                await GitCleanupRegistry.shared.retain(terminator)
            } else if let current = ProcessInspector.snapshot(pid: process.processIdentifier)?.identity {
                await GitCleanupRegistry.shared.retain(ProcessTreeTerminator(root: current))
            }
        }

        if let terminator {
            let descendants = await terminator.liveDescendantIdentities()
            if !descendants.isEmpty {
                leftDescendants = true
                let report = await terminator.terminate(
                    gracePeriod: .milliseconds(100),
                    rescanInterval: .milliseconds(10),
                    killConfirmationPeriod: .milliseconds(100)
                )
                if !report.survivors.isEmpty {
                    await GitCleanupRegistry.shared.retain(terminator)
                }
            }
        }

        // Once the verified tree is gone, drain every currently buffered byte and
        // then allow readers to stop on EAGAIN even if an untracked process kept a
        // duplicate writer descriptor open.
        drainControl.processEnded()
        await stdoutTask.value
        await stderrTask.value
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        let stdoutSnapshot = stdout.snapshot()
        let stderrSnapshot = stderr.snapshot()
        if cancelled { throw CancellationError() }
        return .init(
            stdout: stdoutSnapshot.0,
            stderr: stderrSnapshot.0,
            exitCode: rootSurvived ? -1 : process.terminationStatus,
            truncated: stdoutSnapshot.1,
            timedOut: timedOut,
            leftDescendants: leftDescendants
        )
    }
}

/// Retains verification state for the exceptional case where a Git process or
/// descendant survives the runner's bounded cleanup windows. Cleanup retries
/// remain identity-checked; the caller receives a failure instead of blocking.
private actor GitCleanupRegistry {
    static let shared = GitCleanupRegistry()

    private var retained: [ProcessIdentity: ProcessTreeTerminator] = [:]
    private var retrying: Set<ProcessIdentity> = []

    func retain(_ terminator: ProcessTreeTerminator) {
        let root = terminator.root
        retained[root] = terminator
        guard retrying.insert(root).inserted else { return }
        Task { await retry(root: root) }
    }

    private func retry(root: ProcessIdentity) async {
        for _ in 0 ..< 10 {
            guard let terminator = retained[root] else { break }
            let report = await terminator.terminate(
                gracePeriod: .milliseconds(100),
                rescanInterval: .milliseconds(20),
                killConfirmationPeriod: .milliseconds(200)
            )
            if report.survivors.isEmpty {
                retained[root] = nil
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        retrying.remove(root)
    }
}

/// Drains a child pipe with POSIX reads so large output cannot deadlock the child.
/// The collector remains bounded; bytes beyond its limits are discarded until EOF.
private final class GitPipeDrainControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopDeadline: ContinuousClock.Instant?

    func processEnded() {
        lock.lock()
        stopDeadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        lock.unlock()
    }

    func mayStop(collectorIsTruncated: Bool, pipeIsEmpty: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stopDeadline else { return false }
        return pipeIsEmpty || collectorIsTruncated || ContinuousClock.now >= stopDeadline
    }
}

private func setNonBlocking(_ fileDescriptor: Int32) {
    let flags = fcntl(fileDescriptor, F_GETFL)
    guard flags >= 0 else { return }
    _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
}

private func drainGitPipe(
    fileDescriptor: Int32,
    collector: GitOutputCollector,
    control: GitPipeDrainControl
) async {
    var storage = [UInt8](repeating: 0, count: 16 * 1_024)
    while !Task.isCancelled {
        if control.mayStop(
            collectorIsTruncated: collector.isTruncated(),
            pipeIsEmpty: false
        ) {
            return
        }
        let count = storage.withUnsafeMutableBytes { buffer in
            Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        if count > 0 {
            _ = collector.append(Data(storage.prefix(count)))
            continue
        }
        if count == 0 { return }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            if control.mayStop(
                collectorIsTruncated: collector.isTruncated(),
                pipeIsEmpty: true
            ) {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
            continue
        }
        return
    }
}
