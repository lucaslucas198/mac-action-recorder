import AppKit
import MacActionRecorderCore
import SwiftUI

/// The first-run flow. It fills the whole window and has two pages:
///
/// 1. Home: the logo, the name and **Get Started**.
/// 2. Setup: installs the app with a step-by-step progress screen, then walks through the two
///    permissions, and closes with **Enter**.
///
/// Get Started slides over to the setup page and starts the installation by itself. After an
/// update, or from Help > Welcome & Setup, the window opens straight on the setup page.
struct WelcomeView: View {
    private enum Page {
        case home
        case setup
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var setup = SetupManager.shared
    @State private var page: Page = .home
    @State private var ai: AIStatus?
    @State private var confirmRepair = false

    private struct AIStatus {
        let isAvailable: Bool
        let message: String
    }

    var body: some View {
        ZStack {
            switch page {
            case .home:
                HomePage(onStart: getStarted)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .setup:
                setupPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear {
            if model.welcomeStartsOnSetup || model.settings.hasCompletedWelcome || setup.isWorking || setup.isContinuing {
                page = .setup
            }
        }
        .onChange(of: model.welcomeStartsOnSetup) { onSetup in
            if onSetup {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) { page = .setup }
            }
        }
    }

    private func getStarted() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) {
            page = .setup
        }
        // Start installing as soon as the page has slid in.
        if !setup.isDone && !setup.isWorking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                setup.run()
            }
        }
    }

    // MARK: Setup page

    private var setupPage: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    installCard
                    permissionsCard
                    optionsCard
                    privacyNote
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if ai == nil {
                let found = AIAssistant.availability
                ai = AIStatus(isAvailable: found.isAvailable, message: found.message)
            }
            model.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Mac Action Recorder")
                    .font(.title.weight(.semibold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !setup.isWorking {
                Button {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) { page = .home }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .opacity(model.settings.hasCompletedWelcome ? 0 : 1)
                .disabled(model.settings.hasCompletedWelcome)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var headerSubtitle: String {
        if setup.isWorking { return "Working… keep this window open. It only takes a moment." }
        if allDone { return "Everything is ready." }
        return "Two steps: install the app, then allow keyboard and mouse access."
    }

    private var allDone: Bool {
        return setup.isDone && model.inputMonitoringGranted && model.accessibilityGranted
    }

    // MARK: Step 1: install

    private var installCard: some View {
        StepCard(number: 1, title: "Install on this Mac", done: setup.isDone && !setup.isWorking) {
            switch setup.phase {
            case .running:
                SetupProgressView(setup: setup)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Setup stopped", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can try again. If it keeps failing: quit the app, drag it from the disk image into your Applications folder yourself, and open it from there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { setup.run() }
                        .buttonStyle(.borderedProminent)
                }
            case .finished:
                finishedSummary
            case .idle:
                if setup.isDone {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Installed in Applications and signed for this Mac.", systemImage: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                        Text("Permissions you switch on will keep working after updates.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Check for Old Copies Again") { setup.run() }
                            .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Puts the app in your Applications folder, signs it with a certificate made on this Mac (so macOS remembers your permissions after updates), ejects old installer disks and moves other copies to the Trash. The app reopens once on its own.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            setup.run()
                        } label: {
                            Label("Install and Set Up", systemImage: "arrow.down.app")
                                .frame(minWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
            if let note = setup.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var finishedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Installed and tidied up.", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
            ProgressView(value: 1)
                .tint(.green)
            ForEach(setup.results, id: \.self) { line in
                Label(line, systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("What was done") {
                StepList(planned: setup.plannedSteps, completed: setup.completed, current: nil)
                    .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    // MARK: Step 2: permissions

    private var permissionsCard: some View {
        StepCard(
            number: 2,
            title: "Allow keyboard and mouse access",
            done: setup.isDone && !setup.isWorking && model.inputMonitoringGranted && model.accessibilityGranted
        ) {
            if !setup.isDone || setup.isWorking {
                Label("Finish step 1 first. Permissions switched on before that would have to be switched on again.", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    PermissionStep(
                        title: "Input Monitoring",
                        purpose: "lets the app see your clicks and typing while recording, and hear the emergency-stop shortcut.",
                        granted: model.inputMonitoringGranted,
                        listName: "Input Monitoring",
                        open: {
                            Permissions.requestInputMonitoring()
                            Permissions.openInputMonitoringSettings()
                        }
                    )
                    PermissionStep(
                        title: "Accessibility",
                        purpose: "lets the app click and type for you during playback.",
                        granted: model.accessibilityGranted,
                        listName: "Accessibility",
                        open: {
                            Permissions.requestAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                    )
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Switched it on but it still says Not allowed?")
                            .font(.callout.weight(.medium))
                        Text("Input Monitoring often needs the app to restart: click Quit and Reopen. If that does not help, Repair removes this app's old entries from both lists; then switch it on again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Check Again") { model.recheckInputMonitoring() }
                            Button("Quit and Reopen") { Permissions.relaunch() }
                            Button("Repair…") { confirmRepair = true }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .confirmationDialog("Remove this app's old permission entries?", isPresented: $confirmRepair, titleVisibility: .visible) {
            Button("Remove and Start Again", role: .destructive) {
                let done = InstallDoctor.repairPermissionsIfNeeded(force: true)
                model.refreshPermissions()
                if done {
                    Permissions.requestInputMonitoring()
                    Permissions.requestAccessibility()
                } else {
                    model.showNotice("The entries could not be removed. In System Settings, select Mac Action Recorder in each list and click the minus button, then add it again.", isError: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mac Action Recorder is removed from the Input Monitoring and Accessibility lists. Nothing else changes. macOS then asks again, and you switch both on.")
        }
    }

    // MARK: Options

    private var optionsCard: some View {
        StepCard(number: nil, title: "Options", done: nil) {
            Toggle("Check GitHub for new versions and download them in the background", isOn: updatesBinding)
            Text("A new version is installed only when you click Restart to Update, and it keeps your permissions. Turn this off and the app uses no network at all.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                if let ai = ai {
                    Text(ai.isAvailable
                         ? "On-device AI helper: available. It runs on this Mac and suggests ways to make macros more reliable; you choose what to apply."
                         : "On-device AI helper: " + ai.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var privacyNote: some View {
        Text("The app records only after you click Start Recording and shows a red indicator the whole time. Recordings stay on this Mac. Anything you type while recording is saved in the recording, so do not record passwords.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if setup.isWorking {
                ProgressView().controlSize(.small)
                Text("Setting up… \(Int((setup.progress * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !allDone {
                Text("You can enter now and finish the rest later from Help > Welcome & Setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("All set", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Spacer()
            Button {
                enter()
            } label: {
                Text("Enter")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(setup.isWorking)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
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
        model.welcomeStartsOnSetup = false
        model.showingWelcome = false
        UpdateManager.shared.startSchedule()
    }
}

// MARK: - Progress

/// The moving bar, the step it is on, what that step is doing right now, and every step's state.
struct SetupProgressView: View {
    @ObservedObject var setup: SetupManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(setup.currentStep?.title ?? "Working")
                    .font(.headline)
                Spacer()
                Text("\(Int((setup.progress * 100).rounded()))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, setup.progress)))
                .progressViewStyle(.linear)
                .animation(.linear(duration: 0.1), value: setup.progress)
            if let step = setup.currentStep {
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(setup.liveLine ?? "Working…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(Int(setup.stepElapsed)) s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if setup.stepElapsed > step.typicalSeconds * 2.5, let hint = step.slowHint {
                    Label(hint, systemImage: "hand.point.up.left")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            StepList(planned: setup.plannedSteps, completed: setup.completed, current: setup.currentStep)
        }
    }
}

/// Every planned step with a checkmark (and time) when done, a spinner when running, or a circle.
struct StepList: View {
    let planned: [SetupStep]
    let completed: [SetupManager.CompletedStep]
    let current: SetupStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(planned) { step in
                HStack(spacing: 8) {
                    icon(for: step)
                        .frame(width: 16)
                    Text(step.title)
                        .font(.callout)
                        .foregroundStyle(step != current && doneStep(step) == nil ? Color.secondary : Color.primary)
                    if let done = doneStep(step), let note = done.note {
                        Text("· " + note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if let done = doneStep(step), done.seconds >= 0.05 {
                        Text(String(format: "%.1f s", done.seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func doneStep(_ step: SetupStep) -> SetupManager.CompletedStep? {
        return completed.first { $0.step == step }
    }

    @ViewBuilder
    private func icon(for step: SetupStep) -> some View {
        if doneStep(step) != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if step == current {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Permission step

/// One permission with numbered instructions and a live status.
private struct PermissionStep: View {
    let title: String
    let purpose: String
    let granted: Bool
    let listName: String
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.orange)
                .frame(width: 28)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: granted)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Text(granted ? "Allowed" : "Not allowed yet")
                        .font(.callout)
                        .foregroundStyle(granted ? Color.green : Color.secondary)
                    Spacer()
                    if !granted {
                        Button("Open \(listName) Settings", action: open)
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text(title + " " + purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. Click Open \(listName) Settings. System Settings opens on the right list.")
                        Text("2. Switch on Mac Action Recorder. Not in the list? Click +, choose Applications > Mac Action Recorder, click Open.")
                        Text("3. If macOS offers Quit & Reopen, click it. This window comes back by itself.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Home page

/// The first thing a new user sees: the logo, the name, and one button. Elements ease in one
/// after another.
private struct HomePage: View {
    let onStart: () -> Void
    @State private var shown = false
    @State private var glow = false

    private let deep = Color(red: 0.08, green: 0.22, blue: 0.58)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.44, blue: 0.92), deep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // A soft light behind the logo that slowly breathes.
            RadialGradient(
                colors: [Color.white.opacity(glow ? 0.20 : 0.10), Color.white.opacity(0)],
                center: .center,
                startRadius: 10,
                endRadius: 300
            )
            .frame(width: 600, height: 600)
            .offset(y: -70)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: glow)

            VStack(spacing: 0) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 180, height: 180)
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                    .scaleEffect(shown ? 1 : 0.7)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.7, dampingFraction: 0.7), value: shown)
                Text("Mac Action Recorder")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 26)
                    .offset(y: shown ? 0 : 16)
                    .opacity(shown ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.15), value: shown)
                Text("Record once. Replay at any speed.")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 8)
                    .offset(y: shown ? 0 : 16)
                    .opacity(shown ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.3), value: shown)
                Spacer()
                Button(action: onStart) {
                    HStack(spacing: 10) {
                        Text("Get Started")
                        Image(systemName: "arrow.right")
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(deep)
                    .frame(width: 300, height: 54)
                    .background(Capsule().fill(Color.white))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(0.5), value: shown)
                Text("Setup takes about a minute. Everything stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 14)
                    .padding(.bottom, 44)
                    .opacity(shown ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.6), value: shown)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            shown = true
            glow = true
        }
    }
}

/// A box in the setup page with a number (or none) and a done checkmark.
private struct StepCard<Content: View>: View {
    let number: Int?
    let title: String
    let done: Bool?
    let content: Content

    init(number: Int?, title: String, done: Bool?, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.done = done
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if done == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                } else if let number = number {
                    Image(systemName: "\(number).circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        )
        .animation(.easeInOut(duration: 0.25), value: done)
    }
}
