import AppKit
import MacActionRecorderCore
import SwiftUI

/// The first-run flow, in two pages:
///
/// 1. A home page with the big logo and a **Get Started** button.
/// 2. The setup page: sets the app up on this Mac, shows the live status of the two permissions,
///    and closes with the **Enter** button.
///
/// It can be opened again from Help > Welcome & Setup. After "Set Up This Mac" reopens the app,
/// it starts on the setup page, because the home page was already seen.
struct WelcomeView: View {
    private enum Page {
        case home
        case setup
    }

    private static let homeSeenKey = "welcomeHomeSeen"

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var setup = SetupManager.shared
    @State private var page: Page = UserDefaults.standard.bool(forKey: WelcomeView.homeSeenKey) ? .setup : .home
    @State private var ai: AIStatus?

    private struct AIStatus {
        let isAvailable: Bool
        let message: String
    }

    var body: some View {
        ZStack {
            switch page {
            case .home:
                HomePage(onStart: getStarted)
                    .transition(.opacity)
            case .setup:
                setupPage
                    .transition(.opacity)
            }
        }
        .frame(width: 600, height: 590)
        .interactiveDismissDisabled(true)
    }

    private func getStarted() {
        UserDefaults.standard.set(true, forKey: WelcomeView.homeSeenKey)
        withAnimation(.easeInOut(duration: 0.25)) {
            page = .setup
        }
    }

    // MARK: Setup page

    private var setupPage: some View {
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
        .onAppear {
            // Asked once, not on every redraw.
            if ai == nil {
                let found = AIAssistant.availability
                ai = AIStatus(isAvailable: found.isAvailable, message: found.message)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Set up Mac Action Recorder")
                    .font(.title2.weight(.semibold))
                Text("Three short steps. You can finish them later from Help > Welcome & Setup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var setupStep: some View {
        let done = setup.isDone
        return StepCard(number: 1, title: "Set up this Mac", done: done) {
            Text(done
                 ? "The app is in Applications and signed on this Mac, so the permissions below stay switched on after updates."
                 : "Moves the app to Applications and signs it with a certificate made on this Mac. Do this before the permissions, because macOS ties each permission to the app's signature. The app reopens when it is done.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !done {
                if case .working(let stage) = setup.phase {
                    progress(for: stage)
                } else {
                    Button("Set Up This Mac") { setup.run() }
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

    /// The loading bar. It moves when a stage really begins; the text says what is happening.
    private func progress(for stage: SetupStage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: stage.fraction)
                .animation(.easeInOut(duration: 0.4), value: stage.fraction)
            HStack {
                Text(stage.title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(stage.stepText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let hint = stage.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        StepCard(number: 4, title: "On-device AI helper (optional)", done: nil) {
            if let ai = ai {
                Text(ai.isAvailable
                     ? "Available. It runs on this Mac and can suggest ways to make a macro more reliable. You always choose which changes to apply."
                     : ai.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
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
            if !(model.inputMonitoringGranted && model.accessibilityGranted && setup.isDone) {
                Text("Something above is not finished. You can still enter and finish later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Enter") { enter() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(setup.isWorking)
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
        UpdateManager.shared.startSchedule()
    }
}

// MARK: - Home page

/// The first thing a new user sees: the logo, the name, and one button.
private struct HomePage: View {
    let onStart: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.40, blue: 0.88), Color(red: 0.08, green: 0.22, blue: 0.58)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 170, height: 170)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                Text("Mac Action Recorder")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 22)
                Text("Record once. Replay at any speed.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 6)
                Spacer()
                Button(action: onStart) {
                    Text("Get Started")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(red: 0.08, green: 0.22, blue: 0.58))
                        .frame(width: 300, height: 52)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Text("A short setup follows. Everything stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 12)
                    .padding(.bottom, 34)
            }
        }
    }
}

/// A numbered box in the setup page with a done checkmark (or none, for optional steps).
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
