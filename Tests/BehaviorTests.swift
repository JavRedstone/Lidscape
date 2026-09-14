import AppKit
import SceneKit

@main struct BehaviorTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        precondition(MacHardware.previewModel(for: "Mac17,2") == "MacBookPro14")
        precondition(MacHardware.previewModel(for: "Mac16,13") == "MacBookAir15")
        precondition(MacHardware.previewModel(for: "Unknown") == nil)
        let suite = "Lidscape.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = FoldModel(preferences: preferences)
        saved.enableAtLaunch = false; saved.showDockIcon = false; saved.trigger = 112; saved.geometry.distance = 720; saved.fadeStrength = 1.3
        saved.previewModel = "MacBookAir15"; saved.previewColor = "Midnight"
        saved.holdToReset = false; saved.autoCalibrationDelay = 2.4
        let restored = FoldModel(preferences: preferences)
        precondition(!restored.showDockIcon && !restored.enableAtLaunch)
        precondition(restored.trigger == 112 && restored.geometry.distance == 720 && restored.fadeStrength == 1.3)
        precondition(restored.previewModel == "MacBookAir15" && restored.previewColor == "Midnight")
        precondition(!restored.holdToReset && restored.autoCalibrationDelay == 2.4)
        restored.resetSettings()
        let resetReload = FoldModel(preferences: preferences)
        precondition(resetReload.showDockIcon && resetReload.enableAtLaunch && resetReload.autoCalibrate && resetReload.autoCalibrationDelay == 5)
        precondition(resetReload.trigger == 90 && resetReload.fadeStrength == 0.5 && resetReload.holdToReset)
        let defaults = FoldModel(preferences: preferences)
        defaults.trigger = 130; defaults.blurStrength = 0; defaults.autoCalibrate = true
        defaults.minimumCalibrationAngle = 80; defaults.holdToReset = false
        defaults.resetSettings()
        precondition(defaults.trigger == 90 && defaults.blurStrength == 1)
        precondition(defaults.autoCalibrate && defaults.minimumCalibrationAngle == 30 && defaults.holdToReset)
        let geometry = ViewingGeometry()
        let edge = geometry.edgeOnDegrees * .pi / 180
        // At edge-on the screen normal is perpendicular to the eye vector.
        precondition(abs(-sin(edge) * geometry.distance + cos(edge) * geometry.eyeHeight) < 1e-9)
        precondition(abs(geometry.eyeRelativeDegrees(lidDegrees: geometry.edgeOnDegrees)) < 1e-9)
        for angle in [90.0, 104.0, 120.0] {
            var calibrated = ViewingGeometry()
            calibrated.calibrate(lidDegrees: angle)
            let a = angle * Double.pi / 180
            let dy = calibrated.eyeHeight - calibrated.height * 0.5 * sin(a)
            let dz = calibrated.distance - calibrated.height * 0.5 * cos(a)
            precondition(abs(dy * sin(a) + dz * cos(a)) < 1e-8)
        }
        var hold = HoldResetState()
        for tick in 0...29 {
            let result = hold.update(angle: 60 + (tick % 2 == 0 ? 0.3 : -0.3), now: Double(tick) / 30, delay: 1)
            precondition(result == 0)
        }
        var settled = 0.0
        for tick in 30...45 { settled = hold.update(angle: 60, now: Double(tick) / 30, delay: 1) }
        precondition(settled == 1)
        for tick in 46...75 { precondition(hold.update(angle: 60, now: Double(tick) / 30, delay: 1) == 1) }
        let firstReturn = hold.update(angle: 55, now: 76.0 / 30, delay: 1)
        precondition(firstReturn > 0 && firstReturn < 1, "Reactivation must interpolate, not snap")
        var resumed = firstReturn
        for tick in 77...91 { resumed = hold.update(angle: 55, now: Double(tick) / 30, delay: 1) }
        precondition(resumed == 0)
        let model = FoldModel()
        model.eyeRelativePreview = true
        model.preview = 1
        precondition(abs(model.previewReadout) < 1e-9)
        precondition(abs(model.previewLidAngle - model.geometry.edgeOnDegrees) < 1e-9)
        model.eyeRelativePreview = false
        precondition(model.previewLidAngle == 0)
        model.previewReset = 1
        model.preview = 0.5
        precondition(model.previewReset == 1, "Slider rearm must preserve the current image for a smooth transition")
        model.editPreview(true)
        precondition(model.previewEditing && model.previewReset == 1)
        model.editPreview(false)
        let view = MacBookPreview(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        view.update(progress: 0.35, source: model.artwork, reference: 90, geometry: model.geometry, sideView: false)
        let original = view.pointOfView!.worldTransform
        view.update(progress: 0.35, source: model.artwork, reference: 90, geometry: model.geometry, sideView: true)
        view.pointOfView!.eulerAngles = SCNVector3(0.5, 0.5, 0.5)
        view.update(progress: 0.35, source: model.artwork, reference: 90, geometry: model.geometry, sideView: false)
        precondition(SCNMatrix4EqualToMatrix4(original, view.pointOfView!.worldTransform))
        for (name, reset) in [("blurred", 0.0), ("reset", 1.0)] {
            view.update(progress: 0.35, source: model.artwork, reference: 90, geometry: model.geometry, sideView: false, resetAmount: reset)
            let image = view.snapshot()
            try! NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
        }
        print("PASS: hold delay, jitter, settled latch, movement rearm, camera restoration; rendered blur and reset")
    }
}
