import Foundation

/// Human-readable one-line descriptions for the action list.
public enum ActionDescriber {
    public static func describe(_ action: MacroAction) -> String {
        switch action.kind {
        case .move:
            return "Move mouse to \(point(action))"

        case .drag:
            return "Drag (\(buttonName(action))) to \(point(action))"

        case .mouseDown:
            return "Press \(buttonName(action).lowercased()) button at \(point(action))"

        case .mouseUp:
            return "Release \(buttonName(action).lowercased()) button at \(point(action))"

        case .click:
            let count = action.clickCount ?? 1
            let prefix: String
            switch count {
            case 2: prefix = "Double-click"
            case 3: prefix = "Triple-click"
            default: prefix = "Click"
            }
            return "\(buttonName(action)) \(prefix.lowercased()) at \(point(action))"

        case .scroll:
            let dx = action.scrollX ?? 0
            let dy = action.scrollY ?? 0
            return "Scroll (horizontal \(dx), vertical \(dy))"

        case .key:
            let code = action.keyCode ?? -1
            let shown = KeyNames.display(keyCode: code, modifiers: action.modifiers ?? [])
            return "Press \(shown)"

        case .text:
            return "Type “\(preview(action.text ?? ""))”"

        case .wait:
            return "Wait \(formatSeconds(action.duration ?? 0))"
        }
    }

    public static func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 10 {
            return String(format: "%.1f s", seconds)
        }
        return String(format: "%.2f s", seconds)
    }

    private static func point(_ action: MacroAction) -> String {
        let x = Int((action.x ?? 0).rounded())
        let y = Int((action.y ?? 0).rounded())
        return "(\(x), \(y))"
    }

    private static func buttonName(_ action: MacroAction) -> String {
        return (action.button ?? .left).displayName
    }

    private static func preview(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: "⏎")
        if singleLine.count > 40 {
            return String(singleLine.prefix(40)) + "…"
        }
        return singleLine
    }
}
