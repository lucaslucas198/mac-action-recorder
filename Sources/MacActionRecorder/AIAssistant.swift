import Foundation
import MacActionRecorderCore

#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

enum AIAssistantError: LocalizedError {
    case unavailable(String)
    case emptyReply
    case timedOut(Int)
    case busy

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyReply: return "The model returned an empty answer. Try again."
        case .timedOut(let seconds): return "The on-device model did not answer within \(seconds) seconds, so the request was stopped. Try again; the first request after starting the Mac is the slowest."
        case .busy: return "The on-device model is still working on another request. Wait for it to finish."
        }
    }
}

/// Lets the cancel handler reach the request that is running.
private final class ResumerHolder<T> {
    private let lock = NSLock()
    private var value: OnceResumer<T>?

    func set(_ resumer: OnceResumer<T>) {
        lock.lock()
        value = resumer
        lock.unlock()
    }

    func get() -> OnceResumer<T>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Resumes a continuation exactly once, whichever of the answer, the time limit or a cancel comes first.
private final class OnceResumer<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    var task: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending = pending else { return false }
        pending.resume(with: result)
        return true
    }
}

/// Optional advice from Apple's on-device language model (the Foundation Models framework,
/// macOS 26 or newer, Apple Intelligence turned on).
///
/// - The model runs on this Mac; the app sends nothing over the network.
/// - Its review is shown as text. Its suggested edits are parsed into a small set of safe edits that the user must choose to apply.
/// - It is given a short text summary of the actions, never the macro file itself.
/// - Its answers can be wrong; the UI says so.
enum AIAssistant {
    /// Whether the model can be used right now, and if not, why.
    static var availability: (isAvailable: Bool, message: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "")
            default:
                return (false, "The on-device model is not ready. It needs a Mac with Apple Intelligence turned on (System Settings > Apple Intelligence & Siri), and the model may still be downloading.")
            }
        }
        #endif
        return (false, "On-device AI needs macOS 26 or newer with Apple Intelligence. The built-in checks above still work.")
    }

    private static let reviewInstructions = """
    You review keyboard and mouse macros for a Mac automation app that is mostly used with the \
    Discord desktop app. The user gives you a numbered list of the steps. Reply with at most six \
    short bullet points. Point out steps that are likely to break (clicks at fixed screen \
    positions, typing before a text field is focused, missing waits after opening a menu or \
    switching channels), steps that look unnecessary, and risks such as sending many messages \
    quickly. Only talk about steps that are in the list; do not invent steps. If the macro looks \
    fine, say so in one sentence. Do not ask questions.
    """

    private static let nameInstructions = """
    You name macros. Reply with only a short, plain name of at most five words that describes what \
    the macro does. No quotes, no punctuation at the end.
    """

    private static let editInstructions = """
    You improve keyboard and mouse macros for a Mac automation app that is mostly used with the \
    Discord desktop app. The user gives you numbered steps such as "#4 Press ⌘K". Suggest changes \
    using only these two line formats, one per line, and write nothing else:
    DELETE <step number> | <short reason>
    PAUSE <step number> <seconds> | <short reason>
    DELETE removes a step that is clearly pointless, such as an exact repeat of the step before it \
    or a stray key press. PAUSE makes the app wait before a step, between 0.2 and 3 seconds, when \
    the step needs the app to catch up, for example typing right after opening a menu or switching \
    channels. Use at most eight lines. Only use step numbers that appear in the list. Do not delete \
    steps that send messages or confirm something unless they are exact repeats. If nothing needs \
    changing, reply with the single word NONE.
    """

    /// Asks the model for edits. The reply is parsed by `AIEditParser`, which accepts only a small
    /// set of safe edits; the user still chooses which ones to apply.
    static func proposeEdits(for recording: Recording, profile: String? = nil) async throws -> [MacroEdit] {
        let summary = MacroSummary.numberedText(for: recording)
        let reply = try await respond(
            instructions: editInstructions,
            prompt: "Suggest improvements for this macro.\n\n" + summary + profileBlock(profile)
        )
        return AIEditParser.parse(reply, recording: recording)
    }

    private static let draftInstructions = """
    You turn a plain-English request into keyboard steps for a Mac macro app that is mostly used \
    with the Discord desktop app. Reply only with lines in these formats, one step per line, and \
    write nothing else:
    KEY <shortcut>   (examples: KEY cmd+k, KEY return, KEY shift+return, KEY tab, KEY escape)
    TYPE <text>   (the exact text to type)
    WAIT <seconds>   (0.1 to 10)
    Use keyboard shortcuts instead of mouse clicks. In Discord, cmd+k opens the Quick Switcher: \
    TYPE the channel or person name, then KEY return to open it. Pressing KEY return in a message \
    box sends the message. Use at most 20 lines. Never type passwords or secrets. If the request \
    cannot be done with the keyboard, reply with the single word UNSUPPORTED.
    """

    /// Drafts keyboard steps from a plain-English request. The reply is parsed by `AIMacroDrafter`;
    /// the user reviews the steps before anything is added to a macro.
    static func draftSteps(for request: String, profile: String? = nil) async throws -> MacroDraft {
        let reply = try await respond(instructions: draftInstructions, prompt: "Request: " + request + profileBlock(profile))
        return AIMacroDrafter.parse(reply)
    }

    static func review(_ recording: Recording, profile: String? = nil) async throws -> String {
        let summary = MacroSummary.text(for: recording)
        return try await respond(instructions: reviewInstructions, prompt: "Review this macro.\n\n" + summary + profileBlock(profile))
    }

    private static let tipsInstructions = """
    You give personal suggestions for a Discord macro. You are given the user's own notes about how \
    they use Discord and a numbered list of their macro's steps. Reply with at most four short \
    bullet points that connect the two: for example a favorite channel the macro could open first, a \
    message they send often that it could use, or a pacing or rule note they gave that the macro \
    might break. Use only facts from the user's notes and the steps. Do not invent channels, \
    messages or rules. If nothing in the notes applies, reply with one sentence saying so. Do not \
    ask questions.
    """

    /// Text-only suggestions that tie the macro to the user's Discord profile. Changes nothing.
    static func discordTips(for recording: Recording, profile: String) async throws -> String {
        let summary = MacroSummary.text(for: recording)
        return try await respond(
            instructions: tipsInstructions,
            prompt: "The user's notes:\n" + profile + "\n\nTheir macro:\n" + summary
        )
    }

    private static let explainInstructions = """
    You explain why a Mac macro app stopped a macro on its own. You are given the app's exact \
    message. Reply in at most three short sentences: what the message means in plain words and the \
    simplest way to fix it. Use only what the message says. Do not guess about anything else and do \
    not claim to have seen the screen.
    """

    /// A plain-words explanation of a safety stop. The stop itself never depends on this.
    static func explainStop(_ message: String) async throws -> String {
        return try await respond(instructions: explainInstructions, prompt: "The app's message: " + message)
    }

    private static func profileBlock(_ profile: String?) -> String {
        guard let profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty else { return "" }
        return "\n\nNotes the user gave about how they use Discord (use them only where they help):\n" + profile
    }

    static func suggestName(for recording: Recording) async throws -> String {
        let summary = MacroSummary.text(for: recording)
        let reply = try await respond(instructions: nameInstructions, prompt: "Name this macro.\n\n" + summary)
        let firstLine = reply.split(separator: "\n").first.map(String.init) ?? reply
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”.\t"))
    }

    /// Loads the model ahead of time so the first answer comes faster. Cheap to call more than once.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard availability.isAvailable else { return }
            let session = LanguageModelSession(instructions: reviewInstructions)
            session.prewarm()
            // Kept so the loaded model is not released straight away.
            warmSession = session
        }
        #endif
    }

    private static var warmSession: Any?

    /// Longest time one request may take before it is stopped.
    static let timeLimit = 60

    private static let gate = NSLock()
    private static var running = 0

    /// One request at a time: the on-device model answers one prompt at a time anyway, and a second
    /// request would only wait behind the first.
    private static func enter() throws {
        gate.lock()
        defer { gate.unlock() }
        guard running == 0 else { throw AIAssistantError.busy }
        running += 1
    }

    private static func leave() {
        gate.lock()
        running = max(0, running - 1)
        gate.unlock()
    }

    private static func respond(instructions: String, prompt: String, maxTokens: Int = 600) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard availability.isAvailable else {
                throw AIAssistantError.unavailable(availability.message)
            }
            try enter()
            defer { leave() }
            // Short prompts keep the answer fast and inside the model's context window.
            let trimmed = String(prompt.prefix(6000))
            return try await withTimeLimit(seconds: timeLimit) {
                let session = LanguageModelSession(instructions: instructions)
                // A low temperature keeps the strict line formats the parsers expect.
                let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
                let response = try await session.respond(to: trimmed, options: options)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { throw AIAssistantError.emptyReply }
                return text
            }
        }
        #endif
        throw AIAssistantError.unavailable(availability.message)
    }

    /// Runs `work`, but gives up after `seconds` or when the calling task is cancelled.
    private static func withTimeLimit<T>(seconds: Int, _ work: @escaping () async throws -> T) async throws -> T {
        let holder = ResumerHolder<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let once = OnceResumer(continuation)
                holder.set(once)
                once.task = Task {
                    do {
                        once.resume(.success(try await work()))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                    if once.resume(.failure(AIAssistantError.timedOut(seconds))) {
                        once.task?.cancel()
                    }
                }
            }
        } onCancel: {
            if let once = holder.get() {
                once.task?.cancel()
                once.resume(.failure(CancellationError()))
            }
        }
    }
}
