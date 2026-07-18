import AppKit
import UniformTypeIdentifiers

@MainActor
enum SystemPickers {
    static func chooseRepository() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Git repository"
        panel.message = "Select a non-bare Git worktree with a valid HEAD commit. Local changes are allowed."
        panel.prompt = "Choose Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseVibeExecutable() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the Mistral Vibe executable"
        panel.message = "Select the vibe-acp executable for Vibe 2.21.0."
        panel.prompt = "Validate Vibe"
        panel.allowedContentTypes = [.item]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
