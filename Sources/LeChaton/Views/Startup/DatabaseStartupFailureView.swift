import AppKit
import SwiftUI

struct DatabaseStartupFailureView: View {
    let container: ApplicationContainer
    let failure: DatabaseStartupFailure

    @State private var confirmsReset = false

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: icon)
        } description: {
            Text(failure.message)
        } actions: {
            HStack(spacing: 10) {
                switch failure.kind {
                case .schemaTooNew:
                    Button("Update Application") { container.showUpdateInstructions() }
                        .buttonStyle(.borderedProminent)
                        .tint(LeChatonTheme.orange)
                        .foregroundStyle(LeChatonTheme.onAccent)
                    Button("Reveal Database") { container.revealDatabase() }
                    Button("Quit") { NSApp.terminate(nil) }

                case .recoverable:
                    Button("Try Again") { container.retryStartup() }
                        .buttonStyle(.borderedProminent)
                        .tint(LeChatonTheme.orange)
                        .foregroundStyle(LeChatonTheme.onAccent)
                    Button("Reveal Database") { container.revealDatabase() }
                    Button("Export Diagnostic") { container.exportStartupDiagnostic() }
                    Button("Reset Local Metadata…", role: .destructive) { confirmsReset = true }

                case .unavailable:
                    Button("Try Again") { container.retryStartup() }
                        .buttonStyle(.borderedProminent)
                        .tint(LeChatonTheme.orange)
                        .foregroundStyle(LeChatonTheme.onAccent)
                    Button("Reveal Database") { container.revealDatabase() }
                    Button("Export Diagnostic") { container.exportStartupDiagnostic() }
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .confirmationDialog(
            "Reset Local Metadata?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Move Database to Recovery and Reset", role: .destructive) {
                container.recoverLocalMetadata()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LeChaton will move the entire Database directory, including WAL and SHM files, to a recoverable backup. Vibe history is not deleted.")
        }
    }

    private var icon: String {
        switch failure.kind {
        case .schemaTooNew: "arrow.down.app"
        case .recoverable: "externaldrive.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}
