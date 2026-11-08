import AppKit
import ServiceManagement
import SwiftUI
import Charts
import SceneKit
import MetalKit
import IOKit.hid
import ScreenCaptureKit
import CoreMedia
import CoreImage.CIFilterBuiltins
import Darwin
import UniformTypeIdentifiers

// HID feature report documented by samhenrigold/LidAngleSensor.
final class LidSensor {
    private var device: IOHIDDevice?
    init() {
        let matching = IOServiceMatching("IOHIDDevice")!
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service)
            IOObjectRelease(service)
            guard let candidate else { continue }
            let vendor = IOHIDDeviceGetProperty(candidate, kIOHIDVendorIDKey as CFString) as? Int
            let usage = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsageKey as CFString) as? Int
            let page = IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            if vendor == 0x05ac && page == 0x20 && usage == 0x8a,
               IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess {
                device = candidate
                break
            }
        }
    }
    deinit { if let device { IOHIDDeviceClose(device, 0) } }
    func read() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              length >= 3 else { return nil }
        let angle = Double(UInt16(report[1]) | UInt16(report[2]) << 8)
        return (0...180).contains(angle) ? angle : nil
    }
}

// Dimensions and eye position are in millimetres, relative to the bottom hinge.
struct ViewingGeometry {
    var width = 302.0
    var height = 196.0
    var distance = 550.0
    var eyeHeight = 300.0
    var edgeOnDegrees: Double { atan2(eyeHeight, distance) * 180 / .pi }
    func eyeRelativeDegrees(lidDegrees: Double) -> Double { lidDegrees - edgeOnDegrees }
    mutating func calibrate(lidDegrees: Double) {
        let angle = lidDegrees * .pi / 180
        let centerY = height * 0.5 * sin(angle)
        let centerZ = height * 0.5 * cos(angle)
        eyeHeight = centerY + (distance - centerZ) * tan(angle - .pi / 2)
    }
}

// A median rejects isolated HID spikes; temporal filtering removes small
// quantization steps. Brief missing reports do not tear down the overlay.
struct LidAngleFilter {
    private var samples: [Double] = []
    private var filtered: Double?
    private var lastValid = 0.0
    mutating func update(_ raw: Double?, now: Double) -> Double? {
        guard let raw, raw.isFinite, (0...180).contains(raw) else {
            if now - lastValid <= 0.15 { return filtered }
            samples.removeAll(); filtered = nil
            return nil
        }
        let dt = min(0.1, max(0, now - lastValid)); lastValid = now
        samples.append(raw)
        if samples.count > 3 { samples.removeFirst() }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        if let previous = filtered {
            filtered = previous + (median - previous) * -expm1(-dt / 0.035)
        } else { filtered = median }
        return filtered
    }
}

// HID feature reports can block. Sample independently of drawing, and expose
// only the newest filtered reading rather than queuing UI work for every report.
final class LidSampler {
    private let queue = DispatchQueue(label: "Lidscape.lid-sensor", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var sensor: LidSensor?
    private var filter = LidAngleFilter()
    private var value: Double?
    private var timestamp = 0.0
    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.sensor == nil { self.sensor = LidSensor() }
            let raw = self.sensor?.read()
            let now = ProcessInfo.processInfo.systemUptime
            let reading = self.filter.update(raw, now: now)
            self.lock.lock(); self.value = reading; self.timestamp = now; self.lock.unlock()
        }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel() }
    func latest(now: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return now - timestamp <= 0.15 ? value : nil
    }
    func restart() {
        lock.lock(); value = nil; timestamp = 0; lock.unlock()
        queue.async { [weak self] in self?.sensor = nil; self?.filter = LidAngleFilter() }
    }
}

// Overlapping sleep/session notifications must not resume one another.
struct FoldResumeGate {
    enum Reason: Hashable { case systemSleep, displaySleep, inactiveSession }
    private var reasons: Set<Reason> = []
    var suspended: Bool { !reasons.isEmpty }
    mutating func suspend(_ reason: Reason) {
        reasons.insert(reason)
    }
    mutating func resume(_ reason: Reason) {
        reasons.remove(reason)
    }
}

enum LockScreenContent: String, CaseIterable {
    case everything, selectedApplications, systemOnly
    var overlaySpaceLevel: Int32 {
        switch self {
        case .systemOnly: return 400
        // WindowServer rejects Int32.max for overlay Spaces on current macOS.
        // 500 is accepted and sits above lock-screen app overlays (400/401).
        case .selectedApplications, .everything: return 500
        }
    }
    var title: String {
        switch self {
        case .systemOnly: return "System content only"
        case .selectedApplications: return "Selected applications"
        case .everything: return "Everything visible"
        }
    }
    var explanation: String {
        switch self {
        case .systemOnly: return "Folds the login-window interface and Apple wallpaper."
        case .selectedApplications: return "Folds system content plus visible windows and overlays from the apps you select. Lidscape is always excluded."
        case .everything: return "Folds all visible content on the built-in display, including other apps’ overlays. Lidscape’s own windows are excluded."
        }
    }
}

struct LockScreenCapturePolicy {
    static func captureWindowID(_ windowNumber: Int) -> CGWindowID? {
        guard windowNumber > 0 else { return nil }
        return CGWindowID(exactly: windowNumber)
    }
    // WindowServer orders these IDs front-to-back across overlay Spaces. Only
    // app windows above the login surface are visible lock-screen content.
    static func foregroundWindowIDs(ordered: [CGWindowID], loginWindows: Set<CGWindowID>) -> Set<CGWindowID>? {
        guard let boundary = ordered.firstIndex(where: { loginWindows.contains($0) }) else { return nil }
        return Set(ordered[..<boundary])
    }
    // System wallpaper providers have their own windows, separate from loginwindow.
    static let backgroundProviders: Set<String> = [
        "com.apple.wallpaper.agent",
        "com.apple.wallpaper.extension.aerials", "com.apple.wallpaper.extension.dynamic",
        "com.apple.wallpaper.extension.image", "com.apple.wallpaper.extension.legacy",
        "com.apple.wallpaper.extension.monterey", "com.apple.wallpaper.extension.ventura",
        "com.apple.wallpaper.extension.sonoma", "com.apple.wallpaper.extension.sequoia",
        "com.apple.wallpaper.extension.macintosh", "com.apple.wallpaper.extension.gradient"
    ]
    static func isBackgroundProvider(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map { backgroundProviders.contains($0) } ?? false
    }
    static func accepts(bundleIdentifier: String?, onScreen: Bool, windowFrame: CGRect, displayFrame: CGRect,
                        content: LockScreenContent = .systemOnly, selectedApplications: Set<String> = []) -> Bool {
        // Never include our own renderer, including in the broadest mode.
        guard bundleIdentifier != "local.macfold.app", onScreen,
              displayFrame.width > 0, displayFrame.height > 0 else { return false }
        let overlap = windowFrame.intersection(displayFrame)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return false }
        if content == .everything { return true }
        if content == .selectedApplications, let bundleIdentifier, selectedApplications.contains(bundleIdentifier) {
            return true
        }
        guard bundleIdentifier == "com.apple.loginwindow" || isBackgroundProvider(bundleIdentifier) else { return false }
        return overlap.width >= displayFrame.width * 0.8
            && overlap.height >= displayFrame.height * 0.8
    }
}

// Private WindowServer placement, used only while lock-screen folding is enabled.
// A normal window level does not place a window in the lock-screen compositor.
@MainActor final class LockScreenOverlaySpace {
    static let shared = LockScreenOverlaySpace()
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias GetLevel = @convention(c) (Int32, UInt64) -> Int32
    private typealias Show = @convention(c) (Int32, CFArray) -> Void
    private typealias Place = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private var library: UnsafeMutableRawPointer?
    private var connection: Int32 = 0
    private var space: UInt64 = 0
    private var place: Place?
    private var show: Show?
    private var copySpaces: CopySpaces?
    private var setLevel: SetLevel?
    private var getLevel: GetLevel?
    var actualLevel: Int32? { getLevel.map { $0(connection, space) } }
    private(set) var diagnostic = "Overlay Space not initialized."

    func attach(_ window: NSWindow, content: LockScreenContent = .systemOnly) -> Bool {
        guard window.windowNumber > 0 else { diagnostic = "The overlay window has no WindowServer ID yet."; return false }
        if space == 0 && !initialize() { return false }
        guard let place, let show, let copySpaces, let setLevel else { return false }
        setLevel(connection, space, content.overlaySpaceLevel)
        show(connection, [space] as CFArray)
        place(connection, space, [window.windowNumber] as CFArray, 7)
        // These setters return void. Verify actual membership instead of
        // interpreting an undefined return register as an error code.
        // Include OS-controlled Spaces (bit 3), not just user desktops.
        let memberships = copySpaces(connection, 15, [window.windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber]
        let attached = memberships?.contains { $0.uint64Value == space } == true
        let reported = memberships?.map { String($0.uint64Value) }.joined(separator: ", ") ?? "unavailable"
        let level = actualLevel.map(String.init) ?? "unknown"
        diagnostic = attached ? "Dedicated overlay Space attached; window membership verified; Space level \(level) (requested \(content.overlaySpaceLevel))." : "Overlay Space \(space) requested for window \(window.windowNumber); reported Spaces: \(reported)."
        return attached
    }
    private func initialize() -> Bool {
        // Keep one Space and its function pointers for this process's lifetime.
        // WindowServer releases the Space when the app connection exits.
        if library == nil {
            library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL)
        }
        guard let library,
              let connectionSymbol = dlsym(library, "SLSMainConnectionID"),
              let createSymbol = dlsym(library, "SLSSpaceCreate"),
              let levelSymbol = dlsym(library, "SLSSpaceSetAbsoluteLevel"),
              let showSymbol = dlsym(library, "SLSShowSpaces"),
              let placeSymbol = dlsym(library, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
              let copySymbol = dlsym(library, "SLSCopySpacesForWindows") ?? dlsym(library, "CGSCopySpacesForWindows") else {
            diagnostic = "The SkyLight overlay Space APIs are unavailable on this macOS version."
            return false
        }
        connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let created = unsafeBitCast(createSymbol, to: Create.self)(connection, 1, nil)
        guard created != 0 else { diagnostic = "WindowServer could not create an overlay Space."; return false }
        unsafeBitCast(levelSymbol, to: SetLevel.self)(connection, created, 400)
        setLevel = unsafeBitCast(levelSymbol, to: SetLevel.self)
        if let symbol = dlsym(library, "SLSSpaceGetAbsoluteLevel") ?? dlsym(library, "CGSSpaceGetAbsoluteLevel") {
            getLevel = unsafeBitCast(symbol, to: GetLevel.self)
        }
        show = unsafeBitCast(showSymbol, to: Show.self)
        place = unsafeBitCast(placeSymbol, to: Place.self)
        copySpaces = unsafeBitCast(copySymbol, to: CopySpaces.self)
        space = created
        return true
    }
}

// Keep only the newest IOSurface-backed image. The display link pulls it;
// capture callbacks never queue one main-thread task per frame.
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "Lidscape.desktop-capture", qos: .userInteractive)
    private let lock = NSLock()
    private var image: CIImage?
    private var acceptingFrames = true
    private var failure: Error?
    private var stream: SCStream?

    @MainActor func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        // A lid/session change can stop us while startCapture is suspended.
        if isStopped { try? await stream.stopCapture() }
    }
    @MainActor func updateFilter(_ filter: SCContentFilter) async throws {
        guard !isStopped, let stream else { return }
        try await stream.updateContentFilter(filter)
    }
    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return !acceptingFrames
    }
    func stop() {
        lock.lock(); acceptingFrames = false; image = nil; lock.unlock()
        stopStream()
    }
    func freeze() {
        lock.lock()
        guard acceptingFrames, image != nil else { lock.unlock(); return }
        acceptingFrames = false
        lock.unlock()
        stopStream()
    }
    private func stopStream() {
        let previous = stream; stream = nil
        previous?.stopCapture { _ in
            try? previous?.removeStreamOutput(self, type: .screen)
        }
    }
    func latest() -> (image: CIImage?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (image, failure)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        receive(sampleBuffer)
    }
    func receive(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        lock.lock(); defer { lock.unlock() }
        guard acceptingFrames else { return }
        switch status {
        case .complete:
            guard let buffer = sampleBuffer.imageBuffer else { return }
            image = CIImage(cvPixelBuffer: buffer)
        case .idle:
            break // Unchanged content is still a valid live frame.
        default:
            image = nil // Blank, suspended, or stopped: never display an old frame.
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard acceptingFrames else { return }
        image = nil; failure = error; acceptingFrames = false
    }
}

struct FoldThreshold {
    private(set) var active = false
    private var previousThreshold: Double?
    mutating func update(angle: Double?, threshold: Double) -> Bool {
        if previousThreshold != threshold { active = false; previousThreshold = threshold }
        guard let angle else { active = false; return false }
        // Different entry and exit angles stop boundary chatter.
        if active { if angle >= threshold + 1.5 { active = false } }
        else if angle <= threshold - 1.5 { active = true }
        return active
    }
}

struct ResetAngleGate {
    private var eligible: Bool?
    private var previousMinimum: Double?
    mutating func update(angle: Double, minimum: Double) -> Bool {
        if previousMinimum != minimum { eligible = nil; previousMinimum = minimum }
        if eligible == nil { eligible = angle >= minimum }
        if angle < minimum { eligible = false }
        else if angle >= minimum + 1.5 { eligible = true }
        return eligible!
    }
}

