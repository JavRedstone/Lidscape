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
        var history = ActivityHistory()
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        history.record(date: day, folds: 1, seconds: 3)
        history.record(date: day.addingTimeInterval(5), folds: 1, seconds: 2)
        precondition(history.days.count == 1 && history.days[0].folds == 2 && history.days[0].seconds == 5)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        history.record(date: nextDay, folds: 1, seconds: .nan)
        precondition(history.days.count == 2 && history.days[1].folds == 1 && history.days[1].seconds == 0,
            "Midnight must start fresh daily totals and reject invalid durations")
        history.record(date: Calendar.current.date(byAdding: .day, value: 31, to: day)!)
        precondition(history.days.count == 1, "Daily history must expire after thirty days")
        history.change(from: 90, to: 100, reason: "Adjusted manually", date: day)
        history.change(from: 100, to: 110, reason: "Adjusted manually", date: day.addingTimeInterval(1))
        precondition(history.changes.count == 1 && history.changes[0].previous == 90 && history.changes[0].angle == 110,
            "A slider drag should form one starting-angle change")
        for index in 0..<210 {
            history.change(from: 90, to: 105, reason: "Auto-calibrated", date: day.addingTimeInterval(Double(index + 1) * 5))
        }
        precondition(history.changes.count == 200)
        let decoded = try! JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(history))
        precondition(decoded.days.count == history.days.count && decoded.changes.count == 200)
        var legacyHistory = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as! [String: Any]
        legacyHistory.removeValue(forKey: "stateEvents")
        let migrated = try! JSONDecoder().decode(ActivityHistory.self, from: JSONSerialization.data(withJSONObject: legacyHistory))
        precondition(migrated.changes.count == 200 && migrated.stateEvents.isEmpty,
            "Adding enable/pause history must preserve existing activity")
        let rapidEvents = [0.0, 2, 5, 12, 13, 30].enumerated().map { index, offset in
            EffectStateEvent(date: day.addingTimeInterval(offset), enabled: index.isMultiple(of: 2), source: "Test")
        }
        let clusters = EffectEventCluster.group(rapidEvents.reversed())
        precondition(clusters.map { $0.events.count } == [3, 2, 1], "Rapid changes must share a marker without losing events")
        precondition(clusters.flatMap(\.events).map(\.id) == rapidEvents.map(\.id))
        precondition(clusters[0].date == day && clusters[1].date == day.addingTimeInterval(12), "Grouped markers must remain separated")
        precondition(EffectEventCluster.group([]).isEmpty)
        history.recordState(enabled: true, source: "Manual control", date: day)
        history.recordState(enabled: false, source: "Manual control", date: day.addingTimeInterval(2))
        let stateReload = try! JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(history))
        precondition(stateReload.stateEvents.map(\.enabled) == [true, false], "Enable/pause history must survive relaunch in order")
        let saved = FoldModel(preferences: preferences)
        precondition(saved.appearance == .system, "Existing installs must follow the system appearance")
        saved.appearance = .dark
        precondition(saved.liveDesktopCapture, "Existing preferences must default to live capture")
        precondition(saved.lockScreenContent == .everything)
        saved.lockScreenContent = .selectedApplications
        saved.selectedLockApplications = ["example.chosen-app": "Chosen app", "com.Jackson.DynamicNotch": "DynamicNotch"]
        saved.liveDesktopCapture = false
        saved.enableAtLaunch = false; saved.showDockIcon = false; saved.trigger = 112; saved.geometry.distance = 720; saved.fadeStrength = 1.3
        saved.previewModel = "MacBookAir15"; saved.previewColor = "Midnight"
        saved.holdToReset = false; saved.autoCalibrationDelay = 2.4
        var legacySettings = preferences.dictionary(forKey: "Lidscape.settings.v1")!
        legacySettings["model"] = "MacBookAir15"; legacySettings["color"] = "Midnight"
        preferences.set(legacySettings, forKey: "Lidscape.settings.v1")
        let restored = FoldModel(preferences: preferences)
        precondition(restored.appearance == .dark, "Appearance must survive relaunch")
        precondition(restored.activity.changes.count == saved.activity.changes.count,
            "Restoring the saved angle must not record an extra calibration")
        precondition(!restored.liveDesktopCapture, "The capture mode must survive relaunch")
        precondition(restored.lockScreenContent == .selectedApplications, "The lock-screen content choice must survive relaunch")
        precondition(!restored.showDockIcon && !restored.enableAtLaunch)
        precondition(restored.trigger == 112 && restored.geometry.distance == 720 && restored.fadeStrength == 1.3)
        precondition(restored.previewModel == (MacHardware.previewModel(for: restored.hardwareIdentifier) ?? "Simple"),
            "Preview must always use the detected Mac instead of a saved manual selection")
        precondition(!restored.holdToReset && restored.autoCalibrationDelay == 2.4)
        precondition(restored.selectedLockApplications == saved.selectedLockApplications, "Selected applications must survive relaunch")
        restored.lockScreenEffect = true
        let lockReload = FoldModel(preferences: preferences)
        precondition(lockReload.lockScreenEffect, "Lock-screen folding must survive relaunch")
        restored.lockScreenEffect = false
        restored.resetSettings()
        let resetReload = FoldModel(preferences: preferences)
        precondition(resetReload.appearance == .system)
        precondition(resetReload.liveDesktopCapture, "Reset must restore live capture")
        precondition(resetReload.lockScreenContent == .everything && resetReload.selectedLockApplications.isEmpty)
        precondition(!resetReload.lockScreenEffect, "Reset settings must explicitly turn off lock-screen folding")
        precondition(resetReload.showDockIcon && resetReload.enableAtLaunch && resetReload.autoCalibrate && resetReload.autoCalibrationDelay == 5)
        precondition(resetReload.trigger == 90 && resetReload.fadeStrength == 1 && resetReload.holdToReset)
        let defaults = FoldModel(preferences: preferences)
        defaults.trigger = 130; defaults.blurStrength = 0; defaults.autoCalibrate = true
        defaults.minimumCalibrationAngle = 80; defaults.holdToReset = false
        defaults.resetSettings()
        precondition(defaults.trigger == 90 && defaults.blurStrength == 1)
        precondition(defaults.autoCalibrate && defaults.minimumCalibrationAngle == 30 && defaults.holdToReset)
        let previousWindows = Set(NSApp.windows.map(\.windowNumber))
        defaults.lockScreenEffect = true
        if let prepared = NSApp.windows.first(where: { $0 is FoldOverlayPanel && $0.canBecomeVisibleWithoutLogin && !previousWindows.contains($0.windowNumber) }) {
            precondition(prepared.isVisible && prepared.ignoresMouseEvents && !prepared.canBecomeKey)
            precondition(!(prepared.contentView is MetalFoldView), "The prepared panel must contain no desktop renderer before locking")
            defaults.lockScreenEffect = false
            precondition(!prepared.isVisible, "Disabling the experiment must close its prepared window")
        } else {
            precondition(!NSScreen.screens.contains { screen in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
                return CGDisplayIsBuiltin(id) != 0
            }, "A built-in display must have a prepared lock-screen panel")
            defaults.lockScreenEffect = false
            print("PASS: no lock-screen panel is created without a built-in display")
        }
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
        let model = FoldModel(preferences: preferences)
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
