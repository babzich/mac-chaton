import Foundation
import Testing
@testable import LeChatonCore

@Suite("Bounded read-only Git inspection", .serialized)
struct GitInspectorTests {
    @Test("Dirty baselines label pre-existing paths and keep staged and unstaged diffs separate")
    func baselineAndSeparateDiffs() async throws {
        try await withRepository { repository in
            try write("original\n", to: repository.appending(path: "notes file.txt"))
            try git(["add", "--", "notes file.txt"], at: repository)
            try git(["commit", "-m", "add notes"], at: repository)

            try write("baseline dirty\n", to: repository.appending(path: "notes file.txt"))
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)

            try git(["add", "--", "notes file.txt"], at: repository)
            try write("current unstaged\n", to: repository.appending(path: "notes file.txt"))
            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            let file = try #require(inspection.files.first(where: { $0.status.path == "notes file.txt" }))

            #expect(file.wasDirtyAtBaseline)
            #expect(file.sections.map(\.kind) == [.staged, .unstaged])
            #expect(text(in: file.sections[0].content).contains("baseline dirty"))
            #expect(text(in: file.sections[1].content).contains("current unstaged"))
        }
    }

    @Test("Current inspection keeps baseline attribution explicitly unknown")
    func inspectionWithoutBaselineDoesNotInventAttribution() async throws {
        try await withRepository { repository in
            let inspector = GitInspector()
            try write("current only\n", to: repository.appending(path: "current.txt"))

            let inspection = try await inspector.inspect(repository: repository, baseline: nil)
            let file = try #require(inspection.files.first(where: { $0.status.path == "current.txt" }))

            #expect(inspection.baseline == nil)
            #expect(file.baselineAttribution == .unknown)
            #expect(!file.wasDirtyAtBaseline)
        }
    }

    @Test("Known baselines distinguish new paths from pre-existing paths")
    func knownBaselineMarksNewPathAsNotPreExisting() async throws {
        try await withRepository { repository in
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)
            try write("created later\n", to: repository.appending(path: "later.txt"))

            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            let file = try #require(inspection.files.first(where: { $0.status.path == "later.txt" }))

            #expect(file.baselineAttribution == .notPreExisting)
        }
    }

    @Test("Unicode renames, deletions, and untracked text use bounded renderings")
    func renamesDeletionsAndUntrackedText() async throws {
        try await withRepository { repository in
            try write("rename me\n", to: repository.appending(path: "old name.txt"))
            try write("delete me\n", to: repository.appending(path: "delete.txt"))
            try git(["add", "."], at: repository)
            try git(["commit", "-m", "seed files"], at: repository)
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)

            try git(["mv", "old name.txt", "café 🐈.txt"], at: repository)
            try FileManager.default.removeItem(at: repository.appending(path: "delete.txt"))
            try write("first\nsecond\n", to: repository.appending(path: "new ünicode.txt"))

            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            let renamed = try #require(inspection.current.entries.first(where: { $0.path == "café 🐈.txt" }))
            #expect(renamed.originalPath == "old name.txt")
            #expect(inspection.current.entries.contains(where: { $0.path == "delete.txt" }))

            let untracked = try #require(inspection.files.first(where: { $0.status.path == "new ünicode.txt" }))
            let synthetic = text(in: try #require(untracked.sections.first).content)
            #expect(synthetic.contains("--- /dev/null"))
            #expect(synthetic.contains("+++ b/new ünicode.txt"))
            #expect(synthetic.contains("+first"))
        }
    }

    @Test("Binary, non-regular, oversized, and line-truncated untracked files become placeholders")
    func boundedUntrackedPlaceholders() async throws {
        try await withRepository { repository in
            let inspector = GitInspector(limits: .init(maximumBytesPerFile: 64, maximumLinesPerFile: 3))
            let baseline = try await inspector.captureBaseline(repository: repository)

            try Data([0x00, 0x01, 0x02]).write(to: repository.appending(path: "binary.dat"))
            try write(String(repeating: "x", count: 65), to: repository.appending(path: "large.txt"))
            try write("1\n2\n3\n4\n", to: repository.appending(path: "lines.txt"))
            try FileManager.default.createDirectory(at: repository.appending(path: "folder"), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: repository.appending(path: "link"),
                withDestinationURL: repository.appending(path: "lines.txt")
            )

            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            #expect(content(for: "binary.dat", in: inspection) == .placeholder(.binary))
            #expect(content(for: "large.txt", in: inspection) == .placeholder(.oversized(byteCount: 65)))
            guard case .truncated = content(for: "lines.txt", in: inspection) else {
                Issue.record("Expected line-truncated synthetic diff")
                return
            }
            #expect(content(for: "link", in: inspection) == .placeholder(.nonRegularFile))
        }
    }

    @Test("Tracked binary diffs are never rendered as arbitrary text")
    func trackedBinaryPlaceholder() async throws {
        try await withRepository { repository in
            try Data([0x00, 0x01]).write(to: repository.appending(path: "image.bin"))
            try git(["add", "image.bin"], at: repository)
            try git(["commit", "-m", "add binary"], at: repository)
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)

            try Data([0x00, 0x02]).write(to: repository.appending(path: "image.bin"))
            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            #expect(content(for: "image.bin", in: inspection) == .placeholder(.binary))
        }
    }

    @Test("Binary-looking text content is not mistaken for Git's binary summary")
    func binaryLookingTextRemainsText() async throws {
        try await withRepository { repository in
            let file = repository.appending(path: "phrases.txt")
            try write("seed\n", to: file)
            try git(["add", "phrases.txt"], at: repository)
            try git(["commit", "-m", "add phrases"], at: repository)
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)

            try write("seed\nBinary files a and b differ\nGIT binary patch\n", to: file)
            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            guard case let .text(diff) = content(for: "phrases.txt", in: inspection) else {
                Issue.record("Expected ordinary text diff")
                return
            }
            #expect(diff.contains("+Binary files a and b differ"))
            #expect(diff.contains("+GIT binary patch"))
        }
    }

    @Test("Synthetic diff headers C-quote control characters in filenames")
    func syntheticHeadersQuoteControlCharacters() async throws {
        try await withRepository { repository in
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)
            let path = "line\nbreak\tname.txt"
            try write("safe body\n", to: repository.appending(path: path))

            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            let synthetic = text(in: try #require(content(for: path, in: inspection)))
            #expect(synthetic.contains("line\\nbreak\\tname.txt"))
            #expect(!synthetic.contains("a/line\nbreak"))
            #expect(!synthetic.contains("b/line\nbreak"))
        }
    }

    @Test("Tracked symbolic links render as non-regular placeholders")
    func trackedSymbolicLinkPlaceholder() async throws {
        try await withRepository { repository in
            try write("one\n", to: repository.appending(path: "target-one.txt"))
            try write("two\n", to: repository.appending(path: "target-two.txt"))
            let link = repository.appending(path: "tracked-link")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: repository.appending(path: "target-one.txt")
            )
            try git(["add", "."], at: repository)
            try git(["commit", "-m", "add link"], at: repository)
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)

            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: repository.appending(path: "target-two.txt")
            )
            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            #expect(content(for: "tracked-link", in: inspection) == .placeholder(.nonRegularFile))
        }
    }

    @Test("Staged and unstaged renderings share the per-file byte budget")
    func combinedPerFileBudget() async throws {
        try await withRepository { repository in
            let file = repository.appending(path: "bounded.txt")
            try write("seed\n", to: file)
            try git(["add", "bounded.txt"], at: repository)
            try git(["commit", "-m", "add bounded file"], at: repository)
            let inspector = GitInspector(limits: .init(
                maximumBytesPerFile: 180,
                maximumLinesPerFile: 100
            ))
            let baseline = try await inspector.captureBaseline(repository: repository)

            try write(String(repeating: "staged ", count: 30) + "\n", to: file)
            try git(["add", "bounded.txt"], at: repository)
            try write(String(repeating: "unstaged ", count: 30) + "\n", to: file)
            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            let rendered = try #require(inspection.files.first(where: { $0.status.path == "bounded.txt" }))
            let totalBytes = rendered.sections.reduce(into: 0) { total, section in
                total += text(in: section.content).utf8.count
            }
            #expect(rendered.sections.map(\.kind) == [.staged, .unstaged])
            #expect(totalBytes <= 180)
            guard case .truncated = rendered.sections[0].content else {
                Issue.record("Expected the first section to consume the shared budget")
                return
            }
            #expect(rendered.sections[1].content == .truncated(prefix: ""))
        }
    }

    @Test("Submodule worktree changes render a placeholder without traversing the nested repository")
    func submodulePlaceholder() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonSubmodule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try git(["init"], at: source)
        try configureRepository(source)
        try write("submodule seed\n", to: source.appending(path: "seed.txt"))
        try git(["add", "seed.txt"], at: source)
        try git(["commit", "-m", "submodule seed"], at: source)

        try await withRepository { repository in
            try git([
                "-c", "protocol.file.allow=always",
                "submodule", "add", source.path, "Vendor/Submodule",
            ], at: repository)
            try git(["commit", "-am", "add submodule"], at: repository)
            let inspector = GitInspector()
            let baseline = try await inspector.captureBaseline(repository: repository)

            try write(
                "nested untracked\n",
                to: repository.appending(path: "Vendor/Submodule/local.txt")
            )
            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            #expect(content(for: "Vendor/Submodule", in: inspection) == .placeholder(.submodule))
        }
    }

    @Test("Repository validation requires the canonical root and a valid HEAD")
    func repositoryInvariants() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonGitInvalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try git(["init"], at: parent)

        let inspector = GitInspector()
        await #expect(throws: GitInspectionError.self) {
            _ = try await inspector.captureBaseline(repository: parent)
        }

        try configureRepository(parent)
        try write("seed\n", to: parent.appending(path: "seed.txt"))
        try git(["add", "seed.txt"], at: parent)
        try git(["commit", "-m", "seed"], at: parent)
        let child = parent.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        await #expect(throws: GitInspectionError.self) {
            _ = try await inspector.captureBaseline(repository: child)
        }
    }

    @Test("Repository clean and process filters are rejected before status can invoke them")
    func unsafeFiltersAreRejectedWithoutExecution() async throws {
        try await withRepository { repository in
            try write("*.txt filter=sideeffect\n", to: repository.appending(path: ".gitattributes"))
            try git(["add", ".gitattributes"], at: repository)
            try git(["commit", "-m", "add attributes"], at: repository)

            let marker = repository.appending(path: "filter-was-invoked")
            let command = "/bin/sh -c 'touch \"\(marker.path)\"; cat'"
            try git(["config", "filter.sideeffect.clean", command], at: repository)

            let inspector = GitInspector()
            do {
                _ = try await inspector.captureBaseline(repository: repository)
                Issue.record("Expected unsafe filter rejection")
            } catch let error as GitInspectionError {
                #expect(error == .unsafeFilterConfiguration(repository.path))
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("Negative rendering limits clamp to zero instead of trapping")
    func negativeLimitsAreClamped() async throws {
        try await withRepository { repository in
            let inspector = GitInspector(limits: .init(
                maximumBytesPerFile: -1,
                maximumLinesPerFile: -1,
                commandTimeout: .seconds(1)
            ))
            let baseline = try await inspector.captureBaseline(repository: repository)
            try write("content\n", to: repository.appending(path: "new.txt"))
            let inspection = try await inspector.inspect(repository: repository, baseline: baseline)
            #expect(content(for: "new.txt", in: inspection) == .placeholder(.oversized(byteCount: 8)))
        }
    }

    private func content(for path: String, in inspection: GitInspection) -> GitRenderedDiff? {
        inspection.files.first(where: { $0.status.path == path })?.sections.first?.content
    }

    private func text(in content: GitRenderedDiff) -> String {
        switch content {
        case let .text(value), let .truncated(value): value
        case .placeholder: ""
        }
    }

    private func withRepository(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let repository = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try git(["init"], at: repository)
        try configureRepository(repository)
        try write("seed\n", to: repository.appending(path: "seed.txt"))
        try git(["add", "seed.txt"], at: repository)
        try git(["commit", "-m", "initial"], at: repository)
        try await operation(repository)
    }

    private func configureRepository(_ repository: URL) throws {
        try git(["config", "user.name", "LeChaton Tests"], at: repository)
        try git(["config", "user.email", "tests@example.invalid"], at: repository)
        try git(["config", "commit.gpgsign", "false"], at: repository)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
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
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.command(arguments, String(decoding: error, as: UTF8.self))
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private enum GitFixtureError: Error {
    case command([String], String)
}