// Angle deadband rejects sensor jitter. A settled image stays normal until
// real movement rearms the effect; it must not repeatedly capture while held.
struct HoldResetState {
    private var anchor: Double?
    private var heldSince = 0.0
    private var lastTime: Double?
    private(set) var amount = 0.0
    private(set) var resuming = false
    private var wasEnabled: Bool?
    mutating func rearm() { anchor = nil }
    mutating func update(angle: Double, now: Double, delay: Double, moving: Bool = false, enabled: Bool = true, canRenderReturn: Bool = true, waitingForFrame: Bool = false) -> Double {
        let dt = min(0.1, max(0, now - (lastTime ?? now)))
        lastTime = now
        if wasEnabled != enabled { anchor = nil; wasEnabled = enabled }
        if waitingForFrame || anchor == nil || abs(angle - anchor!) > 1.5 {
            anchor = angle; heldSince = now
        }
        let target = enabled && !moving && !waitingForFrame && now - heldSince >= delay ? 1.0 : 0.0
        resuming = target == 0
        // Desktop capture is asynchronous. Keep the normal view until the new
        // overlay can actually display the return animation.
        if resuming && !canRenderReturn { return amount }
        amount += (target - amount) * (1 - exp(-dt / (target == 0 ? 0.085 : 0.055)))
        if abs(amount - target) < 0.003 { amount = target }
        return amount
    }
}

final class FoldCanvas: NSView {
    var resetAmount = 0.0 { didSet { needsDisplay = true } }
    var blurStrength = 1.0 { didSet { needsDisplay = true } }
    var geometry = ViewingGeometry() { didSet { needsDisplay = true } }
    var referenceDegrees = 90.0 { didSet { needsDisplay = true } }
    var progress = 0.0 { didSet { needsDisplay = true } }
    var source: CIImage? { didSet { needsDisplay = true } }
    private let context = CIContext(options: [.cacheIntermediates: false])
    // Inverse mapping avoids singular forward quads as the lid crosses the
    // horizon. Cast from the eye through each physical pixel to the fixed plane.
    static let projection = CIKernel(source: """
    kernel vec4 projectUpright(sampler picture, float width, float height,
                              float distance, float eyeHeight,
                              float angle, float reference, float pixelWidth, float pixelHeight) {
        vec2 uv = destCoord() / vec2(pixelWidth, pixelHeight);
        vec3 eye = vec3(0.0, eyeHeight, distance);
        vec3 panel = vec3((uv.x - 0.5) * width,
                          uv.y * height * sin(angle), uv.y * height * cos(angle));
        vec3 ray = panel - eye;
        vec3 normal = vec3(0.0, cos(reference), -sin(reference));
        float denominator = dot(normal, ray);
        if (abs(denominator) < 0.0001) return vec4(0.0);
        float t = -dot(normal, eye) / denominator;
        if (t <= 0.0) return vec4(0.0);
        vec3 point = eye + t * ray;
        vec2 sourceUV = vec2(point.x / width + 0.5,
                            (point.y * sin(reference) + point.z * cos(reference)) / height);
        if (sourceUV.x < 0.0 || sourceUV.x > 1.0 || sourceUV.y < 0.0 || sourceUV.y > 1.0)
            return vec4(0.0);
        return sample(picture, samplerTransform(picture, sourceUV * vec2(pixelWidth, pixelHeight)));
    }
    """)!
    static let progressiveBlur = CIKernel(source: """
    kernel vec4 frost(sampler sharp, sampler soft1, sampler soft2, sampler soft3, sampler soft4, float height) {
        vec2 p = destCoord();
        float level = pow(smoothstep(0.04, 1.0, p.y / height), 1.6) * 4.0;
        vec4 a = sample(sharp, samplerTransform(sharp, p));
        vec4 b = sample(soft1, samplerTransform(soft1, p));
        vec4 c = sample(soft2, samplerTransform(soft2, p));
        vec4 d = sample(soft3, samplerTransform(soft3, p));
        vec4 e = sample(soft4, samplerTransform(soft4, p));
        if (level < 1.0) return mix(a, b, level);
        if (level < 2.0) return mix(b, c, level - 1.0);
        if (level < 3.0) return mix(c, d, level - 2.0);
        return mix(d, e, level - 3.0);
    }
    """)!
    static func frost(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0.0001 else { return image }
        let extent = image.extent
        let radius = amount * extent.height * 0.075
        let levels = [0.125, 0.25, 0.5, 1.0].map { fraction in
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * fraction]).cropped(to: extent)
        }
        return progressiveBlur.apply(extent: extent, roiCallback: { _, _ in extent },
            arguments: [image] + levels + [extent.height]) ?? image
    }
    static let darken = CIColorKernel(source: """
        kernel vec4 darken(__sample pixel, float height, float amount) {
            float elevation = smoothstep(0.0, 1.0, destCoord().y / height);
            float shade = clamp(amount * (0.25 + 0.75 * elevation), 0.0, 1.0);
            return vec4(pixel.rgb * (1.0 - shade), pixel.a);
        }
        """)!
    static func frame(source: CIImage, progress: Double, referenceDegrees: Double,
                      resetAmount: Double, blurStrength: Double, geometry: ViewingGeometry, fadeStrength: Double = 0) -> CIImage? {
        let p = min(1, max(0, progress))
        let extent = source.extent
        let baseReference = referenceDegrees * .pi / 180
        let angle = (referenceDegrees + (0 - referenceDegrees) * p) * .pi / 180
        let reset = min(1, max(0, resetAmount))
        let reference = baseReference + (angle - baseReference) * reset
        let frosting = pow(p, 0.8) * (1 - reset) * blurStrength
        guard let warped = projection.apply(extent: extent, roiCallback: { _, _ in extent }, arguments: [
            source, geometry.width, geometry.height, geometry.distance, geometry.eyeHeight,
            angle, reference, extent.width, extent.height
        ]) else { return nil }
        // Blur is anchored to physical panel height AFTER projection. The
        // hinge remains crisp; progressively wider kernels frost the top edge.
        let opaque = warped.composited(over: CIImage(color: .black).cropped(to: extent))
        let frosted = frost(opaque, amount: frosting)
        let fade = pow(p, 0.8) * (1 - reset) * fadeStrength
        guard fade > 0 else { return frosted }
        return darken.apply(extent: extent, arguments: [frosted, extent.height, fade])
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let source, let image = Self.frame(source: source, progress: progress, referenceDegrees: referenceDegrees,
            resetAmount: resetAmount, blurStrength: blurStrength, geometry: geometry),
            let cg = context.createCGImage(image, from: image.extent) else { return }
        NSImage(cgImage: cg, size: bounds.size).draw(in: bounds)
    }

}

// Production rendering stays on the GPU; no CGImage or bitmap readback per frame.
final class FoldGPU {
    var fadeStrength = 0.0
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    private(set) var texture: MTLTexture?
    private var texturePool: [MTLTexture] = []
    private var textureIndex = 0
    private var cachedSource: CIImage?
    private var resizedSource: CIImage?
    private var sourceWidth = 0
    private(set) var lastGPUSeconds = 0.0
    init(device: MTLDevice = MTLCreateSystemDefaultDevice()!, queue: MTLCommandQueue? = nil) {
        self.device = device; self.queue = queue ?? device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }
    func releaseResources() {
        context.clearCaches()
        cachedSource = nil; resizedSource = nil
        texture = nil; texturePool.removeAll()
    }
    func image(source: CIImage, width: Int, progress: Double, reference: Double,
               reset: Double, blur: Double, geometry: ViewingGeometry) -> CIImage? {
        if cachedSource !== source || sourceWidth != width {
            cachedSource = source; sourceWidth = width
            resizedSource = source.transformed(by: CGAffineTransform(scaleX: Double(width) / source.extent.width,
                                                                       y: Double(width) / source.extent.width))
        }
        return FoldCanvas.frame(source: resizedSource!, progress: progress, referenceDegrees: reference,
                                resetAmount: reset, blurStrength: blur, geometry: geometry, fadeStrength: fadeStrength)
    }
    func render(source: CIImage, width: Int, progress: Double, reference: Double,
                reset: Double, blur: Double, geometry: ViewingGeometry) -> MTLTexture? {
        guard let image = image(source: source, width: width, progress: progress, reference: reference,
                                reset: reset, blur: blur, geometry: geometry) else { return nil }
        let height = Int(image.extent.height.rounded(.up))
        if texturePool.first?.width != width || texturePool.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            texturePool = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            textureIndex = 0
        }
        guard texturePool.count == 3 else { return nil }
        // Keep the currently displayed texture intact while producing the next.
        textureIndex = (textureIndex + 1) % texturePool.count
        texture = texturePool[textureIndex]
        guard let texture, let buffer = queue.makeCommandBuffer() else { return nil }
        context.render(image, to: texture, commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        buffer.commit()
        // Complete the producer before SceneKit consumes the shared texture.
        // No pixels cross to the CPU. Benchmarks include this synchronization.
        buffer.waitUntilCompleted()
        lastGPUSeconds = max(0, buffer.gpuEndTime - buffer.gpuStartTime)
        return texture
    }
}

final class FoldOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect // The lock-screen overlay must cover the menu-bar/notch region too.
    }
}

final class MetalFoldView: MTKView, MTKViewDelegate {
    private(set) var hasRenderedFrame = false
    private var firstFramePending = false
    var fadeStrength = 0.0 { didSet { gpu.fadeStrength = fadeStrength } }
    var source: CIImage?
    var progress = 0.0
    var resetAmount = 0.0
    var blurStrength = 1.0
    var referenceDegrees = 90.0
    var geometry = ViewingGeometry()
    private let gpu = FoldGPU()
    func stopRendering() {
        isPaused = true; delegate = nil; source = nil
        gpu.releaseResources()
    }
    override init(frame: NSRect, device: MTLDevice? = nil) {
        super.init(frame: frame, device: gpu.device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isPaused = true; enableSetNeedsDisplay = false
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("Unsupported") }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let source, let drawable = currentDrawable,
              let image = gpu.image(source: source, width: min(1920, Int(drawableSize.width)), progress: progress,
                  reference: referenceDegrees, reset: resetAmount, blur: blurStrength, geometry: geometry),
              let buffer = gpu.queue.makeCommandBuffer() else { return }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: drawableSize.width / image.extent.width,
                                                             y: drawableSize.height / image.extent.height))
        gpu.context.render(scaled, to: drawable.texture, commandBuffer: buffer,
            bounds: CGRect(origin: .zero, size: drawableSize), colorSpace: CGColorSpaceCreateDeviceRGB())
        if !hasRenderedFrame && !firstFramePending {
            firstFramePending = true
            buffer.addCompletedHandler { [weak self] completed in
                let succeeded = completed.status == .completed
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.delegate != nil else { return }
                    self.hasRenderedFrame = succeeded
                    self.firstFramePending = false
                }
            }
        }
        buffer.present(drawable); buffer.commit()
    }
}

struct SettledCalibration {
    private var anchor: Double?
    private var since = 0.0
    private var fired = false
    mutating func update(angle: Double?, now: Double, delay: Double = 1) -> Double? {
        guard let angle, (60...150).contains(angle) else { anchor = nil; fired = false; return nil }
        if anchor == nil || abs(angle - anchor!) > 1.5 {
            anchor = angle; since = now; fired = false
        }
        guard !fired, now - since >= delay else { return nil }
        fired = true
        return angle
    }
}

struct PreviewPlayback {
    var value: Double
    var closing = true
    var pauseRemaining = 0.0
    mutating func advance(dt: Double, holdDelay: Double) -> (value: Double, moving: Bool) {
        if pauseRemaining > 0 {
            pauseRemaining = max(0, pauseRemaining - dt)
            return (value, false)
        }
        let end = closing ? 1.0 : 0.0
        value += (closing ? 1 : -1) * max(0, dt) * 0.22
        if (closing && value >= end) || (!closing && value <= end) {
            value = end; closing.toggle(); pauseRemaining = holdDelay + 0.8
            return (value, false)
        }
        return (value, true)
    }
}

struct SmoothValue {
    var value = 0.0
    mutating func advance(to target: Double, dt: Double, response: Double) -> Double {
        value += (target - value) * -expm1(-max(0, dt) / max(0.001, response))
        if abs(value - target) < 0.00005 { value = target }
        return value
    }
}

final class FrameTickTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick(_ link: CADisplayLink) { autoreleasepool { action() } }
}

