import AppKit
import MacActionRecorderCore

/// Briefly draws numbered markers on screen where a macro will click, so it is easy to see
/// whether a window or layout has moved since recording. The markers ignore the mouse, never
/// block anything underneath, and disappear by themselves.
final class ClickPreview {
    static let shared = ClickPreview()

    private var windows: [NSWindow] = []
    private var hideTimer: Timer?

    /// Click positions in macro order, in the global top-left-origin coordinate space.
    static func clickPoints(in recording: Recording) -> [CGPoint] {
        var points: [CGPoint] = []
        for action in recording.actions where action.kind == .click || action.kind == .mouseDown {
            if let x = action.x, let y = action.y {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    /// Returns false when the macro has no clicks to show.
    @discardableResult
    func show(for recording: Recording, seconds: TimeInterval = 6) -> Bool {
        hide()
        let points = ClickPreview.clickPoints(in: recording)
        guard !points.isEmpty, let primary = NSScreen.screens.first else { return false }
        let primaryHeight = primary.frame.height

        for screen in NSScreen.screens {
            let frame = screen.frame
            // Convert from global top-left coordinates to this screen's own bottom-left coordinates.
            var local: [(number: Int, point: CGPoint)] = []
            for (index, point) in points.enumerated() {
                let appKitPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
                if frame.contains(appKitPoint) {
                    local.append((index + 1, CGPoint(x: appKitPoint.x - frame.minX, y: appKitPoint.y - frame.minY)))
                }
            }
            if local.isEmpty { continue }

            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.contentView = ClickPreviewView(frame: CGRect(origin: .zero, size: frame.size), markers: local)
            window.orderFrontRegardless()
            windows.append(window)
        }

        guard !windows.isEmpty else { return false }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
        return true
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

private final class ClickPreviewView: NSView {
    private let markers: [(number: Int, point: CGPoint)]

    init(frame: CGRect, markers: [(number: Int, point: CGPoint)]) {
        self.markers = markers
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 14
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.white
        ]
        for marker in markers {
            let circle = NSBezierPath(ovalIn: CGRect(
                x: marker.point.x - radius,
                y: marker.point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            NSColor.systemRed.withAlphaComponent(0.85).setFill()
            circle.fill()
            NSColor.white.setStroke()
            circle.lineWidth = 2
            circle.stroke()

            let label = NSAttributedString(string: String(marker.number), attributes: attributes)
            let size = label.size()
            label.draw(at: CGPoint(
                x: marker.point.x - size.width / 2,
                y: marker.point.y - size.height / 2
            ))
        }
    }
}
