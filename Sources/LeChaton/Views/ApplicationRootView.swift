import SwiftUI

struct ApplicationRootView: View {
    let container: ApplicationContainer

    var body: some View {
        Group {
            switch container.startupState {
            case .starting:
                ZStack {
                    LeChatonPixelField(opacity: 0.18)
                        .scaleEffect(2.4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(70)

                    VStack(alignment: .leading, spacing: 22) {
                        LeChatonBrandLockup()

                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(LeChatonTheme.orange)
                            Text("Opening local metadata…")
                                .font(.title2.weight(.semibold))
                            Text("No Vibe process is started until you choose Resume or New Thread.")
                                .foregroundStyle(LeChatonTheme.secondaryText)
                        }
                        .padding(24)
                        .frame(maxWidth: 480, alignment: .leading)
                        .leChatonGlassCard(cornerRadius: 20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(42)
                }
                .accessibilityElement(children: .combine)

            case .ready:
                if let workspace = container.workspace {
                    WorkspaceRootView(
                        workspace: workspace,
                        startupRecoveryBackupURL: container.startupRecoveryBackupURL
                    )
                } else {
                    ProgressView()
                }

            case let .failed(failure):
                DatabaseStartupFailureView(container: container, failure: failure)
            }
        }
        .leChatonDetailCanvas()
        .alert(
            "LeChaton",
            isPresented: Binding(
                get: { container.notice != nil },
                set: { if !$0 { container.dismissNotice() } }
            )
        ) {
            Button("OK") { container.dismissNotice() }
        } message: {
            Text(container.notice ?? "")
        }
    }
}