final class MacBookPreview: SCNView {
    private var animationLink: CADisplayLink?
    private var animationFrame: ((Double) -> Void)?
    private var animationTime = ProcessInfo.processInfo.systemUptime
    private var animatedProgress = SmoothValue()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animationLink?.invalidate(); animationLink = nil
        guard let display = window?.screen else { return }
        animationTime = ProcessInfo.processInfo.systemUptime
        let target = FrameTickTarget { [weak self] in self?.animatePreview() }
        let link = display.displayLink(target: target, selector: #selector(FrameTickTarget.tick))
        let rate = Float(display.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        animationLink = link
    }
    private func animatePreview() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, now - animationTime); animationTime = now
        animationFrame?(dt)
    }
    deinit { animationLink?.invalidate() }
    private let lid = SCNNode()
    private let screen = SCNNode()
    private let cameraNode = SCNNode()
    private let inspectionCamera = SCNNode()
    private var zoomTarget = SCNVector3Zero
    override func scrollWheel(with event: NSEvent) {
        guard allowsCameraControl, let camera = pointOfView else { return }
        defaultCameraController.stopInertia()
        let offset = SCNVector3(camera.position.x - zoomTarget.x, camera.position.y - zoomTarget.y, camera.position.z - zoomTarget.z)
        let distance = sqrt(offset.x * offset.x + offset.y * offset.y + offset.z * offset.z)
        guard distance > 0 else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
        let newDistance = min(3000, max(100, distance * exp(-delta * 0.006)))
        camera.position = SCNVector3(zoomTarget.x + offset.x * newDistance / distance,
                                    zoomTarget.y + offset.y * newDistance / distance,
                                    zoomTarget.z + offset.z * newDistance / distance)
        needsDisplay = true
    }
    private let hardware = SCNNode()
    private lazy var gpu = FoldGPU(device: device ?? MTLCreateSystemDefaultDevice()!)
    private var dimensions = CGSize.zero
    private var lastInputs: [Double] = []
    private var lastCameraInputs: [Double] = []
    private var lastSource: CIImage?
    private var selectedModel = "Simple"
    private(set) var importedModelName: String?

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        scene = SCNScene()
        backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
        antialiasingMode = .multisampling2X
        preferredFramesPerSecond = 120
        autoenablesDefaultLighting = true
        scene!.rootNode.addChildNode(hardware)
        cameraNode.camera = SCNCamera()
        cameraNode.camera!.zNear = 1
        cameraNode.camera!.zFar = 4000
        cameraNode.camera!.fieldOfView = 40
        scene!.rootNode.addChildNode(cameraNode)
        inspectionCamera.camera = cameraNode.camera!.copy() as? SCNCamera
        scene!.rootNode.addChildNode(inspectionCamera)
        pointOfView = cameraNode
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func box(_ width: Double, _ height: Double, _ depth: Double,
                     at position: SCNVector3, color: NSColor, radius: Double = 1) -> SCNNode {
        let shape = SCNBox(width: width, height: height, length: depth, chamferRadius: radius)
        shape.firstMaterial!.diffuse.contents = color
        shape.firstMaterial!.roughness.contents = 0.65
        let node = SCNNode(geometry: shape)
        node.position = position
        return node
    }
    private func loadAppleModel(_ geometry: ViewingGeometry) -> Bool {
        guard selectedModel != "Simple" else { return false }
        let url = Bundle.main.url(forResource: selectedModel, withExtension: "usdz", subdirectory: "Models")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Models/" + selectedModel + ".usdz")
        guard let asset = try? SCNScene(url: url) else { return false }
        let rigs: [String: (String, String, Bool)] = [
            "MacBookPro14": ("RcexTyyhpuJYATQ", "tfTbkkzhxqpKRgC", true),
            "MacBookAir13": ("PuFNZqOrQmeQtle", "lidqkpaVJriYQHN", false),
            "MacBookAir13-sky-blue": ("PuFNZqOrQmeQtle", "lidqkpaVJriYQHN", false),
            "MacBookAir15-sky-blue": ("NQBByylvJetTJWU", "mRFtNxQIMDMOFhZ", false),
            "MacBookAir13-silver": ("RUgpIPPvIpoKyKB", "NSKTMOGjgWSbJNs", true),
            "MacBookAir13-midnight": ("PmaGyMSfOSmJyEs", "yfwVklggWEvWVte", true),
            "MacBookAir13-starlight": ("mcZXJptrvdvujfm", "ronPuhdyDfXCPyw", true),
            "MacBookAir15-silver": ("mlBJTkeLRJEGJYh", "OQzaQDtbMVhhlAr", true),
            "MacBookAir15-midnight": ("GfPOzdygRdhBvfP", "IcBMnlsGrUWaSql", true),
            "MacBookAir15-starlight": ("ZqpKmNJOzrYhovX", "VvklDMOkMTwkrEm", true)
        ]
        guard let rig = rigs[selectedModel],
              let assembly = asset.rootNode.childNode(withName: rig.0, recursively: true),
              let display = asset.rootNode.childNode(withName: rig.1, recursively: true) else { return false }
        // Replace the authored display artwork with black so rounded corners
        // reveal the display surround, never the asset's original wallpaper.
        display.geometry = display.geometry?.copy() as? SCNGeometry
        let displayBacking = SCNMaterial()
        displayBacking.lightingModel = .constant
        displayBacking.diffuse.contents = NSColor.black
        display.geometry?.materials = [displayBacking]
        let baked = rig.2
        let bounds = display.boundingBox
        let bottom = display.convertPosition(baked ? SCNVector3(0, bounds.min.y, bounds.max.z) : SCNVector3(0, bounds.min.y, bounds.min.z), to: nil)
        let top = display.convertPosition(baked ? SCNVector3(0, bounds.max.y, bounds.min.z) : SCNVector3(0, bounds.min.y, bounds.max.z), to: nil)
        let dy = Double(top.y - bottom.y), dz = Double(top.z - bottom.z)
        let scale = geometry.width / Double(bounds.max.x - bounds.min.x)
        let lidClone = assembly.clone()
        lidClone.transform = assembly.worldTransform
        assembly.removeFromParentNode()
        asset.rootNode.childNode(withName: "STqWlxoLEgIXuhO", recursively: true)?.removeFromParentNode()
        if selectedModel == "MacBookAir15-sky-blue" {
            asset.rootNode.childNode(withName: "GymPGKieMgDZPqK", recursively: true)?.removeFromParentNode()
        }
        var hingeWorld = baked ? SCNVector3(0, 0.65, bottom.z + 0.39) : lidClone.convertPosition(SCNVector3Zero, to: nil)
        if !baked { hingeWorld.y += 0.7 }
        do {
        // Solve the hinge from the real mesh in its closed pose. This avoids
        // model-specific guessed offsets and preserves the authored open pose.
        func vertices(_ root: SCNNode) -> [SCNVector3] {
            var result: [SCNVector3] = []
            func read(_ node: SCNNode) {
                guard let source = node.geometry?.sources(for: .vertex).first,
                      source.usesFloatComponents, source.bytesPerComponent == 4 else { return }
                source.data.withUnsafeBytes { bytes in
                    for i in 0..<source.vectorCount {
                        let offset = source.dataOffset + i * source.dataStride
                        let x = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        let y = bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                        let z = bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                        result.append(node.convertPosition(SCNVector3(x, y, z), to: nil))
                    }
                }
            }
            read(root); root.enumerateChildNodes { node, _ in read(node) }
            return result
        }
        let baseVertices = vertices(asset.rootNode)
        let lidVertices = vertices(lidClone)
        guard !baseVertices.isEmpty, !lidVertices.isEmpty else { return false }
        let closingRotation = Double.pi / 2 - atan2(dz, dy)
        let c = cos(closingRotation), sn = sin(closingRotation), a = 1 - c
        let closedZ = lidVertices.map { Double($0.y) * sn + Double($0.z) * c }
        let baseZ = baseVertices.map { Double($0.z) }
        // Seat the active display surface above the keyboard, not the
        // lowest hinge protrusion (which leaves the shell floating).
        let closedDisplayY = Double(bottom.y) * c - Double(bottom.z) * sn
        let shiftY = baseVertices.map { Double($0.y) }.max()! + 0.02 - closedDisplayY
        let shiftZ = (baseZ.min()! + baseZ.max()! - closedZ.min()! - closedZ.max()!) / 2
        hingeWorld = SCNVector3(0, (a * shiftY - sn * shiftZ) / (2 * a),
                                     (sn * shiftY + a * shiftZ) / (2 * a))
        }
        let baseScale = SCNNode()
        baseScale.scale = SCNVector3(scale, scale, scale)
        let base = asset.rootNode.clone()
        base.position = SCNVector3(-bottom.x, -bottom.y, -bottom.z)
        baseScale.addChildNode(base); hardware.addChildNode(baseScale)
        let lidScale = SCNNode()
        lidScale.scale = SCNVector3(scale, geometry.height / hypot(dy, dz), scale)
        let upright = SCNNode()
        upright.eulerAngles.x = CGFloat(-atan2(dz, dy))
        let shift = SCNNode()
        shift.position = SCNVector3(-bottom.x, -bottom.y, -bottom.z)
        shift.addChildNode(lidClone); upright.addChildNode(shift); lidScale.addChildNode(upright)
        lid.addChildNode(lidScale); hardware.addChildNode(lid)
        let offsetY = Double(hingeWorld.y - bottom.y), offsetZ = Double(hingeWorld.z - bottom.z)
        let rotation = -atan2(dz, dy)
        let hinge = SCNVector3(0, (offsetY * cos(rotation) - offsetZ * sin(rotation)) * geometry.height / hypot(dy, dz),
                              (offsetY * sin(rotation) + offsetZ * cos(rotation)) * scale)
        lid.pivot = SCNMatrix4MakeTranslation(hinge.x, hinge.y, hinge.z)
        // The pivot is expressed in the normalized upright lid coordinates,
        // but its position must remain in the base's unrotated coordinates.
        // Using the rotated pivot for both displaces the hinge when closing.
        lid.position = SCNVector3(0, offsetY * scale, offsetZ * scale)
        importedModelName = selectedModel
        return true
    }
    private func rebuild(_ geometry: ViewingGeometry) {
        hardware.childNodes.forEach { $0.removeFromParentNode() }
        lid.childNodes.forEach { $0.removeFromParentNode() }
        lid.pivot = SCNMatrix4Identity; lid.position = SCNVector3Zero
        let w = geometry.width, h = geometry.height
        importedModelName = nil
        let imported = loadAppleModel(geometry)
        if !imported {
        let silver = NSColor(calibratedWhite: 0.48, alpha: 1)
        hardware.addChildNode(box(w + 14, 9, h + 12, at: SCNVector3(0, -9, h / 2), color: silver, radius: 4))
        // Keyboard and trackpad lie on the base, in front of the hinge.
        for row in 0..<6 { for col in 0..<14 {
            hardware.addChildNode(box((w - 30) / 14 - 2, 1, 11,
                at: SCNVector3(-w / 2 + 15 + (Double(col) + 0.5) * (w - 30) / 14, -3.8, 20 + Double(row) * 14),
                color: NSColor(calibratedWhite: 0.075, alpha: 1)))
        } }
        hardware.addChildNode(box(w * 0.40, 0.6, h * 0.30,
            at: SCNVector3(0, -4.0, h * 0.77), color: NSColor(calibratedWhite: 0.39, alpha: 1), radius: 2))
        hardware.addChildNode(lid)
        lid.addChildNode(box(w + 14, h + 10, 4,
            at: SCNVector3(0, h / 2, -2.5), color: silver, radius: 3))
        lid.addChildNode(box(w + 7, h + 4, 0.5,
            at: SCNVector3(0, h / 2, -0.25), color: .black, radius: 2))
        }
        // Keep a small physical inset from the aperture to avoid drawing over
        // the bezel at grazing angles. Rounded geometry clips every effect.
        let inset = 0.6
        let panel = SCNPlane(width: w - 2 * inset, height: h - 2 * inset)
        panel.cornerRadius = 3.5
        panel.cornerSegmentCount = 12
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        panel.materials = [material]
        screen.geometry = panel
        screen.position = SCNVector3(0, h / 2, 0.03)
        lid.addChildNode(screen)
        dimensions = CGSize(width: w, height: h)
    }
    func update(progress: Double, source: CIImage, reference: Double,
                geometry: ViewingGeometry, sideView: Bool, resetAmount: Double = 0, blurStrength: Double = 1, model: String = "Simple") {
        animationFrame = { [weak self] dt in
            guard let self else { return }
            let value = self.animatedProgress.advance(to: progress, dt: dt, response: self.smoothingResponse)
            self.renderFrame(progress: value, source: source, reference: reference, geometry: geometry, sideView: sideView, resetAmount: resetAmount, blurStrength: blurStrength, model: model)
        }
        if window == nil { renderFrame(progress: progress, source: source, reference: reference, geometry: geometry, sideView: sideView, resetAmount: resetAmount, blurStrength: blurStrength, model: model) }
    }
    var fadeStrength = 0.0
    var smoothingResponse = 0.055
    private func renderFrame(progress: Double, source: CIImage, reference: Double, geometry: ViewingGeometry, sideView: Bool, resetAmount: Double, blurStrength: Double, model: String) {
        let modelChanged = selectedModel != model
        selectedModel = model
        let cameraInputs = [geometry.width, geometry.height, geometry.distance, geometry.eyeHeight, sideView ? 1.0 : 0.0]
        let inputs = cameraInputs + [progress, reference, resetAmount, blurStrength, fadeStrength]
        guard modelChanged || inputs != lastInputs || lastSource !== source else { return }
        // Commit the lid pose and matching texture together. SceneKit must not
        // implicitly animate geometry independently of our display-link smoothing.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        lastInputs = inputs; lastSource = source
        if modelChanged || dimensions != CGSize(width: geometry.width, height: geometry.height) { rebuild(geometry) }
        let angle = reference + (0 - reference) * progress
        // Local +Y runs up the lid; closing swings it toward the viewer (+Z).
        lid.eulerAngles.x = CGFloat((90 - angle) * .pi / 180)
        gpu.fadeStrength = fadeStrength
        if let texture = gpu.render(source: source, width: 1024, progress: progress, reference: reference,
                                    reset: resetAmount, blur: blurStrength, geometry: geometry) {
            screen.geometry!.firstMaterial!.diffuse.contents = texture
            var flip = SCNMatrix4Identity; flip.m22 = -1; flip.m42 = 1
            screen.geometry!.firstMaterial!.diffuse.contentsTransform = flip
        }
        if cameraInputs != lastCameraInputs {
            lastCameraInputs = cameraInputs
            defaultCameraController.stopInertia()
            allowsCameraControl = sideView
            let activeCamera = sideView ? inspectionCamera : cameraNode
            activeCamera.transform = SCNMatrix4Identity
            activeCamera.position = sideView
                ? SCNVector3(geometry.width * 1.5, geometry.height * 1.6, geometry.height * 2.3)
                : SCNVector3(0, geometry.eyeHeight, geometry.distance)
            zoomTarget = SCNVector3(0, geometry.height * 0.40, geometry.height * 0.18)
            activeCamera.look(at: zoomTarget,
                                 up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            activeCamera.camera!.fieldOfView = 40
            pointOfView = activeCamera
            defaultCameraController.pointOfView = activeCamera
        }
        needsDisplay = true
    }
}

