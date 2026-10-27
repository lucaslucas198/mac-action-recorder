import Foundation

// MARK: - Options

/// Controls what the recorder keeps. Stored in the app settings.
public struct RecordingOptions: Codable, Equatable {
    public var includeMouseMove = true
    public var recordScroll = true
    /// Keyboard shortcuts (⌘/⌃ combinations) and special keys (Return, arrows, Delete, ...).
    public var recordShortcuts = true
    /// Ordinary typed characters.
    public var recordText = true
    /// Minimum time between stored mouse-move samples, in seconds.
    public var minEventInterval = 0.03
    /// Minimum pointer travel between stored mouse-move samples, in points.
    public var minMoveDistance = 3.0
    /// Use the time stamp macOS puts on each input event instead of the moment this app got to
    /// look at it. The event time is not affected by this app being busy, so gaps are more exact.
    public var preciseTiming = true

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeMouseMove = c.value(.includeMouseMove, includeMouseMove)
        recordScroll = c.value(.recordScroll, recordScroll)
        recordShortcuts = c.value(.recordShortcuts, recordShortcuts)
        recordText = c.value(.recordText, recordText)
        minEventInterval = c.value(.minEventInterval, minEventInterval)
        minMoveDistance = c.value(.minMoveDistance, minMoveDistance)
        preciseTiming = c.value(.preciseTiming, preciseTiming)
    }
}

// MARK: - Raw events

public enum RawEventKind: Equatable {
    case mouseMove
    case mouseDrag(MouseButton)
    case mouseDown(MouseButton, clickCount: Int)
    case mouseUp(MouseButton, clickCount: Int)
    case scroll(dx: Int, dy: Int)
    case keyDown(keyCode: Int, modifiers: KeyModifiers, characters: String, isRepeat: Bool)
    case keyUp(keyCode: Int, modifiers: KeyModifiers)
}

/// One captured input event. `time` comes from a monotonic clock, in seconds.
public struct RawEvent: Equatable {
    public var time: Double
    public var x: Double
    public var y: Double
    public var kind: RawEventKind
    /// Modifier keys held while a mouse or scroll event happened (Shift-click, ⌘-click, ...).
    /// Key events carry their own modifiers inside `kind`.
    public var modifiers: KeyModifiers

    public init(time: Double, x: Double = 0, y: Double = 0, kind: RawEventKind, modifiers: KeyModifiers = []) {
        self.time = time
        self.x = x
        self.y = y
        self.kind = kind
        self.modifiers = modifiers
    }
}

// MARK: - Mouse-move throttling

/// Decides which mouse-move samples to keep so high-frequency tracking stays cheap.
public struct MoveThrottle {
    public var minInterval: Double
    public var minDistance: Double
    private var lastTime: Double?
    private var lastX = 0.0
    private var lastY = 0.0

    public init(minInterval: Double, minDistance: Double) {
        self.minInterval = minInterval
        self.minDistance = minDistance
    }

    /// Returns true if the sample should be kept. Both the time and distance thresholds
    /// must be met relative to the last kept sample; the first sample is always kept.
    public mutating func shouldAccept(time: Double, x: Double, y: Double) -> Bool {
        guard let previous = lastTime else {
            remember(time, x, y)
            return true
        }
        let elapsed = time - previous
        let distance = hypot(x - lastX, y - lastY)
        if elapsed >= minInterval && distance >= minDistance {
            remember(time, x, y)
            return true
        }
        return false
    }

    public mutating func reset() {
        lastTime = nil
    }

    private mutating func remember(_ time: Double, _ x: Double, _ y: Double) {
        lastTime = time
        lastX = x
        lastY = y
    }
}

// MARK: - Builder

/// Turns the raw event stream into an editable list of actions:
/// - mouse down + up at the same spot become one click (and double/triple clicks are merged)
/// - consecutive typed characters become one text action
/// - shortcuts and special keys become key actions (key-down + key-up = one press)
/// - delays are the gaps between the end of one action and the start of the next
/// - a click keeps how long the button was held, and text keeps how long it took to type, so
///   playback can reproduce the recorded timeline
public enum RecordingBuilder {
    /// A pause longer than this starts a new text action instead of extending the last one.
    public static let textRunGap = 2.0
    /// Scroll events closer together than this are combined.
    public static let scrollCoalesceGap = 0.08
    /// Down/up positions closer than this (points) still count as a click.
    public static let clickSlop = 4.0

