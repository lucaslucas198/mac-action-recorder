import Foundation

/// The stages of "Set Up This Mac", used to drive the progress bar in the Welcome screen.
/// The bar moves from stage to stage as each one really starts; it is not a timer.
public enum SetupStage: Int, CaseIterable, Equatable {
    case copying
    case signing
    case installing

    public static var count: Int { return allCases.count }

    /// Where the bar sits while this stage is running (0...1). Strictly increasing, never full:
    /// the bar is full only when the app has reopened.
    public var fraction: Double {
        switch self {
        case .copying: return 0.15
        case .signing: return 0.45
        case .installing: return 0.85
        }
    }

    /// "Step 1 of 3".
    public var stepText: String {
        return "Step \(rawValue + 1) of \(SetupStage.count)"
    }

    public var title: String {
        switch self {
        case .copying: return "Copying the app…"
        case .signing: return "Signing it for this Mac…"
        case .installing: return "Installing and reopening…"
        }
    }

    /// A hint for the one stage where macOS may ask the user something.
    public var hint: String? {
        switch self {
        case .signing:
            return "If macOS asks whether \"codesign\" may use a key, choose Always Allow."
        default:
            return nil
        }
    }
}
