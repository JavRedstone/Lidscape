import AppKit
import CoreMedia
import ScreenCaptureKit

@main struct LiveCaptureTests {
    static func sample(_ status: SCFrameStatus, width: Int = 8) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer!, formatDescription: format!, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)!
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.status.rawValue as NSString
        let value = NSNumber(value: status.rawValue)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
        return sampleBuffer!
    }

    static func main() {
        for invalid in [Int.min, -1, 0, Int(UInt32.max) + 1, Int.max] {
            precondition(LockScreenCapturePolicy.captureWindowID(invalid) == nil,
                "AppKit sentinel window numbers must not crash capture selection")
        }
        precondition(LockScreenCapturePolicy.captureWindowID(1) == 1)
        precondition(LockScreenCapturePolicy.captureWindowID(Int(UInt32.max)) == UInt32.max)
        let foreground = LockScreenCapturePolicy.foregroundWindowIDs(ordered: [90, 80, 70, 60, 50], loginWindows: [70, 50])
        precondition(foreground == [90, 80], "Only windows above the first login surface are visible on the lock screen")
        precondition(LockScreenCapturePolicy.foregroundWindowIDs(ordered: [70, 80], loginWindows: [70]) == [])
        precondition(LockScreenCapturePolicy.foregroundWindowIDs(ordered: [80, 60], loginWindows: [70]) == nil,
            "Missing login ordering must not expose desktop windows")
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        precondition(LockScreenCapturePolicy.accepts(bundleIdentifier: "com.apple.loginwindow",
            onScreen: true, windowFrame: display, displayFrame: display))
        for provider in LockScreenCapturePolicy.backgroundProviders {
            precondition(LockScreenCapturePolicy.accepts(bundleIdentifier: provider,
                onScreen: true, windowFrame: display, displayFrame: display), "System wallpaper must be included behind the login window")
            precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: provider,
                onScreen: false, windowFrame: display, displayFrame: display))
            precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: provider,
                onScreen: true, windowFrame: display.offsetBy(dx: display.width, dy: 0), displayFrame: display))
        }
        for owner in [nil, "local.macfold.app", "com.apple.finder", "com.apple.wallpaper.extension.unrecognized", "com.apple.Wallpaper-Settings.extension"] {
            precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: owner,
                onScreen: true, windowFrame: display, displayFrame: display), "Desktop content must never be a lock-screen source")
        }
        precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "com.apple.loginwindow",
            onScreen: false, windowFrame: display, displayFrame: display))
        precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "com.apple.loginwindow",
            onScreen: true, windowFrame: CGRect(x: 0, y: 0, width: 300, height: 100), displayFrame: display))
        precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "com.apple.loginwindow",
            onScreen: true, windowFrame: display.offsetBy(dx: 1512, dy: 0), displayFrame: display))
        let overlay = CGRect(x: 500, y: 0, width: 400, height: 160)
        precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "com.Jackson.DynamicNotch",
            onScreen: true, windowFrame: overlay, displayFrame: display))
        precondition(LockScreenCapturePolicy.accepts(bundleIdentifier: "com.Jackson.DynamicNotch",
            onScreen: true, windowFrame: overlay, displayFrame: display,
            content: .selectedApplications, selectedApplications: ["com.Jackson.DynamicNotch"]))
        precondition(LockScreenCapturePolicy.accepts(bundleIdentifier: "example.chosen-app",
            onScreen: true, windowFrame: overlay, displayFrame: display,
            content: .selectedApplications, selectedApplications: ["example.chosen-app"]), "Application selection must work for any chosen bundle")
        precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "example.other-overlay",
            onScreen: true, windowFrame: overlay, displayFrame: display,
            content: .selectedApplications, selectedApplications: ["com.Jackson.DynamicNotch"]))
        precondition(LockScreenCapturePolicy.accepts(bundleIdentifier: "example.other-overlay",
            onScreen: true, windowFrame: overlay, displayFrame: display, content: .everything))
        for mode in LockScreenContent.allCases {
            precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "local.macfold.app",
                onScreen: true, windowFrame: display, displayFrame: display, content: mode, selectedApplications: ["local.macfold.app", "com.Jackson.DynamicNotch"]))
            precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "com.Jackson.DynamicNotch",
                onScreen: false, windowFrame: overlay, displayFrame: display, content: mode, selectedApplications: ["local.macfold.app", "com.Jackson.DynamicNotch"]))
            precondition(!LockScreenCapturePolicy.accepts(bundleIdentifier: "com.Jackson.DynamicNotch",
                onScreen: true, windowFrame: overlay.offsetBy(dx: display.width, dy: 0), displayFrame: display,
                content: mode, selectedApplications: ["local.macfold.app", "com.Jackson.DynamicNotch"]))
        }
        print("PASS: capture scopes honor arbitrary selected apps, visibility, display bounds and self-exclusion")
        print("PASS: lock-screen source rejects desktop apps, hidden/small windows and other displays")
        let capture = DesktopCapture()
        precondition(capture.latest().image == nil)
        capture.receive(sample(.idle))
        precondition(capture.latest().image == nil, "Idle cannot make a first frame available")
        capture.receive(sample(.complete))
        let first = capture.latest().image!
        capture.receive(sample(.idle))
        precondition(capture.latest().image === first, "An unchanged live desktop must remain visible")
        capture.receive(sample(.complete, width: 16))
        precondition(capture.latest().image !== first && capture.latest().image!.extent.width == 16,
            "New content must replace the previous frame rather than freezing the fold snapshot")
        for status in [SCFrameStatus.suspended, .blank, .stopped] {
            capture.receive(sample(status))
            precondition(capture.latest().image == nil, "Unavailable capture must discard the previous image")
            capture.receive(sample(.idle))
            precondition(capture.latest().image == nil, "Idle must not resurrect a stale frame")
            capture.receive(sample(.complete))
            precondition(capture.latest().image != nil, "Fresh content must resume without an angle gate")
        }
        capture.stop()
        precondition(capture.latest().image == nil)
        capture.receive(sample(.complete))
        precondition(capture.latest().image == nil, "Late callbacks from a stopped stream must be ignored")
        let still = DesktopCapture()
        still.freeze()
        still.receive(sample(.complete))
        let snapshot = still.latest().image!
        still.freeze()
        still.receive(sample(.complete, width: 16))
        still.receive(sample(.blank))
        precondition(still.latest().image === snapshot, "Still-image mode must retain its first frame without accepting later callbacks")
        still.stop()
        precondition(still.latest().image == nil, "Dismissing a still-image fold must release its snapshot")
        print("PASS: still-image mode freezes a valid frame and releases it on stop")
        print("PASS: live frame replacement, static desktop, suspended/blank/stopped invalidation, fresh-frame resume, late callback rejection")
    }
}