    public static func build(events: [RawEvent], options: RecordingOptions) -> [MacroAction] {
        var assembler = Assembler()
        var throttle = MoveThrottle(minInterval: options.minEventInterval, minDistance: options.minMoveDistance)
        var openButtons: [MouseButton] = []
        var lastX = 0.0
        var lastY = 0.0
        var index = 0

        while index < events.count {
            let event = events[index]
            lastX = event.x
            lastY = event.y

            switch event.kind {
            case .mouseMove:
                guard options.includeMouseMove,
                      throttle.shouldAccept(time: event.time, x: event.x, y: event.y) else { break }
                assembler.append(round2(.move(x: event.x, y: event.y)), start: event.time, end: event.time)

            case .mouseDrag(let button):
                guard options.includeMouseMove,
                      throttle.shouldAccept(time: event.time, x: event.x, y: event.y) else { break }
                assembler.append(
                    round2(.drag(x: event.x, y: event.y, button: button), modifiers: event.modifiers),
                    start: event.time,
                    end: event.time
                )

            case .mouseDown(let button, let downCount):
                if index + 1 < events.count,
                   case .mouseUp(let upButton, let upCount) = events[index + 1].kind,
                   upButton == button,
                   hypot(events[index + 1].x - event.x, events[index + 1].y - event.y) <= clickSlop {
                    let up = events[index + 1]
                    let count = max(1, max(downCount, upCount))
                    if count >= 2, let last = assembler.actions.last,
                       last.kind == .click, last.button == button,
                       last.clickCount == count - 1,
                       let lastPointX = last.x, let lastPointY = last.y,
                       hypot(lastPointX - event.x, lastPointY - event.y) <= clickSlop {
                        // Second (or third) click of a multi-click: upgrade the previous click.
                        let position = assembler.actions.count - 1
                        assembler.actions[position].clickCount = count
                        assembler.extendLast(to: up.time)
                        assembler.actions[position].duration = assembler.lastSpan
                    } else {
                        var click = round2(.click(x: event.x, y: event.y, button: button, count: min(count, 3)), modifiers: event.modifiers)
                        click.duration = roundMilliseconds(max(0, up.time - event.time))
                        assembler.append(click, start: event.time, end: up.time)
                    }
                    lastX = up.x
                    lastY = up.y
                    index += 1 // the matching mouse-up has been consumed
                } else {
                    assembler.append(
                        round2(.mouseDown(x: event.x, y: event.y, button: button), modifiers: event.modifiers),
                        start: event.time,
                        end: event.time
                    )
                    openButtons.append(button)
                }

            case .mouseUp(let button, _):
                // A release without a recorded press (e.g. the press happened in the app's own
                // window) is dropped rather than replayed.
                if let position = openButtons.firstIndex(of: button) {
                    openButtons.remove(at: position)
                    assembler.append(
                        round2(.mouseUp(x: event.x, y: event.y, button: button), modifiers: event.modifiers),
                        start: event.time,
                        end: event.time
                    )
                }

            case .scroll(let dx, let dy):
                guard options.recordScroll else { break }
                if let last = assembler.actions.last, last.kind == .scroll,
                   let end = assembler.lastEnd, event.time - end < scrollCoalesceGap {
                    let position = assembler.actions.count - 1
                    assembler.actions[position].scrollX = (last.scrollX ?? 0) + dx
                    assembler.actions[position].scrollY = (last.scrollY ?? 0) + dy
                    assembler.actions[position].x = roundPosition(event.x)
                    assembler.actions[position].y = roundPosition(event.y)
                    assembler.extendLast(to: event.time)
                } else {
                    assembler.append(
                        round2(.scroll(dx: dx, dy: dy, x: event.x, y: event.y), modifiers: event.modifiers),
                        start: event.time,
                        end: event.time
                    )
                }

            case .keyDown(let keyCode, let modifiers, let characters, _):
                let isShortcut = !modifiers.isDisjoint(with: [.command, .control])
                if isShortcut {
                    guard options.recordShortcuts else { break }
                    assembler.append(.key(keyCode, modifiers: modifiers), start: event.time, end: event.time)
                } else if isPrintable(characters) {
                    guard options.recordText else { break }
                    if let last = assembler.actions.last, last.kind == .text,
                       let end = assembler.lastEnd, event.time - end <= textRunGap {
                        let position = assembler.actions.count - 1
                        assembler.actions[position].text = (last.text ?? "") + characters
                        assembler.extendLast(to: event.time)
                        assembler.actions[position].duration = assembler.lastSpan
                    } else {
                        var text = MacroAction.text(characters)
                        text.duration = 0
                        assembler.append(text, start: event.time, end: event.time)
                    }
                } else {
                    guard options.recordShortcuts else { break }
                    assembler.append(.key(keyCode, modifiers: modifiers), start: event.time, end: event.time)
                }

            case .keyUp:
                // A key action already represents press + release.
                break
            }

            index += 1
        }

        // If recording stopped while a button was held, release it so replay can't leave it stuck.
        for button in openButtons {
            let at = assembler.lastEnd ?? 0
            assembler.append(round2(.mouseUp(x: lastX, y: lastY, button: button)), start: at, end: at)
        }

        return assembler.actions
    }

    /// True for ordinary text: not empty, no control characters, no function-key private-use codes.
    public static func isPrintable(_ characters: String) -> Bool {
        if characters.isEmpty { return false }
        for scalar in characters.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return false }
        }
        return true
    }

    // MARK: Helpers

    static func roundMilliseconds(_ value: Double) -> Double {
        return (value * 1000).rounded() / 1000
    }

    static func roundPosition(_ value: Double) -> Double {
        return (value * 100).rounded() / 100
    }

    private static func round2(_ action: MacroAction, modifiers: KeyModifiers = []) -> MacroAction {
        var result = action
        if let x = result.x { result.x = roundPosition(x) }
        if let y = result.y { result.y = roundPosition(y) }
        if !modifiers.isEmpty { result.modifiers = modifiers }
        return result
    }

    private struct Assembler {
        var actions: [MacroAction] = []
        var lastEnd: Double?
        var lastStart: Double?

        /// Time from the start to the end of the last action, rounded to milliseconds.
        var lastSpan: Double? {
            guard let start = lastStart, let end = lastEnd else { return nil }
            return RecordingBuilder.roundMilliseconds(max(0, end - start))
        }

        mutating func append(_ action: MacroAction, start: Double, end: Double) {
            var next = action
            if let previousEnd = lastEnd {
                next.delay = RecordingBuilder.roundMilliseconds(max(0, start - previousEnd))
            } else {
                next.delay = 0
            }
            actions.append(next)
            lastStart = start
            lastEnd = end
        }

        mutating func extendLast(to time: Double) {
            lastEnd = time
        }
    }
}
