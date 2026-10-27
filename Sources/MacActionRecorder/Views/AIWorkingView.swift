import SwiftUI

/// "Thinking… 4 s" with a Stop button, shown while the on-device AI works.
struct AIWorkingView: View {
    @ObservedObject private var activity = AIActivity.shared

    var body: some View {
        if activity.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking… \(max(0, Int(context.date.timeIntervalSince(activity.startedAt)))) s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Stop") { activity.cancel() }
                        .controlSize(.small)
                        .help("Stop waiting for the on-device AI")
                }
            }
        }
    }
}
