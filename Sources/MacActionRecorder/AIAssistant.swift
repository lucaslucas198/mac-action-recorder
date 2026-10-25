import Foundation
import MacActionRecorderCore

#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

enum AIAssistantError: LocalizedError {
    case unavailable(String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyReply: return "The model returned an empty answer. Try again."
        }
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
    static func proposeEdits(for recording: Recording) async throws -> [MacroEdit] {
        let summary = MacroSummary.numberedText(for: recording)
        let reply = try await respond(instructions: editInstructions, prompt: "Suggest improvements for this macro.\n\n" + summary)
        return AIEditParser.parse(reply, recording: recording)
    }

    static func review(_ recording: Recording) async throws -> String {
        let summary = MacroSummary.text(for: recording)
        return try await respond(instructions: reviewInstructions, prompt: "Review this macro.\n\n" + summary)
    }

    static func suggestName(for recording: Recording) async throws -> String {
        let summary = MacroSummary.text(for: recording)
        let reply = try await respond(instructions: nameInstructions, prompt: "Name this macro.\n\n" + summary)
        let firstLine = reply.split(separator: "\n").first.map(String.init) ?? reply
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”.\t"))
    }

    private static func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard availability.isAvailable else {
                throw AIAssistantError.unavailable(availability.message)
            }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw AIAssistantError.emptyReply }
            return text
        }
        #endif
        throw AIAssistantError.unavailable(availability.message)
    }
}
