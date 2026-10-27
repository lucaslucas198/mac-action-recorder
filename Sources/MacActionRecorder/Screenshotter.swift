import AppKit
import MacActionRecorderCore
import SwiftUI

/// Renders the main screens to PNG files and quits. Started only with the `--screenshots <folder>`
/// argument, which the CI workflow uses so the layout can be checked on every change. It uses
/// made-up sample data, touches no recordings on disk, and needs no permissions.
enum Screenshotter {
    static var requestedFolder: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshots"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    private struct Shot {
        let name: String
        let size: CGSize
        let dark: Bool
        let prepare: () -> Void
        let view: () -> AnyView
    }

    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel.shared
        let setup = SetupManager.shared
        model.loadForScreenshots(sampleRecordings(), safetyStop: SafetyWatchdog.messagePrefix + "The Discord window changed size (recorded 1200×800, now 1000×700), so the recorded click positions no longer line up.")
        model.settings.discord.favoriteChannels = ["general", "announcements", "bot-testing"]
        model.settings.discord.messageTemplates = ["gm everyone", "Reminder: meeting at 5"]

        func main(_ welcome: Bool, onSetup: Bool = false, completed: Bool = true) -> () -> Void {
            return {
                model.settings.hasCompletedWelcome = completed
                model.welcomeStartsOnSetup = onSetup
                model.showingWelcome = welcome
            }
        }
        let mainView = { AnyView(MainView().environmentObject(model)) }
        func settingsTab<V: View>(_ view: V) -> () -> AnyView {
            return { AnyView(view.environmentObject(model).frame(width: 760, height: 640)) }
        }

        let shots: [Shot] = [
            Shot(name: "01-welcome-home", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: { main(true, onSetup: false, completed: false)(); setup.simulateForScreenshots(step: nil, done: [], finished: false, installed: false) },
                 view: mainView),
            Shot(name: "02-setup-start", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: { main(true, onSetup: true, completed: false)(); setup.simulateForScreenshots(step: nil, done: [], finished: false, installed: false) },
                 view: mainView),
            Shot(name: "03-setup-running", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: { main(true, onSetup: true, completed: false)(); setup.simulateForScreenshots(step: .signing, done: [.checking, .closingOthers, .copying], finished: false, installed: false) },
                 view: mainView),
            Shot(name: "04-setup-finished", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: { main(true, onSetup: true, completed: false)(); setup.simulateForScreenshots(step: nil, done: SetupStep.allCases, finished: true, installed: true) },
                 view: mainView),
            Shot(name: "05-setup-finished-dark", size: CGSize(width: 1040, height: 780), dark: true,
                 prepare: { main(true, onSetup: true, completed: false)(); setup.simulateForScreenshots(step: nil, done: SetupStep.allCases, finished: true, installed: true) },
                 view: mainView),
            Shot(name: "06-setup-permissions-needed", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: {
                     main(true, onSetup: true, completed: false)()
                     setup.simulateForScreenshots(step: nil, done: [], finished: false, installed: true)
                     model.setPermissionsForScreenshots(accessibility: false, inputMonitoring: false)
                 },
                 view: mainView),
            Shot(name: "07-setup-one-permission", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: {
                     main(true, onSetup: true, completed: false)()
                     setup.simulateForScreenshots(step: nil, done: [], finished: false, installed: true)
                     model.setPermissionsForScreenshots(accessibility: true, inputMonitoring: false)
                 },
                 view: mainView),
            Shot(name: "08-main-permission-banner", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: {
                     main(false)()
                     model.setPermissionsForScreenshots(accessibility: false, inputMonitoring: false)
                 },
                 view: mainView),
            Shot(name: "10-main", size: CGSize(width: 1040, height: 780), dark: false,
                 prepare: { main(false)(); model.setPermissionsForScreenshots(accessibility: true, inputMonitoring: true) },
                 view: mainView),
            Shot(name: "11-main-smallest", size: CGSize(width: 960, height: 700), dark: false, prepare: main(false), view: mainView),
            Shot(name: "12-main-large", size: CGSize(width: 1440, height: 900), dark: false, prepare: main(false), view: mainView),
            Shot(name: "13-main-dark", size: CGSize(width: 1040, height: 780), dark: true, prepare: main(false), view: mainView),
            Shot(name: "20-check-sheet", size: CGSize(width: 660, height: 760), dark: false, prepare: main(false),
                 view: { AnyView(MacroCheckSheet().environmentObject(model)) }),
            Shot(name: "21-add-click", size: CGSize(width: 440, height: 520), dark: false, prepare: main(false),
                 view: { AnyView(ActionEditSheet(action: .click(x: 640, y: 412), mode: .add(afterID: nil)).environmentObject(model)) }),
            Shot(name: "30-settings-window", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false),
                 view: { AnyView(SettingsView().environmentObject(model)) }),
            Shot(name: "31-settings-general", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(GeneralSettingsTab())),
            Shot(name: "32-settings-recording", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(RecordingSettingsTab())),
            Shot(name: "33-settings-playback", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(PlaybackSettingsTab())),
            Shot(name: "34-settings-safety", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(SafetySettingsTab())),
            Shot(name: "35-settings-discord", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(DiscordSettingsTab())),
            Shot(name: "36-settings-ai", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(AISettingsTab())),
            Shot(name: "37-settings-storage", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(StorageSettingsTab())),
            Shot(name: "38-settings-privacy", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(PermissionsSettingsTab())),
            Shot(name: "39-settings-updates", size: CGSize(width: 760, height: 640), dark: false, prepare: main(false), view: settingsTab(UpdatesSettingsTab()))
        ]

        var report: [String] = []
        for shot in shots {
            NSApp.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
            shot.prepare()
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: shot.size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
            window.title = shot.name
            let host = NSHostingView(rootView: shot.view().frame(width: shot.size.width, height: shot.size.height))
            window.contentView = host
            window.setContentSize(shot.size)
            window.orderFrontRegardless()
            // Let SwiftUI lay out and finish its appear animations.
            RunLoop.main.run(until: Date().addingTimeInterval(1.8))
            host.layoutSubtreeIfNeeded()
            let url = folder.appendingPathComponent(shot.name + ".png")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                    report.append("\(shot.name): \(Int(host.bounds.width))x\(Int(host.bounds.height)) fitting \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
                }
            }
            window.orderOut(nil)
            window.close()
        }
        try? report.joined(separator: "\n").write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    static func sampleRecordings() -> [Recording] {
        var actions: [MacroAction] = Presets.openChannel("general")
        actions.append(.move(x: 700, y: 610, delay: 0.3))
        var click = MacroAction.click(x: 702, y: 612, delay: 0.12)
        actions.append(click)
        click = MacroAction.click(x: 980, y: 210, delay: 0.8)
        click.modifiers = [.shift]
        actions.append(click)
        actions.append(.text("Hello from Mac Action Recorder! This is a longer message to check that long rows are cut off neatly instead of overlapping.", delay: 0.4))
        actions.append(.key(KeyCodes.returnKey, delay: 0.2))
        actions.append(.wait(2))
        actions.append(.scroll(dx: 0, dy: -120, x: 800, y: 500, delay: 0.5))
        actions.append(.click(x: 300, y: 420, button: .right, delay: 0.6))
        for index in 0..<20 {
            actions.append(.move(x: 300 + Double(index) * 4, y: 420 + Double(index) * 2, delay: 0.016))
        }
        let main = Recording(
            name: "Send a good-morning message",
            targetApp: TargetApp(bundleID: "com.hnc.Discord", name: "Discord"),
            recordedScreen: ScreenSize(width: 1512, height: 982),
            playbackDefaults: PlaybackDefaults(speed: 1.5, repeatCount: 3, loopDelay: 5),
            targetWindow: WindowFrame(x: 100, y: 80, width: 1200, height: 800),
            startChannel: "general",
            actions: actions
        )
        let second = Recording(name: "Moderation: clear reactions", targetApp: TargetApp(bundleID: "com.hnc.Discord", name: "Discord"), actions: [.key(KeyCodes.escape)])
        let third = Recording(name: "Typing test in TextEdit", actions: [.text("abc")])
        return [main, second, third]
    }
}
