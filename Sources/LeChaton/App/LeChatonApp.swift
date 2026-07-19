import AppKit
import LeChatonCore
import SwiftUI

@main
@MainActor
struct LeChatonApp: App {
    @NSApplicationDelegateAdaptor(LeChatonAppDelegate.self) private var appDelegate
    @State private var container = ApplicationContainer()

    var body: some Scene {
        Window("LeChaton", id: "main") {
            ApplicationRootView(container: container)
                .frame(minWidth: 820, minHeight: 580)
                .tint(LeChatonTheme.orange)
                .preferredColorScheme(.dark)
                .task {
                    appDelegate.shutdownHandler = { [weak container] in
                        await container?.shutdown() ?? true
                    }
                    container.start()
                }
        }
        .defaultSize(width: 1_180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread…") {
                    createThreadFromCommand()
                }
                .keyboardShortcut("n")
                .disabled(container.workspace?.canCreateThread != true)
            }

            CommandMenu("Thread") {
                Button("Resume") {
                    guard let workspace = container.workspace else { return }
                    Task { await workspace.resume() }
                }
                .keyboardShortcut("r")
                .disabled(container.workspace?.model.canResume != true)

                Button("Cancel Prompt") {
                    guard let workspace = container.workspace else { return }
                    Task { await workspace.cancelPrompt() }
                }
                .disabled(container.workspace?.model.lifecycle != .prompting)
            }
        }

        Settings {
            SettingsRootView(container: container)
                .preferredColorScheme(.dark)
                .task { container.start() }
        }
    }

    private func createThreadFromCommand() {
        guard let workspace = container.workspace,
              workspace.canCreateThread,
              let repository = SystemPickers.chooseRepository()
        else { return }
        Task {
            await workspace.createThread(
                repositoryURL: repository,
                title: repository.lastPathComponent
            )
        }
    }
}

@MainActor
final class LeChatonAppDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Bool)?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownHandler else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor [weak self] in
            let canTerminate = await shutdownHandler()
            self?.terminationPending = false
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }
}
