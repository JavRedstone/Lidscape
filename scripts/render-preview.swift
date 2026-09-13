import AppKit
import SceneKit

// Render a deterministic demonstration with the production projection and hold state.
@main struct PreviewRecording {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = CommandLine.arguments[1]
        let suite = "Lidscape.recording." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let model = FoldModel(preferences: prefs)
        let view = MacBookPreview(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        view.fadeStrength = 0.5
        var hold = HoldResetState()
        for frame in 0..<300 {
            let time = Double(frame) / 25
            let progress: Double
            let moving: Bool
            let caption: String
            switch time {
            case ..<1: progress = 0; moving = false; caption = "Ready"
            case ..<3: progress = (time - 1) / 2 * 0.45; moving = true; caption = "Folding · perspective, blur & fade"
            case ..<5: progress = 0.45; moving = false; caption = time < 4 ? "Holding still…" : "Hold reset · normal view"
            case ..<7: progress = 0.45 + (time - 5) / 2 * 0.55; moving = true; caption = "Moving again · effect returns"
            case ..<8: progress = 1; moving = false; caption = "Fully closed"
            case ..<11: progress = 1 - (time - 8) / 3; moving = true; caption = "Opening"
            default: progress = 0; moving = false; caption = "Ready"
            }
            let reset = hold.update(angle: 90 * (1 - progress), now: time, delay: 1, moving: moving)
            view.update(progress: progress, source: model.artwork, reference: 90, geometry: model.geometry,
                        sideView: false, resetAmount: reset, blurStrength: 1, model: "MacBookPro14")
            let picture = NSImage(size: NSSize(width: 640, height: 460))
            picture.lockFocus()
            NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 640, height: 460).fill()
            view.snapshot().draw(in: NSRect(x: 0, y: 40, width: 640, height: 420))
            let text = NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            text.draw(at: NSPoint(x: (640 - text.size().width) / 2, y: 14))
            picture.unlockFocus()
            let png = NSBitmapImageRep(data: picture.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(String(format: "%04d.png", frame)))
        }
    }
}