struct MacBookBridge: NSViewRepresentable {
    let progress: Double
    let source: CIImage
    let referenceDegrees: Double
    let geometry: ViewingGeometry
    let sideView: Bool
    let resetAmount: Double
    let blurStrength: Double
    let model: String
    var fadeStrength: Double = 0.5
    var smoothing: Double = 0.055
    func makeNSView(context: Context) -> MacBookPreview { MacBookPreview(frame: .zero) }
    func updateNSView(_ view: MacBookPreview, context: Context) {
        view.fadeStrength = fadeStrength
        view.smoothingResponse = smoothing
        view.update(progress: progress, source: source, reference: referenceDegrees, geometry: geometry, sideView: sideView, resetAmount: resetAmount, blurStrength: blurStrength, model: model)
    }
}

struct MacHardware {
    static var identifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return "Unknown Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Unknown Mac" }
        return String(cString: bytes)
    }
    static func previewModel(for id: String) -> String? {
        if ["Mac17,2", "Mac17,7", "Mac17,9", "Mac16,1", "Mac16,6", "Mac16,8", "Mac15,3", "Mac15,6", "Mac15,8", "Mac15,10", "Mac14,5", "Mac14,9", "MacBookPro18,3", "MacBookPro18,4"].contains(id) { return "MacBookPro14" }
        if ["Mac17,3", "Mac16,12", "Mac15,12", "Mac14,2"].contains(id) { return "MacBookAir13" }
        if ["Mac17,4", "Mac16,13", "Mac15,13", "Mac14,15"].contains(id) { return "MacBookAir15" }
        return nil
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

struct AngleSample: Identifiable {
    let id = UUID()
    let date: Date
    let angle: Double
    let reference: Double
}
struct ReferenceChange: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let previous: Double
    let angle: Double
    let reason: String
}
struct EffectStateEvent: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let enabled: Bool
    let source: String
}
struct EffectEventCluster: Identifiable {
    var events: [EffectStateEvent]
    var id: UUID { events[0].id }
    var date: Date { events[0].date }
    var enabled: Bool { events.last!.enabled }
    static func group(_ events: [EffectStateEvent], separation: TimeInterval = 12) -> [Self] {
        var clusters: [Self] = []
        for event in events.sorted(by: { $0.date < $1.date }) {
            if let last = clusters.last, event.date.timeIntervalSince(last.date) < separation {
                clusters[clusters.count - 1].events.append(event)
            } else {
                clusters.append(Self(events: [event]))
            }
        }
        return clusters
    }
}
struct ActivityTimelineEntry: Identifiable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String
    let symbol: String
    let color: Color
}
struct DailyActivity: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    var folds = 0
    var seconds = 0.0
}
struct ActivityHistory: Codable {
    var days: [DailyActivity] = []
    var changes: [ReferenceChange] = []
    var stateEvents: [EffectStateEvent] = []
    private enum CodingKeys: String, CodingKey { case days, changes, stateEvents }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        days = try values.decodeIfPresent([DailyActivity].self, forKey: .days) ?? []
        changes = try values.decodeIfPresent([ReferenceChange].self, forKey: .changes) ?? []
        stateEvents = Array((try values.decodeIfPresent([EffectStateEvent].self, forKey: .stateEvents) ?? []).suffix(200))
    }
    mutating func recordState(enabled: Bool, source: String, date: Date = Date()) {
        stateEvents.append(EffectStateEvent(date: date, enabled: enabled, source: source))
        stateEvents = Array(stateEvents.suffix(200))
    }
    mutating func record(date: Date, folds: Int = 0, seconds: Double = 0) {
        let day = Calendar.current.startOfDay(for: date)
        if !days.contains(where: { $0.date == day }) { days.append(DailyActivity(date: day)) }
        if let index = days.firstIndex(where: { $0.date == day }) {
            days[index].folds += max(0, folds)
            days[index].seconds += seconds.isFinite ? max(0, seconds) : 0
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -29, to: day)!
        days = Array(days.filter { $0.date >= cutoff && $0.date <= day }.sorted { $0.date < $1.date }.suffix(30))
    }
    mutating func change(from previous: Double, to angle: Double, reason: String, date: Date = Date()) {
        guard previous.isFinite, angle.isFinite, abs(previous - angle) >= 0.5 else { return }
        if let last = changes.last, reason == "Adjusted manually", last.reason == reason,
           (0...2).contains(date.timeIntervalSince(last.date)) {
            changes[changes.count - 1] = ReferenceChange(id: last.id, date: date, previous: last.previous, angle: angle, reason: reason)
        } else {
            changes.append(ReferenceChange(date: date, previous: previous, angle: angle, reason: reason))
        }
        changes = Array(changes.suffix(200))
    }
}
struct LockCaptureSnapshot {
    let date: Date
    let wallpaperWindows: Int
    let appWindows: Int
    let rendered: Bool
    let visible: Bool
    let level: Int32?
    let requestedLevel: Int32
}

enum PreviewArtwork {
    static func image(size: NSSize = NSSize(width: 1600, height: 1000)) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            func color(_ hex: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                        green: CGFloat((hex >> 8) & 255) / 255,
                        blue: CGFloat(hex & 255) / 255, alpha: 1)
            }
            NSGradient(colors: [color(0x061421), color(0x16394A)])!.draw(in: rect, angle: 25)
            // Broad folded planes, drawn as vectors so the preview has no
            // generated scenery or external image dependency.
            let transform = NSAffineTransform()
            transform.scaleX(by: rect.width / 1600, yBy: rect.height / 1000)
            transform.concat()
            let planes: [(CGFloat, UInt32, UInt32)] = [
                (360, 0x123D6A, 0x285F93),
                (180, 0x166EB1, 0x6ACDF0),
                (0, 0x6CD7E8, 0xE7FAF7),
                (-180, 0x096C88, 0x51C7D4),
                (-360, 0x09283F, 0x21638A)
            ]
            for (offset, low, high) in planes {
                let plane = NSBezierPath()
                plane.move(to: NSPoint(x: -400, y: -200 + offset))
                plane.curve(to: NSPoint(x: 1800, y: 940 + offset),
                            controlPoint1: NSPoint(x: 600, y: -240 + offset),
                            controlPoint2: NSPoint(x: 620, y: 1080 + offset))
                plane.line(to: NSPoint(x: 1800, y: 1150 + offset))
                plane.curve(to: NSPoint(x: -400, y: 10 + offset),
                            controlPoint1: NSPoint(x: 620, y: 1290 + offset),
                            controlPoint2: NSPoint(x: 600, y: -30 + offset))
                plane.close()
                NSGradient(colors: [color(low), color(high)])!.draw(in: plane, angle: 70)
            }
            return true
        }
    }
}

