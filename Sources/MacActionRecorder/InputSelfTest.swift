import AppKit
import ApplicationServices
import Foundation
import MacActionRecorderCore

/// CI only (`--selftest-input <folder>`): records and replays real input on the runner.
///
/// It opens an empty document in TextEdit, starts the real recorder, and sends ordinary mouse and
/// keyboard events (a click in the document, a word, Return) the way a person's hardware would. It
/// checks what the recorder made of them (positions, text, gaps), then replays the recording with
/// the real playback engine at 1× and 2× and reads the document's text back through the
/// Accessibility interface. Timing is measured, not assumed. Writes `input-report.txt`.
enum InputSelfTest {
    static var requestedFolder: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest-input"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func log(_ text: String) {
        lines.append(text)
        FileHandle.standardOutput.write((text + "\n").data(using: .utf8) ?? Data())
    }

    private static func check(_ ok: Bool, _ what: String) {
        log((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    private static func finish(_ folder: URL) -> Never {
        log(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("input-report.txt"), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }

    /// Runs off the main thread; the recorder's event tap is served by the main run loop.
    static func run(in folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        log("Accessibility trusted: \(AXIsProcessTrusted())")
        log("Input Monitoring (preflight): \(CGPreflightListenEventAccess())")

        // 1. An empty document in TextEdit.
        let document = folder.appendingPathComponent("selftest-input.txt")
        try? Data().write(to: document)
        _ = InstallDoctor.run("/usr/bin/open", ["-a", "TextEdit", document.path])
        var textEdit: NSRunningApplication?
        var window: WindowFrame?
        for _ in 0..<80 {
            Thread.sleep(forTimeInterval: 0.25)
            textEdit = Platform.onMain { Platform.runningApplication(bundleID: "com.apple.TextEdit") }
            if let app = textEdit, let frame = Platform.frontWindow(pid: app.processIdentifier).frame {
                window = frame
                break
            }
        }
        guard let app = textEdit, let frame = window else {
            check(false, "TextEdit opened a document window")
            finish(folder)
        }
        log("TextEdit window: \(Int(frame.x)), \(Int(frame.y)), \(Int(frame.width))×\(Int(frame.height))")
        Platform.onMain { Platform.activate(app) }
        Thread.sleep(forTimeInterval: 1.0)

        let target = CGPoint(x: frame.x + frame.width * 0.5, y: frame.y + frame.height * 0.6)
        // As in the app: playback reads the frontmost app without waiting for the main thread.
        Platform.onMain { FrontmostTracker.shared.start() }

        // Another app in front, so the recorded click is the one that switches to TextEdit (the
        // way a user clicks into Discord). Calculator is opened, moved beside TextEdit's window
        // (through the Accessibility interface) and made active by clicking its title bar, since
        // macOS refuses to activate an app from a background process, and a click on the desktop
        // can slide all windows aside.
        let calculator = prepareCalculator(awayFrom: frame)
        func bringOtherAppForward() {
            // This test app's own windows must not be under the clicks.
            Platform.onMain { for window in NSApp.windows { window.orderOut(nil) } }
            if let titleBar = calculator?.titleBar, titleBar.x >= 0 {
                postClick(at: titleBar)
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
        bringOtherAppForward()
        log("In front before recording: \(Platform.bundleIDOfFrontmostApp() ?? "unknown")")
        if let list = ScreenWindows.list() {
            let under = list.filter { $0.frame.contains(x: Double(target.x), y: Double(target.y)) }.prefix(4).map { window -> String in
                let info = AppDirectory.shared.info(for: window.pid)
                return "\(info?.bundleID ?? "pid \(window.pid)") layer \(window.layer) \(info?.isRegular == true ? "app" : "helper") \(Int(window.frame.width))×\(Int(window.frame.height))"
            }
            log("Windows under the click point, front to back: " + under.joined(separator: "; "))
        }

        // 2. Record.
        let recorder = EventRecorder()
        var options = RecordingOptions()
        options.includeMouseMove = false
        var startError: Error?
        Platform.onMain {
            do {
                try recorder.start(options: options, ignoredHotKey: HotKey.defaultEmergencyStop)
            } catch {
                startError = error
            }
        }
        check(startError == nil, "the recorder started (\(startError?.localizedDescription ?? "ok"))")
        if startError != nil { finish(folder) }
        Thread.sleep(forTimeInterval: 0.5)

        // The moment each press was really sent, to compare with what the recorder measured.
        var sent: [Double] = []
        sent.append(postClick(at: target))
        Thread.sleep(forTimeInterval: 0.40)
        // h e l l o, then Return
        for code in [4, 14, 37, 37, 31] {
            sent.append(postKey(code))
            Thread.sleep(forTimeInterval: 0.12)
        }
        Thread.sleep(forTimeInterval: 0.3)
        sent.append(postKey(36))
        Thread.sleep(forTimeInterval: 0.6)

        let output = Platform.onMain { recorder.stop() }
        log("Raw events captured: \(output.events.count); target app: \(output.targetApp?.name ?? "none"); window saved: \(output.targetWindow != nil)")
        log(String(format: "Event times from macOS's stamp: %d, from arrival: %d; largest delay before the app read an event: %.1f ms",
                   output.stampedEvents, output.arrivalTimedEvents, output.largestReadDelay * 1000))
        if let first = output.events.first {
            for event in output.events {
                log(String(format: "  raw %+.4f s  %@", event.time - first.time, String(describing: event.kind)))
            }
            log("  sent: " + sent.map { String(format: "%+.4f", $0 - sent[0]) }.joined(separator: " "))
        }
        let actions = RecordingBuilder.build(events: output.events, options: options)
        for (index, action) in actions.enumerated() {
            let took = action.duration.map { String(format: ", took %.3f s", $0) } ?? ""
            log(String(format: "  %2d  +%.3f s  %@%@", index + 1, action.delay, ActionDescriber.describe(action), took))
        }

        let click = actions.first { $0.kind == .click }
        if let click = click, let x = click.x, let y = click.y {
            let error = hypot(x - Double(target.x), y - Double(target.y))
            log(String(format: "Click position error: %.2f points", error))
            check(error <= 1.0, "the click was recorded at the position it happened (within 1 point)")
        } else {
            check(false, "a click was recorded")
        }
        let typed = actions.filter { $0.kind == .text }.compactMap { $0.text }.joined()
        check(typed == "hello", "the typed word was recorded as text (got \"\(typed)\")")
        check(actions.contains { $0.kind == .key && $0.keyCode == 36 }, "Return was recorded as a key press")
        check(output.targetApp?.bundleID == "com.apple.TextEdit", "TextEdit (the app that was clicked, not the one in front) was recorded as the target app")
        let clickStep = actions.first { $0.kind == .click }
        check(clickStep?.app == "com.apple.TextEdit", "the click knows it went to TextEdit (got \(clickStep?.app ?? "nothing"))")
        check(clickStep?.window != nil, "the click knows which TextEdit window it was in")
        check(actions.filter { $0.kind == .text || $0.kind == .key }.allSatisfy { $0.app == "com.apple.TextEdit" }, "the typing knows it went to TextEdit")
        check(output.targetWindow != nil, "the TextEdit window position was saved")

        // Recording accuracy: when the first letter and Return happened after the click press, as
        // sent and as rebuilt from the recording (delays plus the time each action took).
        let starts = timeline(of: actions)
        if sent.count == 7, let clickIndex = actions.firstIndex(where: { $0.kind == .click }),
           clickIndex + 2 < actions.count {
            let sentToText = sent[1] - sent[0]
            let recordedToText = starts[clickIndex + 1] - starts[clickIndex]
            let sentToReturn = sent[6] - sent[0]
            let recordedToReturn = starts[clickIndex + 2] - starts[clickIndex]
            let worst = max(abs(sentToText - recordedToText), abs(sentToReturn - recordedToReturn))
            log(String(format: "Click to first letter: sent %.4f s, recorded %.4f s", sentToText, recordedToText))
            log(String(format: "Click to Return: sent %.4f s, recorded %.4f s", sentToReturn, recordedToReturn))
            log(String(format: "Largest timing error while recording: %.1f ms", worst * 1000))
            check(worst <= 0.02, "the recorded timeline is within 20 ms of when the input was really sent")
        }

        // TextEdit may capitalise the first letter by itself, so compare without case.
        let before = documentText(of: app) ?? ""
        log("Document after recording: \(before.debugDescription)")
        check(before.lowercased() == "hello\n", "the document holds what was typed while recording")

        // 3. Replay at 1× and 2×, measuring how long it takes.
        var recording = Recording(name: "selftest", targetApp: output.targetApp, recordedScreen: Platform.primaryDisplaySize(), targetWindow: output.targetWindow, actions: actions)
        recording.actions = actions
        let recordedSpan = recording.originalDuration
        // Three runs at 1× (the machine's load varies from moment to moment) and one at 2×.
        var differences: [Double: [Double]] = [:]
        for speed in [1.0, 1.0, 1.0, 2.0] {
            // Same situation as when recording: another app in front, the first click goes to TextEdit.
            // The app's real step checks are on, so a wrong stop would fail this test.
            bringOtherAppForward()
            let performer = MacEventPerformer()
            let timing = TimingPerformer(performer)
            let safety = SafetyBox()
            safety.arm(
                options: SafetyOptions(),
                context: SafetyContext(target: recording.targetApp, recordedWindow: recording.targetWindow,
                                       recordedScreen: recording.recordedScreen, followWindow: true),
                verifyForeground: true,
                stepInfo: recording.hasStepInfo
            )
            let engine = PlaybackEngine(
                performer: timing,
                frontmostBundleID: { Platform.bundleIDOfFrontmostApp() },
                safetyCheck: { safety.check(action: $0, performer: performer) }
            )
            var config = PlaybackConfig()
            config.speed = speed
            let probe = PlaybackProbe()
            probe.start()
            let started = Date()
            do {
                try engine.start(recording: recording, config: config)
            } catch {
                check(false, "playback at \(speed)× started (\(error.localizedDescription))")
                continue
            }
            var state = engine.state
            while Date().timeIntervalSince(started) < 30 {
                state = engine.state
                if case .finished = state { break }
                if case .failed = state { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let took = Date().timeIntervalSince(started)
            log(String(format: "Playback at %.0f×: %@ in %.3f s (recorded length %.3f s, so about %.3f s expected)", speed, String(describing: state), took, recordedSpan, recordedSpan / speed))
            check(state == .finished, "playback at \(Int(speed))× finished with the step checks on")
            Thread.sleep(forTimeInterval: 0.3)
            let seen = probe.stop()
            if let worst = measurePlayback(seen: seen, actions: actions, speed: speed) {
                differences[speed, default: []].append(worst)
            }
            // When the engine handed each step to macOS, to tell the app's timing apart from how
            // long the system took to pass the event on.
            let handed = timing.entries
            if let click = handed.first(where: { $0.kind == .click || $0.kind == .mouseDown }),
               let letter = handed.first(where: { $0.kind == .text }),
               let enter = handed.last(where: { $0.kind == .key }),
               let press = seen.first(where: { $0.type == .leftMouseDown }) {
                let firstKey = seen.first { $0.type == .keyDown && $0.time > press.time }
                log(String(format: "  handed to macOS: click step %+.4f s, first letter %+.4f s, Return %+.4f s (from the click step); the system passed the press on %.1f ms and the first letter %.1f ms after handing over",
                           0.0, letter.start - click.start, enter.start - click.start,
                           (press.time - click.start) * 1000,
                           ((firstKey?.time ?? letter.start) - letter.start) * 1000))
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        let after = documentText(of: app) ?? ""
        log("Document after playback: \(after.debugDescription)")
        check(after.lowercased() == String(repeating: "hello\n", count: 5), "every playback typed the same text into the same document")
        for speed in differences.keys.sorted() {
            let values = (differences[speed] ?? []).sorted()
            guard !values.isEmpty else { continue }
            let median = values[values.count / 2]
            log(String(format: "Playback at %.0f×: largest difference per run %@ ms; median %.1f ms", speed,
                       values.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", "), median * 1000))
            check(median <= 0.03, "playback at \(Int(speed))× followed the recorded timeline within 30 ms (median of the runs)")
        }

        // Leave TextEdit without asking to save.
        _ = Platform.onMain { app.forceTerminate() }
        _ = Platform.onMain { calculator?.app.forceTerminate() }
        finish(folder)
    }

    // MARK: Another app

    /// Opens Calculator and moves its window to the right of `frame`, so a click on its title bar
    /// makes it the active app without covering TextEdit. Nil when that is not possible.
    private static func prepareCalculator(awayFrom frame: WindowFrame) -> (app: NSRunningApplication, titleBar: CGPoint)? {
        _ = InstallDoctor.run("/usr/bin/open", ["-a", "Calculator"])
        var calculator: NSRunningApplication?
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            calculator = Platform.onMain { Platform.runningApplication(bundleID: "com.apple.calculator") }
            if let found = calculator, Platform.frontWindow(pid: found.processIdentifier).frame != nil { break }
        }
        guard let app = calculator else {
            log("Calculator did not open; the test continues with TextEdit in front")
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement], let window = windows.first {
            var position = CGPoint(x: frame.x + frame.width + 10, y: frame.y + 40)
            if let value = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
        guard let moved = Platform.frontWindow(pid: app.processIdentifier).frame ??
                ScreenWindows.list().flatMap({ ScreenWindows.windows(of: app.processIdentifier, in: $0).first }) else {
            log("Calculator has no window on screen; the test continues with TextEdit in front")
            return (app, CGPoint(x: -1, y: -1))
        }
        log("Calculator window: \(Int(moved.x)), \(Int(moved.y)), \(Int(moved.width))×\(Int(moved.height))")
        return (app, CGPoint(x: moved.x + moved.width / 2, y: moved.y + 12))
    }

    // MARK: Timeline

    /// Start time of each action, rebuilt from its delay and the time the action before it took.
    private static func timeline(of actions: [MacroAction]) -> [Double] {
        var starts: [Double] = []
        var clock = 0.0
        for action in actions {
            clock += action.delay
            starts.append(clock)
            if action.kind == .wait || action.kind == .click || action.kind == .text {
                clock += action.duration ?? 0
            }
        }
        return starts
    }

    /// Compares when playback really pressed the button, typed the first letter and pressed Return
    /// with the recorded timeline divided by the speed.
    @discardableResult
    private static func measurePlayback(seen: [PlaybackProbe.Seen], actions: [MacroAction], speed: Double) -> Double? {
        let starts = timeline(of: actions)
        guard let clickIndex = actions.firstIndex(where: { $0.kind == .click }), clickIndex + 2 < actions.count,
              let press = seen.first(where: { $0.type == .leftMouseDown }) else {
            check(false, "playback at \(Int(speed))× was observed (\(seen.count) events seen)")
            return nil
        }
        let keys = seen.filter { $0.type == .keyDown && $0.time > press.time }
        guard let firstLetter = keys.first, let returnKey = keys.last(where: { $0.keyCode == 36 }) else {
            check(false, "playback at \(Int(speed))× typed and pressed Return (\(keys.count) key presses seen)")
            return nil
        }
        let expectToText = (starts[clickIndex + 1] - starts[clickIndex]) / speed
        let expectToReturn = (starts[clickIndex + 2] - starts[clickIndex]) / speed
        let gotToText = firstLetter.time - press.time
        let gotToReturn = returnKey.time - press.time
        let worst = max(abs(expectToText - gotToText), abs(expectToReturn - gotToReturn))
        log(String(format: "Playback at %.0f×: click to first letter %.4f s (recorded %.4f s), click to Return %.4f s (recorded %.4f s), largest difference %.1f ms",
                   speed, gotToText, expectToText, gotToReturn, expectToReturn, worst * 1000))
        return worst
    }

    // MARK: Sending events like hardware does (no marker, so the recorder sees them)

    /// Returns the moment the button press was sent.
    @discardableResult
    private static func postClick(at point: CGPoint) -> Double {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        let pressed = ProcessInfo.processInfo.systemUptime
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        return pressed
    }

    /// Returns the moment the key press was sent.
    @discardableResult
    private static func postKey(_ code: Int) -> Double {
        let source = CGEventSource(stateID: .hidSystemState)
        let pressed = ProcessInfo.processInfo.systemUptime
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)?.post(tap: .cghidEventTap)
        return pressed
    }

    // MARK: Reading the document back

    private static func documentText(of app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else { return nil }
        // swiftlint:disable:next force_cast
        return findText(in: window as! AXUIElement, depth: 0)
    }

    private static func findText(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == (kAXTextAreaRole as String) {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            return value as? String
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let text = findText(in: child, depth: depth + 1) { return text }
        }
        return nil
    }
}

/// Watches every mouse press and key press (including the ones playback posts) with a listen-only
/// tap on the main run loop, to measure when playback really sent them. Self-test only.
final class PlaybackProbe {
    struct Seen {
        let time: Double
        let type: CGEventType
        let keyCode: Int
    }

    private let lock = NSLock()
    private var seen: [Seen] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon = refcon {
                let probe = Unmanaged<PlaybackProbe>.fromOpaque(refcon).takeUnretainedValue()
                probe.note(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        let mask = EventTapSupport.mask(for: [.leftMouseDown, .leftMouseUp, .keyDown])
        Platform.onMain {
            if let installed = EventTapSupport.install(mask: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                tap = installed.tap
                source = installed.source
            }
        }
    }

    private func note(type: CGEventType, event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        lock.lock()
        seen.append(Seen(time: now, type: type, keyCode: code))
        lock.unlock()
    }

    func stop() -> [Seen] {
        Platform.onMain {
            if let tap = tap, let source = source {
                EventTapSupport.remove(tap: tap, source: source)
            }
            tap = nil
            source = nil
        }
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

/// Passes every step to the real performer and notes when it was handed over. Self-test only.
final class TimingPerformer: ActionPerformer {
    struct Entry {
        let kind: ActionKind
        let start: Double
    }

    private let inner: ActionPerformer
    private let lock = NSLock()
    private var log: [Entry] = []

    init(_ inner: ActionPerformer) {
        self.inner = inner
    }

    func perform(_ action: MacroAction) throws {
        let start = ProcessInfo.processInfo.systemUptime
        lock.lock()
        log.append(Entry(kind: action.kind, start: start))
        lock.unlock()
        try inner.perform(action)
    }

    func cleanup() {
        inner.cleanup()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }
}
