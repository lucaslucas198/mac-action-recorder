import MacActionRecorderCore
import SwiftUI

/// Shown above the main content when an update is available, being built, ready, or has failed.
struct UpdateBanner: View {
    @ObservedObject private var updates = UpdateManager.shared

    var body: some View {
        switch updates.state {
        case .available(let version):
            row(icon: "arrow.down.circle", text: "Version \(version) is available.") {
                Button("Download and Build") { updates.startBuild() }
            }
        case .building(let version):
            row(icon: "hammer", text: "Building version \(version) in the background. You can keep using the app.") {
                ProgressView().controlSize(.small)
            }
        case .ready(let version):
            row(icon: "checkmark.circle", text: "Version \(version) is ready to install.") {
                Button("Restart to Update") { updates.installAndRelaunch() }
            }
        case .failed(let message):
            row(icon: "exclamationmark.triangle", text: "Update problem: \(message)") {
                Button("Dismiss") { updates.dismissFailure() }
            }
        default:
            EmptyView()
        }
    }

    private func row<Trailing: View>(
        icon: String,
        text: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }
}

struct UpdatesSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updates = UpdateManager.shared

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Installed version", value: updates.installedVersionText ?? "development build")
                Toggle("Check for updates automatically", isOn: $model.settings.checkForUpdates)
                Toggle("Download and build new versions in the background", isOn: $model.settings.autoBuildUpdates)
                    .disabled(!model.settings.checkForUpdates)
                HStack {
                    Button("Check Now") { updates.check(userInitiated: true) }
                        .disabled(!updates.canUpdate || updates.state == .checking)
                    Text(updates.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("How updates work") {
                bullet("The app reads one small text file from its GitHub repository (\(UpdateConfig.repository)) to see the newest version number. That request is the only network use. It sends no recordings, settings or personal data; GitHub sees your IP address like any web request.")
                bullet("A newer version is downloaded as source code from the same repository and built on this Mac, so it needs Xcode. Nothing is installed until you click Restart to Update.")
                bullet("The new build replaces the installed app. Because it is signed with the same local certificate, macOS permissions normally carry over. If they do not, use Reset This App's Permissions in the Permissions & Privacy tab.")
                bullet("Turn the checks off here to make the app use no network at all.")
            }
        }
        .formStyle(.grouped)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