@MainActor final class FoldModel: NSObject, ObservableObject {
    private let preferences: UserDefaults
    private var settingsReady = false
    @Published var appearance = AppAppearance.system {
        didSet { saveSettings(); if settingsReady { applyAppearance() } }
    }
    private func applyAppearance() {
        guard Bundle.main.bundleIdentifier == "local.macfold.app" else { return }
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    @Published private(set) var activity = ActivityHistory()
    @Published private(set) var angleSamples: [AngleSample] = []
    @Published private(set) var lastLockCapture: LockCaptureSnapshot?
    @Published private(set) var lockCaptureProblem: String?
    private var nextActivitySample = 0.0
    private var nextActivitySave = 0.0
    private var lastActivityTick = 0.0
    private var pendingFoldSeconds = 0.0
    private var activityWasFolding = false
    private var referenceChangeReason = "Adjusted manually"
    private var nextDiagnosticSnapshot = 0.0
    var todayActivity: DailyActivity {
        activity.days.first { Calendar.current.isDateInToday($0.date) } ?? DailyActivity(date: Calendar.current.startOfDay(for: Date()))
    }
    var overlayPlacementReady: Bool { lockScreenEffect && lockSpaceReady && preparedLockPanel != nil }
    var overlaySpaceLevel: Int32? { LockScreenOverlaySpace.shared.actualLevel }
    var lockReadinessTitle: String {
        if !lockScreenEffect { return "Lock-screen fold is off" }
        if lockCaptureProblem != nil { return "Last capture needs attention" }
        if !lockSpaceReady { return "Overlay is not ready" }
        return screenLocked ? "Ready on the lock screen" : "Ready for your next lock"
    }
    var lockReadinessDetail: String {
        if !lockScreenEffect { return "Enable it above to fold the lock screen with your lid." }
        if let lockCaptureProblem { return lockCaptureProblem }
        if !lockSpaceReady { return "The fold could not prepare its lock-screen overlay. Expand technical details for the reported reason." }
        return "Lock your Mac and move the lid below your starting angle. The fold appears while the lid is moving."
    }
    func copyLockDiagnostics() {
        let snapshot = lastLockCapture.map { "Last fold: \($0.date)\nWallpaper windows: \($0.wallpaperWindows)\nApp windows: \($0.appWindows)\nRendered: \($0.rendered)\nVisible: \($0.visible)" } ?? "No fold captured this launch."
        let text = "Lidscape \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")\n\(lockReadinessTitle)\n\(lockReadinessDetail)\n\(snapshot)\n\(lockScreenStatus)"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func clearActivity() {
        activity = ActivityHistory(); angleSamples = []; pendingFoldSeconds = 0
        persistActivity()
    }
    private func persistActivity() {
        if let data = try? JSONEncoder().encode(activity) { preferences.set(data, forKey: "Lidscape.activity.v1") }
    }
    private func recordActivity(now: Double) {
        let folding = enabled && !suspended && canvas?.hasRenderedFrame == true && (overlay?.alphaValue ?? 0) > 0.5
        let elapsed = now - lastActivityTick; lastActivityTick = now
        if folding && activityWasFolding && elapsed >= 0 && elapsed < 0.25 { pendingFoldSeconds += elapsed }
        if folding && !activityWasFolding { activity.record(date: Date(), folds: 1) }
        activityWasFolding = folding
        guard now >= nextActivitySample else { return }
        nextActivitySample = now + 1
        let date = Date()
        if activity.days.last?.date != Calendar.current.startOfDay(for: date) { activity.record(date: date) }
        if pendingFoldSeconds > 0 { activity.record(date: date, seconds: pendingFoldSeconds); pendingFoldSeconds = 0 }
        if let angle { angleSamples.append(AngleSample(date: date, angle: angle, reference: trigger)) }
        angleSamples = Array(angleSamples.filter { $0.date >= date.addingTimeInterval(-300) }.suffix(301))
        if now >= nextActivitySave { nextActivitySave = now + 10; persistActivity() }
    }
    @Published var enableAtLaunch = true { didSet { saveSettings() } }
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var menuStatus = "Paused"
    var menuStatusColor: Color {
        switch menuStatus {
        case "Ready", "Folding", "Returning to normal": return .green
        case "Paused": return .secondary
        default: return .orange
        }
    }
    private func refreshMenuStatus() {
        let next: String
        if checkingCapture { next = "Checking access" }
        else if needsScreenPermission { next = "Permission needed" }
        else if !enabled { next = "Paused" }
        else if angle == nil { next = "No lid sensor" }
        else if overlay != nil { next = lidHold.amount > 0.01 ? "Returning to normal" : "Folding" }
        else { next = "Ready" }
        if menuStatus != next { menuStatus = next }
    }
    func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
            if loginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { status = "Could not update launch at login: \(error.localizedDescription)"; refreshLoginStatus() }
    }
    private func startApplication() {
        guard Bundle.main.bundleIdentifier == "local.macfold.app" else { return }
        refreshLoginStatus()
        applyAppearance()
        if !preferences.bool(forKey: "Lidscape.setupComplete") {
            let alert = NSAlert()
            alert.messageText = "Welcome to Lidscape"
            alert.informativeText = "Lidscape uses Screen Recording to animate your desktop as the lid moves. macOS will ask for access if needed. Auto-calibration is on by default. Would you also like Lidscape to launch when you log in?"
            alert.addButton(withTitle: "Enable launch at login")
            alert.addButton(withTitle: "Not now")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            preferences.set(true, forKey: "Lidscape.setupComplete")
            if response == .alertFirstButtonReturn { setLaunchAtLogin(true) }
        }
        refreshScreenLockState()
        if lockScreenEffect { prepareLockPanel(); updateLockTickTimer() }
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreenLockState() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        lockStateWatchdog = watchdog
        if enableAtLaunch { setEnabled(true, source: "At app launch") }
    }
    @Published var showDockIcon = true {
        didSet {
            saveSettings()
            if settingsReady { applyDockPreference() }
        }
    }
    private func applyDockPreference() {
        guard Bundle.main.bundleIdentifier == "local.macfold.app" else { return }
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
    @Published var fadeStrength = 1.0 { didSet { saveSettings() } }
    private func saveSettings() {
        guard settingsReady else { return }
        preferences.set([
            "appearance": appearance.rawValue, "enableAtLaunch": enableAtLaunch, "showDockIcon": showDockIcon,
            "liveCapture": liveDesktopCapture,
            "lockScreenContent": lockScreenContent.rawValue,
            "lockScreenApplications": selectedLockApplications,
            "lockScreenEffect": lockScreenEffect,
            "distance": geometry.distance, "eyeHeight": geometry.eyeHeight,
            "trigger": trigger, "smoothing": smoothing, "blur": blurStrength, "fade": fadeStrength,
            "hold": holdToReset, "holdDelay": holdDelay,
            "auto": autoCalibrate, "autoDelay": autoCalibrationDelay,
            "minimum": minimumCalibrationAngle, "eyeRelative": eyeRelativePreview
        ], forKey: "Lidscape.settings.v1")
    }
    private func restoreSettings() {
        guard let values = preferences.dictionary(forKey: "Lidscape.settings.v1") else { return }
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let value = values[key] as? Double, value.isFinite else { return fallback }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        appearance = (values["appearance"] as? String).flatMap(AppAppearance.init(rawValue:)) ?? .system
        geometry.distance = number("distance", 550, 300...1000)
        geometry.eyeHeight = number("eyeHeight", 300, -600...3000)
        trigger = number("trigger", 90, 35...150)
        smoothing = number("smoothing", 0.055, 0.025...0.14)
        blurStrength = number("blur", 1, 0...2); fadeStrength = number("fade", 1, 0...2)
        holdToReset = values["hold"] as? Bool ?? true
        holdDelay = number("holdDelay", 1, 0.5...3)
        autoCalibrate = values["auto"] as? Bool ?? true
        autoCalibrationDelay = number("autoDelay", 5, 0.5...8)
        if !preferences.bool(forKey: "Lidscape.calibrationDelayV2") && autoCalibrationDelay == 1 {
            autoCalibrationDelay = 5
        }
        minimumCalibrationAngle = number("minimum", 30, 0...120)
        eyeRelativePreview = values["eyeRelative"] as? Bool ?? false
        showDockIcon = values["showDockIcon"] as? Bool ?? true
        enableAtLaunch = values["enableAtLaunch"] as? Bool ?? true
        liveDesktopCapture = values["liveCapture"] as? Bool ?? true
        selectedLockApplications = values["lockScreenApplications"] as? [String: String] ?? [:]
        let storedContent = values["lockScreenContent"] as? String
        if storedContent == "dynamicNotch" {
            selectedLockApplications["com.Jackson.DynamicNotch"] = "DynamicNotch"
            lockScreenContent = .selectedApplications
        } else {
            lockScreenContent = storedContent.flatMap(LockScreenContent.init(rawValue:)) ?? .everything
        }
        lockScreenEffect = values["lockScreenEffect"] as? Bool ?? false
    }
    let hardwareIdentifier = MacHardware.identifier
    func useDetectedModel() {
        previewModel = MacHardware.previewModel(for: hardwareIdentifier) ?? "Simple"
        previewColor = availableColors[0]
    }
    func resetSettings() {
        referenceChangeReason = "Reset to defaults"
        defer { referenceChangeReason = "Adjusted manually" }
        setEnabled(false, source: "Settings reset")
        appearance = .system
        lockScreenEffect = false
        liveDesktopCapture = true
        lockScreenContent = .everything
        selectedLockApplications = [:]
        showDockIcon = true
        geometry = ViewingGeometry(); refreshDisplaySize()
        trigger = 90; smoothing = 0.055; blurStrength = 1; fadeStrength = 1
        holdToReset = true; holdDelay = 1
        autoCalibrate = true; enableAtLaunch = true; autoCalibrationDelay = 5; minimumCalibrationAngle = 30
        eyeRelativePreview = false; preview = 0; previewEditing = false; previewPlaying = false
        previewHold = HoldResetState(); lidHold = HoldResetState(); previewReset = 0
        calibrationAngleGate = ResetAngleGate(); foldThreshold = FoldThreshold()
        previewModel = MacHardware.previewModel(for: hardwareIdentifier) ?? "Simple"
        previewColor = availableColors[0]
        status = "Settings restored to defaults."
    }
    @Published var angle: Double?
    @Published var enabled = false
    @Published var lockScreenContent = LockScreenContent.everything {
        didSet {
            saveSettings()
            hide()
            lidHold = HoldResetState(); foldThreshold = FoldThreshold()
        }
    }
    @Published var selectedLockApplications: [String: String] = [:] {
        didSet {
            saveSettings()
            hide()
            lidHold = HoldResetState(); foldThreshold = FoldThreshold()
        }
    }
    func chooseLockScreenApplications() {
        let panel = NSOpenPanel()
        panel.title = "Include applications on the lock screen"
        panel.message = "Choose the apps whose visible windows and overlays should fold with the lock screen."
        panel.prompt = "Include"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        var applications = selectedLockApplications
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  identifier != "local.macfold.app" else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            applications[identifier] = name
        }
        selectedLockApplications = applications
    }
    @Published var liveDesktopCapture = true {
        didSet {
            saveSettings()
            hide()
            lidHold = HoldResetState(); foldThreshold = FoldThreshold()
        }
    }
    @Published var lockScreenEffect = false {
        didSet {
            saveSettings()
            guard settingsReady else { return }
            hide()
            if lockScreenEffect { prepareLockPanel() }
            else { preparedLockPanel?.close(); preparedLockPanel = nil }
            updateLockTickTimer()
            lidHold = HoldResetState(); foldThreshold = FoldThreshold()
            lockScreenStatus = lockScreenEffect ? lockSpaceDiagnostic : "Lock-screen fold off."
        }
    }
    @Published var lockScreenStatus = "Lock-screen fold off."
    private var screenLocked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var lockTickTimer: Timer?
    private var lockStateWatchdog: Timer?
    private var preparedLockPanel: FoldOverlayPanel?
    private var lockSpaceReady = false
    private var lockSpaceDiagnostic = "Overlay Space not prepared."
    @Published var previewModel = "MacBookPro14" {
        didSet { saveSettings(); if !availableColors.contains(previewColor) { previewColor = availableColors[0] } }
    }
    @Published var previewColor = "Space Black" { didSet { saveSettings() } }
    var availableColors: [String] { previewModel.hasPrefix("MacBookAir") ? ["Sky Blue", "Silver", "Starlight", "Midnight"] : ["Space Black"] }
    var previewAsset: String {
        previewModel.hasPrefix("MacBookAir") ? previewModel + "-" + previewColor.lowercased().replacingOccurrences(of: " ", with: "-") : previewModel
    }
    @Published var previewPlaying = false
    private var previewPlayback = PreviewPlayback(value: 0)
    func togglePreviewPlayback() {
        previewPlaying.toggle()
        previewPlayback = PreviewPlayback(value: preview, closing: preview < 1.0)
        previewEditing = false
        previewHold.rearm()
    }
    var previewEditing = false
    func editPreview(_ editing: Bool) {
        if editing { previewPlaying = false }
        previewEditing = editing
        previewHold.rearm()
    }
    @Published var preview = 0.0 {
        didSet { if preview != oldValue { previewHold.rearm() } }
    }
    @Published var eyeRelativePreview = false { didSet { saveSettings() } }
    var previewStart: Double { eyeRelativePreview ? max(trigger, geometry.edgeOnDegrees) : trigger }
    var previewLidAngle: Double {
        let end = eyeRelativePreview ? geometry.edgeOnDegrees : 0
        return previewStart + (end - previewStart) * preview
    }
    var previewProjectionProgress: Double { 1 - previewLidAngle / previewStart }
    var previewReadout: Double {
        eyeRelativePreview ? geometry.eyeRelativeDegrees(lidDegrees: previewLidAngle) : previewLidAngle
    }
    @Published var previewReset = 0.0
    @Published var holdToReset = true {
        didSet { previewHold.rearm(); lidHold.rearm(); saveSettings() }
    }
    @Published var minimumCalibrationAngle = 30.0 { didSet { saveSettings() } }
    private var calibrationAngleGate = ResetAngleGate()
    @Published var holdDelay = 1.0 { didSet { saveSettings() } }
    @Published var blurStrength = 1.0 { didSet { saveSettings() } }
    private var previewHold = HoldResetState()
    private var lidHold = HoldResetState()
    @Published var trigger = 90.0 {
        didSet {
            saveSettings()
            guard settingsReady else { return }
            activity.change(from: oldValue, to: trigger, reason: referenceChangeReason)
            persistActivity()
        }
    }
    @Published var geometry = ViewingGeometry() { didSet { saveSettings() } }
    @Published var displaySizeDescription = "Fallback display size"
    private func refreshDisplaySize() {
        guard let screen = NSScreen.screens.first(where: {
            guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }), let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        let size = CGDisplayScreenSize(id)
        if size.width > 100 && size.height > 80 {
            geometry.width = size.width; geometry.height = size.height
            displaySizeDescription = "Display: \(Int(size.width)) × \(Int(size.height)) mm"
        }
    }
    @Published var status = "Preview is ready. Enable lid animation to use your desktop."
    let artwork: CIImage
    private let sampler = LidSampler()
    private var foldThreshold = FoldThreshold()
    private var displayLink: CADisplayLink?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lidSmoothing = SmoothValue()
    @Published var autoCalibrationDelay = 5.0 { didSet { saveSettings() } }
    @Published var autoCalibrate = true {
        didSet { settledCalibration = SettledCalibration(); pendingCalibration = nil; saveSettings() }
    }
    private var settledCalibration = SettledCalibration()
    private var pendingCalibration: Double?
    @Published var smoothing = 0.055 { didSet { saveSettings() } }
    @Published var refreshRate = 60
    private var overlay: NSWindow?
    private var canvas: MetalFoldView?
    private var desktopCapture: DesktopCapture?
    private var captureScreenFrame: NSRect?
    private var captureIsLockScreen = false
    private var lockOverlayLevel = Int(CGShieldingWindowLevel()) + 1
    private var lockBackgroundWindowCount = 0
    private var lockAdditionalWindowCount = 0
    private var lockCaptureWindowIDs: Set<CGWindowID> = []
    private var lockCaptureDisplayID: CGDirectDisplayID?
    private var nextLockFilterRefresh = 0.0
    private var lockFilterRefreshing = false
    private var nextLockOrderRefresh = 0.0
    private var overlayReveal = SmoothValue()
    private var capturing = false
    private var generation = 0
    private var progress = 0.0
    private var captureRetryAfter = 0.0
    private var resumeGate = FoldResumeGate()
    private var suspended: Bool { resumeGate.suspended }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        artwork = CIImage(data: PreviewArtwork.image().tiffRepresentation!)!
        super.init()
        refreshDisplaySize()
        restoreSettings()
        useDetectedModel()
        if let data = preferences.data(forKey: "Lidscape.activity.v1"),
           let stored = try? JSONDecoder().decode(ActivityHistory.self, from: data) {
            activity = stored
            activity.record(date: Date())
            activity.changes = Array(activity.changes.suffix(200))
        }
        settingsReady = true
        preferences.set(true, forKey: "Lidscape.calibrationDelayV2")
        saveSettings()
        DispatchQueue.main.async { [weak self] in
            self?.applyDockPreference()
            self?.startApplication()
        }
        if let screen = NSScreen.screens.first(where: { $0.maximumFramesPerSecond > 60 }) ?? NSScreen.main {
            refreshRate = screen.maximumFramesPerSecond
            let target = FrameTickTarget { [weak self] in
                guard let self, !(self.screenLocked && self.lockScreenEffect) else { return }
                self.tick()
            }
            let link = screen.displayLink(target: target, selector: #selector(FrameTickTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(80, refreshRate)), maximum: Float(refreshRate), preferred: Float(refreshRate))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard Bundle.main.bundleIdentifier == "local.macfold.app" else { return }
                self?.refreshLoginStatus()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistActivity() }
        }
        let center = NSWorkspace.shared.notificationCenter
        let lifecycleNotifications: [(Notification.Name, FoldResumeGate.Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)
        ]
        for (name, reason, suspending) in lifecycleNotifications {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleLifecycle(reason, suspending: suspending) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(); self?.refreshDisplaySize() }
        }
        // Notifications provide immediate transitions; session polling below
        // repairs missed events without turning the user's saved setting off.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreenLock(locked) }
            }
            lockObservers.append(observer)
        }
    }
    private func refreshScreenLockState() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard locked != screenLocked else { return }
        handleScreenLock(locked)
    }
    private func updateLockTickTimer() {
        lockTickTimer?.invalidate(); lockTickTimer = nil
        guard screenLocked && lockScreenEffect else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockTickTimer = timer
    }
    private func handleScreenLock(_ locked: Bool) {
        screenLocked = locked
        hide()
        sampler.restart()
        foldThreshold = FoldThreshold(); lidHold = HoldResetState()
        pendingCalibration = nil; settledCalibration = SettledCalibration()
        captureRetryAfter = 0
        if locked && lockScreenEffect {
            prepareLockPanel()
            preparedLockPanel?.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            lockScreenStatus = "Locked. Waiting for the lid to enter the effect range."
        }
        updateLockTickTimer()
    }
    private func handleLifecycle(_ reason: FoldResumeGate.Reason, suspending: Bool) {
        if suspending { resumeGate.suspend(reason) }
        else { resumeGate.resume(reason) }
        hide()
        sampler.restart()
        foldThreshold = FoldThreshold()
        lidHold = HoldResetState()
        pendingCalibration = nil
        settledCalibration = SettledCalibration()
    }
    func calibrateFromLid() {
        guard let current = sampler.latest(), (60...150).contains(current) else {
            status = "Calibration needs a sensor reading with the lid between 60° and 150°."; return
        }
        applyCalibration(current, automatic: false)
    }
    private func applyCalibration(_ current: Double, automatic: Bool = true) {
        referenceChangeReason = automatic ? "Auto-calibrated" : "Calibrated by you"
        defer { referenceChangeReason = "Adjusted manually" }
        geometry.calibrate(lidDegrees: current)
        trigger = current
        preview = 0
        hide(); lidHold = HoldResetState(); previewHold = HoldResetState()
        status = String(format: "Calibrated at %.0f°: eyes estimated %.1f cm above the hinge, facing the screen center. Adjust distance before calibrating.", current, geometry.eyeHeight / 10)
    }
    @Published var needsScreenPermission = false
    @Published var checkingCapture = false
    private var enableRequest = 0
    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    private func setEffectState(_ value: Bool, source: String) {
        guard enabled != value else { return }
        enabled = value
        activity.recordState(enabled: value, source: source)
        persistActivity()
    }
    func setEnabled(_ value: Bool, source: String = "Manual control") {
        guard !value || !enabled else { return }
        enableRequest += 1
        let request = enableRequest
        setEffectState(false, source: source)
        checkingCapture = false
        foldThreshold = FoldThreshold()
        lidHold = HoldResetState()
        hide()
        if !value { status = "Lid animation paused."; return }
        needsScreenPermission = false
        checkingCapture = true
        status = "Checking desktop capture access…"
        // Validate ScreenCaptureKit now, rather than hiding failures until a fold.
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard request == enableRequest else { return }
                checkingCapture = false
                guard content.displays.contains(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
                    status = "No built-in MacBook display found."; return
                }
                setEffectState(true, source: source)
                status = angle == nil ? "Desktop capture ready, but no lid sensor reading is available." : "Ready. Close the physical lid below \(Int(trigger - 1.5))° to start the effect."
            } catch {
                guard request == enableRequest else { return }
                checkingCapture = false
                let captureError = error as NSError
                needsScreenPermission = captureError.domain == SCStreamErrorDomain && captureError.code == SCStreamError.Code.userDeclined.rawValue
                status = needsScreenPermission
                    ? "Screen Recording access was denied. Enable Lidscape in System Settings, then quit and reopen the app."
                    : "Desktop capture failed (\(captureError.domain) \(captureError.code)): \(error.localizedDescription)"

            }
        }
    }
    private func selectLockScreenWindows(content: SCShareableContent, display: SCDisplay) throws -> [SCWindow] {
        // AppKit can return positive sentinel values above UInt32.max for
        // status-bar windows while locking. Read once and reject invalid IDs.
        let ownIDs = Set(NSApp.windows.compactMap { LockScreenCapturePolicy.captureWindowID($0.windowNumber) })
        let systemWindows = content.windows.filter {
            !ownIDs.contains($0.windowID) && LockScreenCapturePolicy.accepts(
                bundleIdentifier: $0.owningApplication?.bundleIdentifier, onScreen: $0.isOnScreen,
                windowFrame: $0.frame, displayFrame: display.frame)
        }
        let loginIDs = Set(systemWindows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.loginwindow" }.map(\.windowID))
        guard !loginIDs.isEmpty else {
            throw NSError(domain: "Lidscape.Capture", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "macOS is not exposing the lock-screen surface."])
        }
        var windows = systemWindows
        if lockScreenContent != .systemOnly {
            let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            let ordered = info?.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value } ?? []
            guard let foreground = LockScreenCapturePolicy.foregroundWindowIDs(ordered: ordered, loginWindows: loginIDs) else {
                throw NSError(domain: "Lidscape.Capture", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot verify which app windows are above the lock screen."])
            }
            let systemIDs = Set(systemWindows.map(\.windowID))
            let selectedIDs = Set(selectedLockApplications.keys)
            windows += content.windows.filter {
                !systemIDs.contains($0.windowID) && !ownIDs.contains($0.windowID)
                    && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                    && foreground.contains($0.windowID)
                    && LockScreenCapturePolicy.accepts(bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                        // WindowServer's visible ordering includes private Spaces;
                        // SCWindow.isOnScreen may only reflect an app's normal Space.
                        onScreen: true, windowFrame: $0.frame, displayFrame: display.frame,
                        content: lockScreenContent, selectedApplications: selectedIDs)
            }
        }
        lockBackgroundWindowCount = windows.filter { LockScreenCapturePolicy.isBackgroundProvider($0.owningApplication?.bundleIdentifier) }.count
        lockAdditionalWindowCount = windows.count - systemWindows.count
        return windows
    }
    private func refreshLockCaptureWindows(now: Double) {
        guard captureIsLockScreen, liveDesktopCapture, !lockFilterRefreshing,
              now >= nextLockFilterRefresh, let capture = desktopCapture,
              let displayID = lockCaptureDisplayID else { return }
        nextLockFilterRefresh = now + 0.75
        lockFilterRefreshing = true
        let token = generation
        Task { [weak self, weak capture] in
            guard let self, let capture else { return }
            defer { lockFilterRefreshing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard generation == token, screenLocked,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let windows = try selectLockScreenWindows(content: content, display: display)
                let ids = Set(windows.map(\.windowID))
                guard ids != lockCaptureWindowIDs else { return }
                try await capture.updateFilter(SCContentFilter(display: display, including: windows))
                guard generation == token else { return }
                lockCaptureWindowIDs = ids
            } catch {
                guard generation == token else { return }
                hide()
                captureRetryAfter = ProcessInfo.processInfo.systemUptime + 1
                lockCaptureProblem = error.localizedDescription
                lockScreenStatus = "Lock-screen capture interrupted: \(error.localizedDescription)"
            }
        }
    }
    private func prepareLockPanel() {
        guard preparedLockPanel == nil,
              let screen = NSScreen.screens.first(where: {
                  guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
                  return CGDisplayIsBuiltin(id) != 0
              }) else { return }
        let panel = FoldOverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.canBecomeVisibleWithoutLogin = true
        panel.hidesOnDeactivate = false; panel.canHide = false
        panel.isFloatingPanel = true; panel.ignoresMouseEvents = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
        panel.level = .statusBar
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        preparedLockPanel = panel
        // Register a clear, empty window while unlocked, then reuse that exact
        // window after locking. No desktop image is ever attached to this panel.
        panel.orderFrontRegardless()
        lockSpaceReady = LockScreenOverlaySpace.shared.attach(panel, content: lockScreenContent)
        lockSpaceDiagnostic = LockScreenOverlaySpace.shared.diagnostic
        if !screenLocked { lockScreenStatus = lockSpaceDiagnostic }
    }
    private func dismissOverlay() {
        canvas?.stopRendering()
        if let overlay, overlay === preparedLockPanel {
            overlay.alphaValue = 0
            overlay.contentView = NSView(frame: NSRect(origin: .zero, size: overlay.frame.size))
            overlay.level = .statusBar
            overlay.displayIfNeeded()
            overlay.alphaValue = 1
        } else {
            overlay?.orderOut(nil)
            overlay?.contentView = nil
            overlay?.close()
        }
        overlay = nil; canvas = nil
        overlayReveal = SmoothValue()
    }
    private func hide() {
        generation += 1
        desktopCapture?.stop(); desktopCapture = nil; captureScreenFrame = nil; captureIsLockScreen = false
        dismissOverlay()
        lockCaptureWindowIDs = []; lockCaptureDisplayID = nil
        nextLockFilterRefresh = 0; nextLockOrderRefresh = 0
        progress = 0; lidSmoothing = SmoothValue()
    }
    private func makeOverlay(frame: NSRect) -> Bool {
        let window: NSWindow
        if captureIsLockScreen {
            guard let panel = preparedLockPanel, lockSpaceReady else {
                lockScreenStatus = lockSpaceDiagnostic
                return false
            }
            panel.setFrame(frame, display: false)
            window = panel
        } else {
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if captureIsLockScreen {
            window.canBecomeVisibleWithoutLogin = true
            window.level = NSWindow.Level(rawValue: lockOverlayLevel)
            window.collectionBehavior.formUnion([.canJoinAllApplications, .ignoresCycle])
        }
        window.ignoresMouseEvents = true
        // Keep the drawable attached, but visually transparent, while the first
        // GPU frame is prepared. Ordering an opaque window first flashes black.
        window.alphaValue = 0.001
        let view = MetalFoldView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        overlay = window; canvas = view
        if captureIsLockScreen {
            guard LockScreenOverlaySpace.shared.attach(window, content: lockScreenContent) else {
                lockSpaceReady = false
                lockSpaceDiagnostic = LockScreenOverlaySpace.shared.diagnostic
                lockScreenStatus = lockSpaceDiagnostic
                dismissOverlay()
                return false
            }
            window.orderFrontRegardless()
        }
        return true
    }
    deinit {
        displayLink?.invalidate(); desktopCapture?.stop()
        lockTickTimer?.invalidate()
        lockStateWatchdog?.invalidate()
        let panel = preparedLockPanel
        DispatchQueue.main.async { panel?.close() }
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { refreshMenuStatus(); recordActivity(now: now) }
        let dt = min(0.1, now - lastTick); lastTick = now
        if previewPlaying {
            let playback = previewPlayback.advance(dt: dt, holdDelay: holdDelay)
            preview = playback.value
            previewEditing = playback.moving
        }
        let previewAmount = previewHold.update(angle: previewLidAngle, now: now, delay: holdDelay, moving: previewEditing, enabled: holdToReset)
        if previewAmount != previewReset { previewReset = previewAmount }
        let reading = sampler.latest(now: now)
        if reading != angle { angle = reading }
        let canAutoCalibrate = angle.map { calibrationAngleGate.update(angle: $0, minimum: minimumCalibrationAngle) } ?? false
        if !canAutoCalibrate { pendingCalibration = nil; settledCalibration = SettledCalibration() }
        if autoCalibrate && !screenLocked && !suspended && canAutoCalibrate {
            if let settled = settledCalibration.update(angle: angle, now: now, delay: autoCalibrationDelay) { pendingCalibration = settled }
            if let pending = pendingCalibration {
                if let angle, abs(angle - pending) > 1.5 { pendingCalibration = nil }
                else if overlay == nil || lidHold.amount == 1 {
                    pendingCalibration = nil; applyCalibration(pending)
                }
            }
        }
        guard enabled, !suspended, (!screenLocked || lockScreenEffect), let angle else {
            foldThreshold = FoldThreshold()
            if overlay != nil || desktopCapture != nil || capturing { hide() }
            return
        }
        if screenLocked && !lockSpaceReady {
            lockScreenStatus = lockSpaceDiagnostic
            if overlay != nil || desktopCapture != nil || capturing { hide() }
            return
        }
        let target = min(1, max(0, (trigger - angle) / trigger))
        guard foldThreshold.update(angle: angle, threshold: trigger) else {
            lidHold = HoldResetState()
            if overlay != nil || desktopCapture != nil || capturing { hide() }
            return
        }
        refreshLockCaptureWindows(now: now)
        let frame = desktopCapture?.latest()
        if let error = frame?.error {
            if captureIsLockScreen { lockCaptureProblem = error.localizedDescription; lockScreenStatus = "Lock-screen stream interrupted: \(error.localizedDescription)" }
            hide()
            captureRetryAfter = now + 1
            needsScreenPermission = !CGPreflightScreenCaptureAccess()
            if needsScreenPermission { setEffectState(false, source: "Screen Recording access lost") }
            status = "Desktop stream interrupted: \(error.localizedDescription)"
            return
        }
        let canPresentFrame = frame?.image != nil && canvas?.hasRenderedFrame == true
        let reset = lidHold.update(angle: angle, now: now, delay: pendingCalibration == nil ? holdDelay : 0,
            enabled: holdToReset || pendingCalibration != nil, canRenderReturn: canPresentFrame,
            waitingForFrame: !canPresentFrame && (desktopCapture != nil || capturing || lidHold.amount < 1))
        if reset == 1 && !lidHold.resuming {
            if overlay != nil || desktopCapture != nil || capturing { hide() }
            return
        }
        progress = lidSmoothing.advance(to: target, dt: dt, response: smoothing)
        if let image = frame?.image, let screenFrame = captureScreenFrame {
            if !liveDesktopCapture { desktopCapture?.freeze() }
            if canvas == nil {
                guard makeOverlay(frame: screenFrame) else { return }
                status = "Live desktop capture active."
                if captureIsLockScreen { lockScreenStatus = "Lock-screen capture active." }
            }
            if let canvas {
                canvas.source = image
                canvas.resetAmount = reset; canvas.blurStrength = blurStrength; canvas.fadeStrength = fadeStrength
                canvas.geometry = geometry; canvas.referenceDegrees = trigger; canvas.progress = progress
                if overlay?.isVisible == false { overlay?.orderFrontRegardless() }
                canvas.draw()
                if canvas.hasRenderedFrame {
                    let alpha = overlayReveal.advance(to: 1, dt: dt, response: 0.045)
                    overlay?.alphaValue = alpha > 0.995 ? 1 : max(0.001, alpha)
                }
                if captureIsLockScreen, let overlay {
                    // Other overlay apps can reassert their own top-level Space.
                    // Reassert ours while the fold is visible, never their windows.
                    if canvas.hasRenderedFrame && now >= nextLockOrderRefresh {
                        nextLockOrderRefresh = now + 0.25
                        _ = LockScreenOverlaySpace.shared.attach(overlay, content: lockScreenContent)
                        overlay.orderFrontRegardless()
                    }
                    let render = canvas.hasRenderedFrame ? "GPU ready" : "waiting for GPU/drawable"
                    let space = overlay.isOnActiveSpace ? "active Space" : "outside active Space"
                    let visible = overlay.occlusionState.contains(.visible) ? "onscreen" : "occluded"
                    let level = LockScreenOverlaySpace.shared.actualLevel.map(String.init) ?? "unknown"
                    let diagnostic = "\(lockScreenContent.title); \(render); \(space); \(visible); opacity \(Int(overlay.alphaValue * 100))%; Space level \(level) (requested \(lockScreenContent.overlaySpaceLevel)); background windows \(lockBackgroundWindowCount); additional windows \(lockAdditionalWindowCount)."
                    if lockScreenStatus != diagnostic { lockScreenStatus = diagnostic }
                    if now >= nextDiagnosticSnapshot {
                        nextDiagnosticSnapshot = now + 1
                        lastLockCapture = LockCaptureSnapshot(date: Date(), wallpaperWindows: lockBackgroundWindowCount,
                            appWindows: lockAdditionalWindowCount, rendered: canvas.hasRenderedFrame,
                            visible: overlay.occlusionState.contains(.visible), level: LockScreenOverlaySpace.shared.actualLevel,
                            requestedLevel: lockScreenContent.overlaySpaceLevel)
                        lockCaptureProblem = nil
                    }
                }
            }
            return
        }
        // Do not leave the last rendered drawable visible while capture is suspended.
        if overlay != nil { dismissOverlay() }
        guard desktopCapture == nil, !capturing, target > 0, now >= captureRetryAfter else { return }
        capturing = true
        status = "Starting live desktop capture…"
        let token = generation
        let forLockScreen = screenLocked
        if forLockScreen { lockCaptureProblem = nil; lockScreenStatus = "Checking whether macOS exposes lock-screen content…" }
        Task {
            let capture = DesktopCapture()
            defer { capturing = false }
            do {
                // Settings may be closed or hidden when the menu-bar app folds.
                // Include offscreen windows so its application can still be excluded.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard generation == token, enabled, !suspended else { return }
                guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
                      let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else {
                    captureRetryAfter = ProcessInfo.processInfo.systemUptime + 1
                    status = "No built-in MacBook display found."; return
                }
                let config = SCStreamConfiguration()
                config.width = min(1920, display.width)
                config.height = max(1, Int((Double(display.height) * Double(config.width) / Double(display.width)).rounded()))
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(min(60, refreshRate)))
                config.queueDepth = 3
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.capturesAudio = false
                // Exclude this process, including overlays created after the stream
                // starts, so the transformed display never feeds back into capture.
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard forLockScreen || !ownApps.isEmpty else {
                    throw NSError(domain: "Lidscape.Capture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Lidscape could not exclude its own windows from capture."])
                }
                let filter: SCContentFilter
                if forLockScreen {
                    let lockWindows = try selectLockScreenWindows(content: content, display: display)
                    // Explicit window inclusion captures overlays in private
                    // Spaces that display-level capture can omit.
                    filter = SCContentFilter(display: display, including: lockWindows)
                    config.ignoreGlobalClipDisplay = true
                    lockCaptureWindowIDs = Set(lockWindows.map(\.windowID))
                    lockCaptureDisplayID = display.displayID
                    lockOverlayLevel = lockScreenContent == .systemOnly
                        ? max(Int(CGWindowLevelForKey(.assistiveTechHighWindow)), lockWindows.map(\.windowLayer).max() ?? 0) + 1
                        : Int(CGWindowLevelForKey(.maximumWindow))
                } else {
                    filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                }
                desktopCapture = capture; captureScreenFrame = screen.frame; captureIsLockScreen = forLockScreen
                try await capture.start(filter: filter, configuration: config)
                guard generation == token, enabled, !suspended else { capture.stop(); return }
                status = canvas == nil ? "Waiting for live desktop frames…" : "Live desktop capture active."
                if forLockScreen && canvas == nil { lockScreenStatus = "Login window found; waiting for capture frames." }
            } catch {
                capture.stop()
                guard generation == token else { return }
                if forLockScreen { lockCaptureProblem = error.localizedDescription; lockScreenStatus = "Lock-screen capture failed: \(error.localizedDescription)" }
                hide()
                captureRetryAfter = ProcessInfo.processInfo.systemUptime + 1
                needsScreenPermission = !CGPreflightScreenCaptureAccess()
                if needsScreenPermission { setEffectState(false, source: "Screen Recording access lost") }
                status = "Desktop stream failed: \(error.localizedDescription)"
            }
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case preview, general, appearance, effect, calibration, lockScreen, activity
    var id: Self { self }
    var title: String {
        switch self {
        case .preview: return "Preview"
        case .general: return "General"
        case .appearance: return "Appearance"
        case .activity: return "Activity"
        case .effect: return "Fold Effect"
        case .calibration: return "Calibration"
        case .lockScreen: return "Lock Screen"
        }
    }
    var symbol: String {
        switch self {
        case .preview: return "laptopcomputer"
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .activity: return "chart.xyaxis.line"
        case .effect: return "rectangle.lefthalf.inset.filled"
        case .calibration: return "viewfinder"
        case .lockScreen: return "lock"
        }
    }
    var color: Color {
        switch self {
        case .preview: return .cyan
        case .general: return .gray
        case .appearance: return .purple
        case .activity: return .green
        case .effect: return .indigo
        case .calibration: return .orange
        case .lockScreen: return .blue
        }
    }
}

