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

        let gapAfterClick = 0.40
        let gapBetweenKeys = 0.12
        postClick(at: target)
        Thread.sleep(forTimeInterval: gapAfterClick)
        // h e l l o, then Return
        for code in [4, 14, 37, 37, 31] {
            postKey(code)
            Thread.sleep(forTimeInterval: gapBetweenKeys)
        }
        Thread.sleep(forTimeInterval: 0.3)
        postKey(36)
        Thread.sleep(forTimeInterval: 0.6)

        let output = Platform.onMain { recorder.stop() }
        log("Raw events captured: \(output.events.count); target app: \(output.targetApp?.name ?? "none"); window saved: \(output.targetWindow != nil)")
        let actions = RecordingBuilder.build(events: output.events, options: options)
        for (index, action) in actions.enumerated() {
            log(String(format: "  %2d  +%.3f s  %@", index + 1, action.delay, ActionDescriber.describe(action)))
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
        check(output.targetApp?.bundleID == "com.apple.TextEdit", "TextEdit was recorded as the target app")
        check(output.targetWindow != nil, "the TextEdit window position was saved")

        if let clickIndex = actions.firstIndex(where: { $0.kind == .click }), clickIndex + 1 < actions.count {
            let measured = actions[clickIndex + 1].delay
            log(String(format: "Gap after the click: sent %.3f s, recorded %.3f s", gapAfterClick, measured))
            check(abs(measured - gapAfterClick) <= 0.05, "the gap after the click was recorded within 50 ms")
        }

        let before = documentText(of: app) ?? ""
        log("Document after recording: \(before.debugDescription)")
        check(before == "hello\n", "the document holds what was typed while recording")

        // 3. Replay at 1× and 2×, measuring how long it takes.
        var recording = Recording(name: "selftest", targetApp: output.targetApp, recordedScreen: Platform.primaryDisplaySize(), targetWindow: output.targetWindow, actions: actions)
        recording.actions = actions
        let recordedSpan = actions.reduce(0) { $0 + $1.delay }
        for speed in [1.0, 2.0] {
            Platform.onMain { Platform.activate(app) }
            Thread.sleep(forTimeInterval: 0.8)
            let engine = PlaybackEngine(performer: MacEventPerformer(), frontmostBundleID: { Platform.bundleIDOfFrontmostApp() })
            var config = PlaybackConfig()
            config.speed = speed
            config.requiredBundleID = "com.apple.TextEdit"
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
            log(String(format: "Playback at %.0f×: %@ in %.3f s (recorded gaps add up to %.3f s, expected about %.3f s plus typing)", speed, String(describing: state), took, recordedSpan, recordedSpan / speed))
            check(state == .finished, "playback at \(Int(speed))× finished")
            Thread.sleep(forTimeInterval: 0.6)
        }

        let after = documentText(of: app) ?? ""
        log("Document after playback: \(after.debugDescription)")
        check(after == "hello\nhello\nhello\n", "playback at 1× and 2× typed the same text into the same document")

        // Leave TextEdit without asking to save.
        _ = Platform.onMain { app.forceTerminate() }
        finish(folder)
    }

    // MARK: Sending events like hardware does (no marker, so the recorder sees them)

    private static func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func postKey(_ code: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)?.post(tap: .cghidEventTap)
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
