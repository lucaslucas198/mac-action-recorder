import AppKit
import MacActionRecorderCore
import SwiftUI

/// The first-run screen. It checks what this Mac still needs, offers to do each part, and closes
/// with the Enter button. It can be opened again from the Help menu.
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var setup = SetupManager.shared
    @ObservedObject private var updates = UpdateManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    setupStep
                    permissionsStep
                    updatesStep
                    aiStep
                    privacyNote
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 640)
        .interactiveDismissDisabled(true)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Mac Action Recorder")
                    .font(.title2.weight(.semibold))
                Text("Record your mouse and keyboard once, then play it back at any speed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var setupStep: some View {
        let done = setup.isDone
        return StepCard(
            number: 1,
            title: "Set up this Mac",
            done: done
        ) {
            Text(done
                 ? "The app is in Applications and signed on this Mac, so the permissions below stay switched on after updates."
                 : "Moves the app to Applications and signs it with a certificate made on this Mac. Do this before the permissions, because macOS ties each permission to the app's signature. The app reopens when it is done. If macOS asks whether \"codesign\" may use a key, choose Always Allow.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !done {
                HStack {
                    Button("Set Up This Mac") { setup.run() }
                        .disabled(setup.phase == .working)
                    if setup.phase == .working {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if case .failed(let message) = setup.phase {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = setup.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionsStep: some View {
        let ready = setup.isDone
        return StepCard(
            number: 2,
            title: "Allow keyboard and mouse access",
            done: model.inputMonitoringGranted && model.accessibilityGranted
        ) {
            if !ready {
                Text("Finish step 1 first, otherwise these would need to be switched on again.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Group {
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets the app see what you click and type while recording, and hear the emergency-stop shortcut.",
                    granted: model.inputMonitoringGranted,
                    request: { Permissions.requestInputMonitoring() },
                    open: { Permissions.openInputMonitoringSettings() }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets the app click and type for you during playback.",
                    granted: model.accessibilityGranted,
                    request: { Permissions.requestAccessibility() },
                    open: { Permissions.openAccessibilitySettings() }
                )
            }
            .disabled(!ready)
            Text("In System Settings, switch the app on in each list (use the + button and pick it from Applications if it is not listed). Then come back; the checkmarks update by themselves. If a switch is on but still shows Not granted, use Quit and Reopen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit and Reopen") { Permissions.relaunch() }
                .controlSize(.small)
        }
    }

    private var updatesStep: some View {
        StepCard(number: 3, title: "Updates", done: nil) {
            Toggle("Check GitHub for new versions and download them in the background", isOn: updatesBinding)
            Text("New versions are only installed when you click Restart to Update. Turn this off and the app uses no network at all. You can change it later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiStep: some View {
        let availability = AIAssistant.availability
        return StepCard(number: 4, title: "On-device AI helper (optional)", done: nil) {
            Text(availability.isAvailable
                 ? "Available. It runs on this Mac and can suggest ways to make a macro more reliable. You always choose which changes to apply."
                 : availability.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyNote: some View {
        Text("The app records only after you click Start Recording, and shows a recording indicator in the menu bar the whole time. Recordings stay on this Mac. Anything you type while recording is saved in the recording, so do not record passwords.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if !(model.inputMonitoringGranted && model.accessibilityGranted && setup.isDone) {
                    Text("Something above is not finished. You can still enter and finish later: Help > Welcome & Setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Enter") { enter() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(16)
    }

    // MARK: Actions

    private var updatesBinding: Binding<Bool> {
        Binding(
            get: { model.settings.checkForUpdates },
            set: { on in
                model.settings.checkForUpdates = on
                model.settings.autoBuildUpdates = on
            }
        )
    }

    private func enter() {
        model.settings.hasCompletedWelcome = true
        model.showingWelcome = false
        updates.startSchedule()
    }
}

/// A numbered box in the Welcome screen with a done checkmark (or none, for optional steps).
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool?
    let content: Content

    init(number: Int, title: String, done: Bool?, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.done = done
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let done = done {
                    Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                        .foregroundStyle(done ? Color.green : Color.secondary)
                } else {
                    Image(systemName: "\(number).circle")
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2))
        )
    }
}