struct AppearanceThumbnail: View {
    let appearance: AppAppearance
    var body: some View {
        HStack(spacing: 0) {
            miniature(dark: appearance == .dark)
            if appearance == .system { miniature(dark: true) }
        }.frame(height: 82).clipShape(RoundedRectangle(cornerRadius: 9))
    }
    private func miniature(dark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 5) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 2).fill(index == 1 ? Color.accentColor : (dark ? Color.white.opacity(0.15) : Color.black.opacity(0.1))).frame(height: 5)
                }
                Spacer(minLength: 0)
            }.padding(7).frame(maxWidth: 35).background(dark ? Color(white: 0.19) : Color(white: 0.88))
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(dark ? Color(white: 0.25) : .white).frame(height: 18)
                RoundedRectangle(cornerRadius: 3).fill(dark ? Color(white: 0.25) : .white).frame(height: 24)
                Spacer(minLength: 0)
            }.padding(7).frame(maxWidth: .infinity).background(dark ? Color(white: 0.13) : Color(white: 0.95))
        }
    }
}

struct SettingsView: View {
    @State private var sideView = false
    @State private var selection: SettingsPane? = .general
    @State private var showResetConfirmation = false
    @State private var showClearHistory = false
    @State private var inspectedEventCluster: EffectEventCluster?
    @ObservedObject var model: FoldModel
    private var effectEnabled: Binding<Bool> {
        Binding(get: { model.enabled }, set: { model.setEnabled($0) })
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                sidebarRow(.preview)
                Section("Settings") {
                    ForEach(SettingsPane.allCases.filter { $0 != .preview }) { pane in sidebarRow(pane) }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Lidscape")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(model.menuStatusColor).frame(width: 7, height: 7)
                    Text(model.menuStatus).lineLimit(1)
                    Spacer()
                    Text(model.angle.map { "\(Int($0))°" } ?? "—").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary).padding(14)
            }
        } detail: {
            VStack(spacing: 0) {
                if model.needsScreenPermission {
                    HStack {
                        Label("Screen Recording access is needed.", systemImage: "rectangle.on.rectangle")
                        Spacer()
                        Button("Open System Settings…") { model.openScreenRecordingSettings() }
                    }.font(.callout).padding().background(.quaternary)
                }
                paneContent
            }
            .navigationTitle((selection ?? .general).title)
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) { EffectControl(model: model).padding(.trailing, 12) }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { EffectControl(model: model).padding(.trailing, 12) }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 840, idealWidth: 900, minHeight: 580, idealHeight: 680)
        .confirmationDialog("Reset Lidscape settings?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset settings", role: .destructive) { model.resetSettings(); sideView = false }
        } message: {
            Text("Restores effect, calibration, preview, and app preferences. Animation will pause. Launch at login and macOS permissions stay unchanged.")
        }
        .confirmationDialog("Clear activity history?", isPresented: $showClearHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearActivity() }
        } message: { Text("Removes saved daily totals, angle changes, enable/pause events, and the live graph. New activity will start recording immediately.") }
    }
    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white).frame(width: 24, height: 24)
                .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: 5))
        }.padding(.vertical, 3).tag(pane)
    }
    @ViewBuilder private var paneContent: some View {
        switch selection ?? .general {
        case .preview: previewTab
        case .general: generalPane
        case .appearance: appearancePane
        case .activity: activityPane
        case .effect: effectPane
        case .calibration: calibrationPane
        case .lockScreen: lockScreenPane
        }
    }
    private var previewTab: some View {
        VStack(spacing: 12) {
            MacBookBridge(progress: model.previewProjectionProgress, source: model.artwork, referenceDegrees: model.previewStart, geometry: model.geometry, sideView: sideView, resetAmount: model.previewReset, blurStrength: model.blurStrength, model: model.previewAsset, fadeStrength: model.fadeStrength, smoothing: model.smoothing)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Picker("Camera", selection: $sideView) {
                Text("Your viewpoint").tag(false)
                Text("Inspect in 3D").tag(true)
            }.pickerStyle(.segmented)
            HStack {
                Button { model.togglePreviewPlayback() } label: {
                    Image(systemName: model.previewPlaying ? "pause.fill" : "play.fill")
                }.help(model.previewPlaying ? "Pause preview" : "Auto-play fold preview")
                    .accessibilityLabel(model.previewPlaying ? "Pause preview" : "Play preview")
                Text("Lid")
                Slider(value: $model.preview, in: 0...1, onEditingChanged: { model.editPreview($0) })
                Text("\(Int(model.previewReadout.rounded()))°").monospacedDigit().frame(width: 42)
            }
            HStack {
                Text(!model.holdToReset ? "Hold reset off · projection stays active" : (model.previewReset > 0.99 ? "Held steady · normal view" : "Drag to fold · release to test hold reset"))
                Spacer()
                Text(model.eyeRelativePreview ? "0° = edge-on" : "0° = closed")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(14)
            .onDisappear { if model.previewPlaying { model.togglePreviewPlayback() } }
    }
    private var generalPane: some View {
        Form {
            Section {
                Toggle("Desktop effect", isOn: effectEnabled)
                Toggle("Live desktop capture", isOn: $model.liveDesktopCapture)
            } header: { Text("Animation") } footer: {
                Text(model.liveDesktopCapture ? "Content stays live throughout the fold." : "Captures a still image for each fold, then stops recording.")
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginNeedsApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Enable animation on launch", isOn: $model.enableAtLaunch)
            }
            Section {
                LabeledContent("Status") { Text(model.status).foregroundStyle(.secondary).textSelection(.enabled) }
                LabeledContent("Display") { Text(model.displaySizeDescription.replacingOccurrences(of: "Display: ", with: "")).foregroundStyle(.secondary) }
                LabeledContent("Refresh rate") { Text("\(model.refreshRate) Hz").foregroundStyle(.secondary) }
                Button("Reset settings…") { showResetConfirmation = true }
            } header: { Text("About this setup") } footer: { Text("Changes save automatically.") }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
    private var effectPane: some View {
        Form {
            Section {
                sliderRow("Start below", value: $model.trigger, range: 35...150, step: 1, readout: "\(Int(model.trigger))°")
                sliderRow("Smoothing", value: $model.smoothing, range: 0.025...0.14, step: 0.001, readout: "\(Int(model.smoothing * 1000)) ms")
            } header: { Text("Motion") } footer: {
                Text("The effect begins below your starting angle. More smoothing softens motion and adds a little delay.")
            }
            Section {
                sliderRow("Blur", value: $model.blurStrength, range: 0...2, readout: "\(Int(model.blurStrength * 100))%")
                sliderRow("Fade to black", value: $model.fadeStrength, range: 0...2, readout: "\(Int(model.fadeStrength * 100))%")
            } header: { Text("Appearance") } footer: {
                Text("Blur and darkening grow toward the top of the screen as the lid closes. Set either to 0% to disable it.")
            }
            Section {
                Toggle("Hold to reset", isOn: $model.holdToReset)
                if model.holdToReset {
                    sliderRow("Reset delay", value: $model.holdDelay, range: 0.5...3, step: 0.1, readout: String(format: "%.1f s", model.holdDelay))
                }
            } header: { Text("Return to normal") } footer: {
                Text("Hold the lid still to ease back to your normal desktop. Moving it again brings the effect back.")
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
    private var calibrationPane: some View {
        Form {
            Section {
                sliderRow("Viewing distance", value: $model.geometry.distance, range: 300...1000, step: 10, readout: "\(Int(model.geometry.distance / 10)) cm")
                LabeledContent("Current lid angle") { Text(model.angle.map { "\(Int($0))°" } ?? "Sensor unavailable").foregroundStyle(.secondary) }
                Button("Calibrate from current lid") { model.calibrateFromLid() }.disabled(model.angle == nil)
            } header: { Text("Viewing position") } footer: {
                Text("Set the distance from your eyes to the hinge. Sit comfortably, look at the screen center, then calibrate.")
            }
            Section {
                Toggle("Auto-calibrate when the lid settles", isOn: $model.autoCalibrate)
                if model.autoCalibrate {
                    sliderRow("Calibration delay", value: $model.autoCalibrationDelay, range: 0.5...8, step: 0.1, readout: String(format: "%.1f s", model.autoCalibrationDelay))
                    sliderRow("Minimum angle", value: $model.minimumCalibrationAngle, range: 0...120, step: 1, readout: "\(Int(model.minimumCalibrationAngle))°")
                }
            } header: { Text("Automatic calibration") } footer: {
                Text("Adopts your comfortable lid position after it stays still. The minimum angle only limits automatic calibration.")
            }
            Section("Advanced") {
                DisclosureGroup("Manual eye height") {
                    sliderRow("Height above hinge", value: $model.geometry.eyeHeight, range: -600...3000, step: 10, readout: "\(Int(model.geometry.eyeHeight / 10)) cm")
                }
                Picker("Preview zero", selection: $model.eyeRelativePreview) {
                    Text("Lid closed").tag(false)
                    Text("Edge-on to eyes").tag(true)
                }
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
    private var lockScreenPane: some View {
        Form {
            Section {
                Toggle("Lock-screen fold", isOn: $model.lockScreenEffect)
            } footer: { Text("Apply the same lid-driven fold while your Mac is locked.") }
            Section {
                Picker("Include", selection: $model.lockScreenContent) {
                    ForEach(LockScreenContent.allCases, id: \.self) { content in Text(content.title).tag(content) }
                }
                if model.lockScreenContent == .selectedApplications {
                    ForEach(model.selectedLockApplications.keys.sorted {
                        (model.selectedLockApplications[$0] ?? $0).localizedStandardCompare(model.selectedLockApplications[$1] ?? $1) == .orderedAscending
                    }, id: \.self) { identifier in
                        HStack {
                            Text(model.selectedLockApplications[identifier] ?? identifier)
                            Spacer()
                            Button { model.selectedLockApplications.removeValue(forKey: identifier) } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless).accessibilityLabel("Remove " + (model.selectedLockApplications[identifier] ?? identifier))
                        }
                    }
                    Button("Choose applications…") { model.chooseLockScreenApplications() }
                    if model.selectedLockApplications.isEmpty {
                        Text("No apps selected. System content is still included.").foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Content") } footer: { Text(model.lockScreenContent.explanation) }
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.lockCaptureProblem != nil ? "exclamationmark.triangle.fill" : (model.lockScreenEffect && model.overlayPlacementReady ? "checkmark.circle.fill" : "info.circle.fill"))
                        .foregroundStyle(model.lockCaptureProblem != nil ? Color.orange : (model.lockScreenEffect && model.overlayPlacementReady ? Color.green : Color.secondary))
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.lockReadinessTitle).font(.headline)
                        Text(model.lockReadinessDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 5)
                LabeledContent("Overlay placement", value: model.overlayPlacementReady ? "Ready" : "Not prepared")
                if let capture = model.lastLockCapture {
                    LabeledContent("Last fold") { Text(capture.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary) }
                    LabeledContent("Wallpaper windows", value: "\(capture.wallpaperWindows)")
                    LabeledContent("App overlay windows", value: "\(capture.appWindows)")
                    LabeledContent("Renderer", value: capture.rendered ? "Frame rendered" : "Waiting for a frame")
                    LabeledContent("Visibility", value: capture.visible ? "Visible during last fold" : "Occluded during last fold")
                } else {
                    Text("No lock-screen fold recorded this launch.").foregroundStyle(.secondary)
                }
            } header: { Text("Status") }
            Section {
                DisclosureGroup("Technical details") {
                    LabeledContent("Overlay level", value: model.overlaySpaceLevel.map(String.init) ?? "Not available")
                    LabeledContent("Requested level", value: String(model.lockScreenContent.overlaySpaceLevel))
                    Text(model.lockScreenStatus).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Copy diagnostics", systemImage: "doc.on.doc") { model.copyLockDiagnostics() }
            }

        }.formStyle(.grouped).toggleStyle(.switch)
    }
    private var appearancePane: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ForEach(AppAppearance.allCases) { choice in
                        Button { model.appearance = choice } label: {
                            VStack(spacing: 10) {
                                AppearanceThumbnail(appearance: choice)
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.appearance == choice ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: model.appearance == choice ? 3 : 1))
                                HStack(spacing: 5) {
                                    Image(systemName: model.appearance == choice ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.appearance == choice ? Color.accentColor : Color.secondary)
                                    Text(choice.title).foregroundStyle(.primary)
                                }.font(.callout)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(choice.title + " appearance")
                            .accessibilityAddTraits(model.appearance == choice ? .isSelected : [])
                    }
                }.padding(.vertical, 10)
            } header: { Text("Appearance") } footer: {
                Text("System follows your Mac’s appearance. Your choice applies to Lidscape’s windows and menu panel.")
            }
            Section {
                Toggle("Show Dock icon", isOn: $model.showDockIcon)
            } header: { Text("Dock & menu bar") } footer: {
                Text("Lidscape is always available from its laptop icon in the menu bar.")
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
    private var weekActivity: [DailyActivity] {
        let calendar = Calendar.current
        return (-6...0).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
            return model.activity.days.first { calendar.isDate($0.date, inSameDayAs: day) } ?? DailyActivity(date: day)
        }
    }
    private var recentActivity: [ActivityTimelineEntry] {
        let angles = model.activity.changes.map { change in
            ActivityTimelineEntry(id: change.id, date: change.date,
                title: "\(Int(change.previous.rounded()))° → \(Int(change.angle.rounded()))°",
                detail: change.reason, symbol: "viewfinder", color: .blue)
        }
        let states = model.activity.stateEvents.map { event in
            ActivityTimelineEntry(id: event.id, date: event.date,
                title: event.enabled ? "Effect enabled" : "Effect paused", detail: event.source,
                symbol: event.enabled ? "play.fill" : "pause.fill", color: event.enabled ? .green : .orange)
        }
        return Array((angles + states).sorted { $0.date > $1.date }.prefix(20))
    }
    private var chartEventClusters: [EffectEventCluster] { EffectEventCluster.group(chartStateEvents) }
    private var chartStateEvents: [EffectStateEvent] {
        let now = Date()
        return model.activity.stateEvents.filter { $0.date >= now.addingTimeInterval(-300) && $0.date <= now }
    }
    private var activityPane: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    activityMetric("Folds today", value: String(model.todayActivity.folds))
                    Divider()
                    activityMetric("Time folding", value: model.todayActivity.seconds < 60 ? "\(Int(model.todayActivity.seconds)) s" : String(format: "%.1f min", model.todayActivity.seconds / 60))
                    Divider()
                    activityMetric("Start angle", value: "\(Int(model.trigger))°")
                }.padding(.vertical, 8)
            }
            Section {
                if model.angleSamples.count >= 2 {
                    Chart {
                        ForEach(model.angleSamples) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("Angle", sample.angle), series: .value("Trace", "Lid angle"))
                                .foregroundStyle(by: .value("Trace", "Lid angle")).lineStyle(StrokeStyle(lineWidth: 2))
                            LineMark(x: .value("Time", sample.date), y: .value("Angle", sample.reference), series: .value("Trace", "Start angle"))
                                .foregroundStyle(by: .value("Trace", "Start angle")).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4])).interpolationMethod(.stepEnd)
                        }
                        ForEach(chartEventClusters) { cluster in
                            RuleMark(x: .value("Effect state changed", cluster.date))
                                .foregroundStyle(cluster.enabled ? Color.green : Color.orange)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .accessibilityLabel(cluster.events.count > 1 ? "\(cluster.events.count) effect state changes" : (cluster.enabled ? "Effect enabled" : "Effect paused"))
                                .accessibilityValue(Text(cluster.date, format: .dateTime.hour().minute().second()))
                        }
                    }
                    .chartForegroundStyleScale(["Lid angle": Color.accentColor, "Start angle": Color.orange])
                    .chartYScale(domain: 0...180)
                    .chartXScale(domain: Date().addingTimeInterval(-300)...Date())
                    .chartXAxis { AxisMarks(values: .stride(by: .minute)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
                    .chartYAxis { AxisMarks(values: [0, 45, 90, 135, 180]) { value in AxisGridLine(); AxisValueLabel { if let degrees = value.as(Int.self) { Text("\(degrees)°") } } } }
                    .frame(height: 180).padding(.vertical, 8)
                    .accessibilityLabel("Live lid angle and starting angle over the last five minutes")
                    if !chartEventClusters.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(chartEventClusters.reversed()) { cluster in
                                    Button { inspectedEventCluster = cluster } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: cluster.events.count > 1 ? "arrow.left.arrow.right" : (cluster.enabled ? "play.fill" : "pause.fill"))
                                                .foregroundStyle(cluster.enabled ? Color.green : Color.orange)
                                            Text(cluster.events.count > 1 ? "\(cluster.events.count) changes" : (cluster.enabled ? "Enabled" : "Paused"))
                                            Text(cluster.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                                        }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                                    }.buttonStyle(.bordered).help("Show exact event times")
                                }
                            }.padding(.vertical, 3)
                        }
                        .popover(item: $inspectedEventCluster) { cluster in
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Effect events").font(.headline)
                                ForEach(cluster.events) { event in
                                    HStack(spacing: 10) {
                                        Label(event.enabled ? "Enabled" : "Paused", systemImage: event.enabled ? "play.fill" : "pause.fill")
                                            .foregroundStyle(event.enabled ? Color.green : Color.orange)
                                        Spacer()
                                        Text(event.date, format: .dateTime.hour().minute().second()).monospacedDigit()
                                    }.font(.callout)
                                }
                            }.padding(18).frame(minWidth: 260)
                        }
                    }
                } else {
                    ContentUnavailableView("Waiting for the lid sensor", systemImage: "waveform.path", description: Text("A live graph will appear as angle readings arrive."))
                        .frame(height: 170)
                }
                if model.angle == nil { Label("Lid sensor is currently unavailable.", systemImage: "info.circle").foregroundStyle(.secondary) }
            } header: { Text("Live angles · last 5 minutes") } footer: {
                Text("The horizontal dashed line is your starting angle. Vertical markers show pauses (orange) and enables (green). Nearby changes are grouped; select an event below for exact times.")
            }
            Section("This week") {
                Chart(weekActivity) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Folds", day.folds))
                        .foregroundStyle(Color.accentColor.gradient).cornerRadius(4)
                }
                .chartYScale(domain: 0...max(5, weekActivity.map(\.folds).max() ?? 0))
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 130).padding(.vertical, 8)
                .accessibilityLabel("Fold counts for the last seven days")
            }
            Section {
                if recentActivity.isEmpty {
                    Text("Enable or pause the effect, calibrate, or adjust your starting angle to begin your history.").foregroundStyle(.secondary)
                }
                ForEach(recentActivity) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.symbol).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(entry.color).frame(width: 30, height: 30)
                            .background(entry.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).monospacedDigit()
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }
            } header: { Text("Recent history") }
            Section {
                Button("Clear activity history…") { showClearHistory = true }
            } footer: { Text("History stays on this Mac. Daily totals are kept for 30 days. The live graph covers this app session.") }
        }.formStyle(.grouped)
    }
    private func activityMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0.01, readout: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: Binding(get: { value.wrappedValue }, set: {
                    value.wrappedValue = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step))
                }), in: range).labelsHidden().accessibilityLabel(title)
                    .frame(minWidth: 110, idealWidth: 170, maxWidth: 220)
                Text(readout).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct EffectControl: View {
    @ObservedObject var model: FoldModel
    private var color: Color { model.enabled ? .orange : .green }
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                control.buttonStyle(.glass).buttonBorderShape(.capsule)
            } else {
                control.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
        .tint(color).controlSize(.regular).fixedSize().disabled(model.checkingCapture)
        .help(model.enabled ? "Pause desktop effect" : "Enable desktop effect")
        .accessibilityLabel(model.enabled ? "Pause desktop effect" : "Enable desktop effect")
    }
    private var control: some View {
        Button { model.setEnabled(!model.enabled) } label: {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: model.enabled ? "pause.fill" : "play.fill")
                        .opacity(model.checkingCapture ? 0 : 1)
                    if model.checkingCapture { ProgressView().controlSize(.mini) }
                }.frame(width: 14, height: 14)
                Text(model.enabled ? "Pause" : "Enable")
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            .frame(width: 76, height: 18).contentTransition(.identity)
            .transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }
}

