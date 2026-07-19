import Darwin
import Foundation
import Testing
@testable import LeChatonCore

@Suite("Vibe executable discovery")
struct VibeLocatorTests {
    @Test("Explicit symlinks resolve to an executable regular file")
    func explicitSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LeChaton Locator \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appending(path: "vibe acp ü")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        #expect(chmod(executable.path, 0o700) == 0)
        let symlink = directory.appending(path: "selected-vibe")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)

        let located = try VibeLocator(standardLocations: []).locate(explicitPath: symlink.path)
        #expect(located.url == executable.resolvingSymlinksInPath())
        #expect(located.source == .explicit)
    }

    @Test("A stored invalid path does not silently fall through")
    func invalidStoredPreference() {
        #expect(throws: VibeLocatorError.self) {
            try VibeLocator(standardLocations: [URL(filePath: "/bin/sh")])
                .locate(storedPath: "/definitely/missing/vibe-acp")
        }
    }

    @Test("Compatibility requires protocol one and exact Vibe version")
    func exactVersion() {
        let executable = VibeExecutable(url: URL(filePath: "/tmp/vibe-acp"), source: .explicit)
        let initialization = ACPInitializeResult(
            protocolVersion: 1,
            agentInfo: .init(
                name: VibeCompatibility.supportedAgentName,
                title: nil,
                version: "2.21.1"
            ),
            agentCapabilities: .object(["loadSession": .bool(true)]),
            authenticationMethods: [],
            metadata: nil,
            raw: .object([:])
        )
        #expect(throws: VibeCompatibilityError.self) {
            try VibeCompatibility(executable: executable, initialization: initialization)
        }
    }

    @Test("Compatibility accepts only the named agent with session loading")
    func exactAgentAndCapability() throws {
        let executable = VibeExecutable(url: URL(filePath: "/tmp/vibe-acp"), source: .explicit)
        let compatible = ACPInitializeResult(
            protocolVersion: ACPProtocol.supportedVersion,
            agentInfo: .init(
                name: VibeCompatibility.supportedAgentName,
                title: "Mistral Vibe",
                version: VibeCompatibility.supportedVersion
            ),
            agentCapabilities: .object([
                "loadSession": .bool(true),
                "sessionCapabilities": .object(["list": .object([:])]),
                "futureCapability": .object([:]),
            ]),
            authenticationMethods: [],
            metadata: nil,
            raw: .object([:])
        )

        _ = try VibeCompatibility(executable: executable, initialization: compatible)

        let missingLoad = ACPInitializeResult(
            protocolVersion: compatible.protocolVersion,
            agentInfo: compatible.agentInfo,
            agentCapabilities: .object(["loadSession": .bool(false)]),
            authenticationMethods: compatible.authenticationMethods,
            metadata: nil,
            raw: .object([:])
        )
        #expect(throws: VibeCompatibilityError.self) {
            try VibeCompatibility(executable: executable, initialization: missingLoad)
        }

        let missingList = ACPInitializeResult(
            protocolVersion: compatible.protocolVersion,
            agentInfo: compatible.agentInfo,
            agentCapabilities: .object(["loadSession": .bool(true)]),
            authenticationMethods: compatible.authenticationMethods,
            metadata: nil,
            raw: .object([:])
        )
        #expect(throws: VibeCompatibilityError.self) {
            try VibeCompatibility(executable: executable, initialization: missingList)
        }

        let wrongAgent = ACPInitializeResult(
            protocolVersion: compatible.protocolVersion,
            agentInfo: .init(
                name: "another-agent",
                title: nil,
                version: VibeCompatibility.supportedVersion
            ),
            agentCapabilities: compatible.agentCapabilities,
            authenticationMethods: [],
            metadata: nil,
            raw: .object([:])
        )
        #expect(throws: VibeCompatibilityError.self) {
            try VibeCompatibility(executable: executable, initialization: wrongAgent)
        }
    }
}
