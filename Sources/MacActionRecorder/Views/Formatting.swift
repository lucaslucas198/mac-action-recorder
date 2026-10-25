import Foundation

enum Fmt {
    /// "12.3 s" under a minute, "2:05" above.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 {
            return String(format: "%.1f s", seconds)
        }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func actionCount(_ count: Int) -> String {
        return count == 1 ? "1 action" : "\(count) actions"
    }
}