struct LidscapeMenu: View {
    @ObservedObject var model: FoldModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").font(.system(size: 25, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lidscape").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(model.menuStatusColor).frame(width: 6, height: 6)
                        Text(model.menuStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(model.angle.map { "\(Int($0))°" } ?? "—")
                    .font(.system(size: 28, weight: .light, design: .rounded)).monospacedDigit()
                    .accessibilityLabel(model.angle.map { "Lid angle \(Int($0)) degrees" } ?? "Lid sensor unavailable")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Desktop effect").font(.headline)
                    Spacer()
                    EffectControl(model: model)
                }
                Text(model.enabled ? (model.holdToReset ? "Folds as your lid closes. Hold still to return." : "Folds as your lid closes.") : "Animation is paused.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle("Live capture", isOn: $model.liveDesktopCapture).toggleStyle(.switch)
                Toggle("Lock-screen fold", isOn: $model.lockScreenEffect).toggleStyle(.switch)
            }
            .padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            if model.needsScreenPermission {
                Button("Allow Screen Recording…") { model.openScreenRecordingSettings() }
                    .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Label("Starts below \(Int(model.trigger))°", systemImage: "angle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Calibrate") { model.calibrateFromLid() }
                        .disabled(model.angle == nil)
                        .help("Use the current lid angle as your comfortable viewing position")
                }
            }
            Divider()
            HStack {
                Button { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) } label: {
                    Label("Settings…", systemImage: "slider.horizontal.3")
                }.keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 310)
    }
}

@main struct LidscapeApp: App {
    @StateObject private var model = FoldModel()
    var body: some Scene {
        Window("Lidscape", id: "settings") { SettingsView(model: model) }.windowResizability(.contentSize)
        MenuBarExtra {
            LidscapeMenu(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "laptopcomputer")
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(model.menuStatusColor)
            }.help("Lidscape · " + model.menuStatus)
                .accessibilityLabel("Lidscape · " + model.menuStatus)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(model: model) }
    }
}
