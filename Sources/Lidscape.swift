import AppKit
import SwiftUI
import SceneKit
import MetalKit
import IOKit.hid
import ScreenCaptureKit
import CoreImage.CIFilterBuiltins

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
    private var wasEnabled: Bool?
    mutating func rearm() { anchor = nil }
    mutating func update(angle: Double, now: Double, delay: Double, moving: Bool = false, enabled: Bool = true) -> Double {
        let dt = min(0.1, max(0, now - (lastTime ?? now)))
        lastTime = now
        if wasEnabled != enabled { anchor = nil; wasEnabled = enabled }
        if anchor == nil || abs(angle - anchor!) > 1.5 {
            anchor = angle; heldSince = now
        }
        let target = enabled && !moving && now - heldSince >= delay ? 1.0 : 0.0
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
    private var cachedSource: CIImage?
    private var resizedSource: CIImage?
    private var sourceWidth = 0
    private(set) var lastGPUSeconds = 0.0
    init(device: MTLDevice = MTLCreateSystemDefaultDevice()!, queue: MTLCommandQueue? = nil) {
        self.device = device; self.queue = queue ?? device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: true])
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
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
        }
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

final class MetalFoldView: MTKView, MTKViewDelegate {
    var fadeStrength = 0.0 { didSet { gpu.fadeStrength = fadeStrength } }
    var source: CIImage?
    var progress = 0.0
    var resetAmount = 0.0
    var blurStrength = 1.0
    var referenceDegrees = 90.0
    var geometry = ViewingGeometry()
    private let gpu = FoldGPU()
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
        let link = display.displayLink(target: self, selector: #selector(animatePreview))
        let rate = Float(display.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        animationLink = link
    }
    @objc private func animatePreview(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, now - animationTime); animationTime = now
        animationFrame?(dt)
    }
    private let lid = SCNNode()
    private let screen = SCNNode()
    private let cameraNode = SCNNode()
    private let inspectionCamera = SCNNode()
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
        var hingeWorld = baked ? SCNVector3(0, 0.65, bottom.z + 0.39) : lidClone.convertPosition(SCNVector3Zero, to: nil)
        if !baked { hingeWorld.y += 0.7 }
        if selectedModel == "MacBookPro14" {
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
        let closedY = lidVertices.map { Double($0.y) * c - Double($0.z) * sn }
        let closedZ = lidVertices.map { Double($0.y) * sn + Double($0.z) * c }
        let baseZ = baseVertices.map { Double($0.z) }
        let shiftY = baseVertices.map { Double($0.y) }.max()! + 0.02 - closedY.min()!
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
        let panel = SCNPlane(width: w, height: h)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        panel.materials = [material]
        screen.geometry = panel
        screen.position = SCNVector3(0, h / 2, 0.1)
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
            activeCamera.look(at: SCNVector3(0, geometry.height * 0.40, geometry.height * 0.18),
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

@MainActor final class FoldModel: NSObject, ObservableObject {
    private let preferences: UserDefaults
    private var settingsReady = false
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
    @Published var fadeStrength = 0.5 { didSet { saveSettings() } }
    private func saveSettings() {
        guard settingsReady else { return }
        preferences.set([
            "model": previewModel, "color": previewColor, "showDockIcon": showDockIcon,
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
        if let model = values["model"] as? String, ["MacBookPro14", "MacBookAir13", "MacBookAir15", "Simple"].contains(model) { previewModel = model }
        if let color = values["color"] as? String, availableColors.contains(color) { previewColor = color }
        geometry.distance = number("distance", 550, 300...1000)
        geometry.eyeHeight = number("eyeHeight", 300, -600...3000)
        trigger = number("trigger", 90, 35...150)
        smoothing = number("smoothing", 0.055, 0.025...0.14)
        blurStrength = number("blur", 1, 0...2); fadeStrength = number("fade", 0.5, 0...2)
        holdToReset = values["hold"] as? Bool ?? true
        holdDelay = number("holdDelay", 1, 0.5...3)
        autoCalibrate = values["auto"] as? Bool ?? false
        autoCalibrationDelay = number("autoDelay", 1, 0.5...8)
        minimumCalibrationAngle = number("minimum", 30, 0...120)
        eyeRelativePreview = values["eyeRelative"] as? Bool ?? false
        showDockIcon = values["showDockIcon"] as? Bool ?? true
    }
    let hardwareIdentifier = MacHardware.identifier
    func useDetectedModel() {
        if let match = MacHardware.previewModel(for: hardwareIdentifier) { previewModel = match }
    }
    func resetSettings() {
        setEnabled(false)
        showDockIcon = true
        geometry = ViewingGeometry(); refreshDisplaySize()
        trigger = 90; smoothing = 0.055; blurStrength = 1; fadeStrength = 0.5
        holdToReset = true; holdDelay = 1
        autoCalibrate = false; autoCalibrationDelay = 1; minimumCalibrationAngle = 30
        eyeRelativePreview = false; preview = 0; previewEditing = false; previewPlaying = false
        previewHold = HoldResetState(); lidHold = HoldResetState(); previewReset = 0
        calibrationAngleGate = ResetAngleGate(); foldThreshold = FoldThreshold()
        previewModel = MacHardware.previewModel(for: hardwareIdentifier) ?? "MacBookPro14"
        previewColor = availableColors[0]
        status = "Settings restored to defaults."
    }
    @Published var angle: Double?
    @Published var enabled = false
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
    @Published var trigger = 90.0 { didSet { saveSettings() } }
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
    private var sensor = LidSensor()
    private var angleFilter = LidAngleFilter()
    private var foldThreshold = FoldThreshold()
    private var displayLink: CADisplayLink?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastSensorRead = 0.0
    private var lidSmoothing = SmoothValue()
    @Published var autoCalibrationDelay = 1.0 { didSet { saveSettings() } }
    @Published var autoCalibrate = false {
        didSet { settledCalibration = SettledCalibration(); pendingCalibration = nil; saveSettings() }
    }
    private var settledCalibration = SettledCalibration()
    private var pendingCalibration: Double?
    @Published var smoothing = 0.055 { didSet { saveSettings() } }
    @Published var refreshRate = 60
    private var overlay: NSWindow?
    private var canvas: MetalFoldView?
    private var capturing = false
    private var generation = 0
    private var progress = 0.0
    private var suspended = false
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        // Bundle original artwork so the preview and app identity share a wallpaper.
        let wallpaperURL = Bundle.main.url(forResource: "Lidscape", withExtension: "png", subdirectory: "Wallpapers")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Wallpapers/Lidscape.png")
        let wallpaper = NSImage(contentsOf: wallpaperURL)
        let image = NSImage(size: NSSize(width: 1200, height: 750), flipped: false) { rect in
            if let wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 {
                let scale = max(rect.width / wallpaper.size.width, rect.height / wallpaper.size.height)
                let size = NSSize(width: wallpaper.size.width * scale, height: wallpaper.size.height * scale)
                wallpaper.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                          width: size.width, height: size.height))
                return true
            }
            // Original flowing-ribbon fallback for video/dynamic wallpapers.
            func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
                NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
            NSGradient(colors: [color(0.025, 0.035, 0.16), color(0.12, 0.10, 0.38), color(0.32, 0.20, 0.58)])!.draw(in: rect, angle: 65)
            for i in 0..<5 {
                let offset = CGFloat(i) * 125
                let ribbon = NSBezierPath()
                ribbon.move(to: NSPoint(x: -150, y: -200 + offset))
                ribbon.curve(to: NSPoint(x: 1350, y: 280 + offset),
                             controlPoint1: NSPoint(x: 380, y: 850 + offset),
                             controlPoint2: NSPoint(x: 720, y: -450 + offset))
                ribbon.line(to: NSPoint(x: 1350, y: 440 + offset))
                ribbon.curve(to: NSPoint(x: -150, y: -40 + offset),
                             controlPoint1: NSPoint(x: 720, y: -290 + offset),
                             controlPoint2: NSPoint(x: 380, y: 1010 + offset))
                ribbon.close()
                let palettes: [[NSColor]] = [
                    [color(0.12, 0.30, 0.85), color(0.35, 0.82, 0.96)],
                    [color(0.20, 0.15, 0.63), color(0.64, 0.55, 0.98)],
                    [color(0.38, 0.18, 0.69), color(0.96, 0.53, 0.74)],
                    [color(0.35, 0.21, 0.73), color(0.66, 0.71, 1.0)],
                    [color(0.13, 0.18, 0.50), color(0.33, 0.57, 0.89)]
                ]
                NSGradient(colors: palettes[i])!.draw(in: ribbon, angle: 85)
            }
            return true
        }
        artwork = CIImage(data: image.tiffRepresentation!)!
        super.init()
        refreshDisplaySize()
        useDetectedModel()
        restoreSettings()
        settingsReady = true
        DispatchQueue.main.async { [weak self] in self?.applyDockPreference() }
        if let screen = NSScreen.screens.first(where: { $0.maximumFramesPerSecond > 60 }) ?? NSScreen.main {
            refreshRate = screen.maximumFramesPerSecond
            let link = screen.displayLink(target: self, selector: #selector(displayTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(80, refreshRate)), maximum: Float(refreshRate), preferred: Float(refreshRate))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = true; self?.hide() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = false; self?.sensor = LidSensor(); self?.angleFilter = LidAngleFilter(); self?.foldThreshold = FoldThreshold() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(); self?.refreshDisplaySize() }
        }
    }
    func calibrateFromLid() {
        guard let current = sensor.read(), (60...150).contains(current) else {
            status = "Calibration needs a sensor reading with the lid between 60° and 150°."; return
        }
        applyCalibration(current)
    }
    private func applyCalibration(_ current: Double) {
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
    func setEnabled(_ value: Bool) {
        enableRequest += 1
        let request = enableRequest
        enabled = false
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
                enabled = true
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
    private func hide() {
        generation += 1
        overlay?.orderOut(nil); overlay = nil; canvas = nil; progress = 0; lidSmoothing = SmoothValue()
    }
    @objc private func displayTick(_ link: CADisplayLink) { tick() }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, now - lastTick); lastTick = now
        if previewPlaying {
            let playback = previewPlayback.advance(dt: dt, holdDelay: holdDelay)
            preview = playback.value
            previewEditing = playback.moving
        }
        let previewAmount = previewHold.update(angle: previewLidAngle, now: now, delay: holdDelay, moving: previewEditing, enabled: holdToReset)
        if previewAmount != previewReset { previewReset = previewAmount }
        if now - lastSensorRead >= 1.0 / 60 {
            lastSensorRead = now
            let reading = angleFilter.update(sensor.read(), now: now)
            if reading != angle { angle = reading }
        }
        let canAutoCalibrate = angle.map { calibrationAngleGate.update(angle: $0, minimum: minimumCalibrationAngle) } ?? false
        if !canAutoCalibrate { pendingCalibration = nil; settledCalibration = SettledCalibration() }
        if autoCalibrate && !suspended && canAutoCalibrate {
            if let settled = settledCalibration.update(angle: angle, now: now, delay: autoCalibrationDelay) { pendingCalibration = settled }
            if let pending = pendingCalibration {
                if let angle, abs(angle - pending) > 1.5 { pendingCalibration = nil }
                else if overlay == nil || lidHold.amount == 1 {
                    pendingCalibration = nil; applyCalibration(pending)
                }
            }
        }
        guard enabled, !suspended, let angle else {
            foldThreshold = FoldThreshold()
            if overlay != nil { hide() }
            return
        }
        let target = min(1, max(0, (trigger - angle) / trigger))
        guard foldThreshold.update(angle: angle, threshold: trigger) else {
            lidHold = HoldResetState()
            if overlay != nil || capturing { hide() }
            return
        }
        let reset = lidHold.update(angle: angle, now: now, delay: pendingCalibration == nil ? holdDelay : 0, enabled: holdToReset || pendingCalibration != nil)
        if reset == 1 { if overlay != nil { hide() }; return }
        progress = lidSmoothing.advance(to: target, dt: dt, response: smoothing)
        if let canvas { canvas.resetAmount = reset; canvas.blurStrength = blurStrength; canvas.fadeStrength = fadeStrength; canvas.geometry = geometry; canvas.referenceDegrees = trigger; canvas.progress = progress; canvas.draw(); return }
        guard !capturing, target > 0 else { return }
        capturing = true
        let token = generation
        Task {
            defer { capturing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
                      let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else {
                    status = "No built-in MacBook display found."; return
                }
                let config = SCStreamConfiguration()
                config.width = display.width; config.height = display.height; config.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard enabled, !suspended, lidHold.amount < 1, generation == token, foldThreshold.active, let latest = self.angle, latest < trigger + 1.5 else { return }
                let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.level = .screenSaver
                window.ignoresMouseEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                let view = MetalFoldView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.resetAmount = lidHold.amount; view.blurStrength = blurStrength; view.fadeStrength = fadeStrength
                view.geometry = geometry; view.source = CIImage(cgImage: shot); view.referenceDegrees = trigger; view.progress = progress
                window.contentView = view
                overlay = window; canvas = view
                window.orderFrontRegardless()
                view.draw()
            } catch {
                enabled = false; hide(); needsScreenPermission = !CGPreflightScreenCaptureAccess(); status = "Screen capture failed: \(error.localizedDescription)"
            }
        }
    }
}

struct SettingsView: View {
    @State private var sideView = false
    @ObservedObject var model: FoldModel
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Lidscape").font(.title.bold())
                Spacer()
                Text(model.angle.map { "Lid \(Int($0))°" } ?? "No lid sensor").foregroundStyle(.secondary).monospacedDigit()
                Toggle("Desktop effect", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })).toggleStyle(.switch)
            }
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.needsScreenPermission {
                    Button("Open Screen Recording") { model.openScreenRecordingSettings() }
                }
                if model.checkingCapture { ProgressView().controlSize(.small) }
            }
            TabView {
                previewTab.tabItem { Label("Preview", systemImage: "laptopcomputer") }
                settingsTab.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            }
        }.padding(20).frame(width: 690, height: min(680, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
    }
    private var previewTab: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Model", selection: $model.previewModel) {
                    Text("MacBook Pro 14″").tag("MacBookPro14")
                    Text("MacBook Air 13″").tag("MacBookAir13")
                    Text("MacBook Air 15″").tag("MacBookAir15")
                    Text("Simple").tag("Simple")
                }
                Picker("Color", selection: $model.previewColor) {
                    ForEach(model.availableColors, id: \.self) { Text($0).tag($0) }
                }.frame(width: 200).disabled(model.previewModel == "Simple")
            }
            HStack {
                Text("Detected Mac: " + model.hardwareIdentifier).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use my Mac") { model.useDetectedModel() }
                    .disabled(MacHardware.previewModel(for: model.hardwareIdentifier) == nil)
            }
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
    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("App behavior") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show Dock icon", isOn: $model.showDockIcon)
                        Text("When off, Lidscape stays in the menu bar. Use its laptop icon to open Settings or quit.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Viewing position") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Distance"); Slider(value: $model.geometry.distance, in: 300...1000, step: 10); Text("\(Int(model.geometry.distance / 10)) cm").frame(width: 65) }
                        Button("Calibrate from current lid") { model.calibrateFromLid() }.disabled(model.angle == nil)
                        Toggle("Auto-calibrate when the lid settles", isOn: $model.autoCalibrate)
                        if model.autoCalibrate {
                            HStack { Text("Calibration delay"); Slider(value: $model.autoCalibrationDelay, in: 0.5...8, step: 0.1); Text(String(format: "%.1f s", model.autoCalibrationDelay)).frame(width: 65) }
                            HStack { Text("Minimum calibration angle"); Slider(value: $model.minimumCalibrationAngle, in: 0...120, step: 1); Text("\(Int(model.minimumCalibrationAngle))°").frame(width: 65) }
                            Text("Physical lid angle. Below this, only auto-calibration is blocked.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Set distance, sit comfortably, then calibrate while looking straight at the screen center.").font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Manual eye height") {
                            HStack { Slider(value: $model.geometry.eyeHeight, in: -600...3000, step: 10); Text("\(Int(model.geometry.eyeHeight / 10)) cm") }
                        }
                        Picker("Preview zero", selection: $model.eyeRelativePreview) {
                            Text("Lid closed").tag(false)
                            Text("Edge-on to eyes").tag(true)
                        }
                    }.padding(8)
                }
                GroupBox("Fold effect") {
                    VStack(spacing: 12) {
                        HStack { Text("Smoothing"); Slider(value: $model.smoothing, in: 0.025...0.14); Text("\(Int(model.smoothing * 1000)) ms").frame(width: 65) }
                        HStack { Text("Blur"); Slider(value: $model.blurStrength, in: 0...2); Text("\(Int(model.blurStrength * 100))%").frame(width: 65) }
                        HStack { Text("Fade to black"); Slider(value: $model.fadeStrength, in: 0...2); Text("\(Int(model.fadeStrength * 100))%").frame(width: 65) }
                        Text("Darkens toward the top as the lid folds. Set to 0% to disable.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Hold to reset", isOn: $model.holdToReset)
                        if model.holdToReset {
                            HStack { Text("Reset delay"); Slider(value: $model.holdDelay, in: 0.5...3, step: 0.1); Text(String(format: "%.1f s", model.holdDelay)).frame(width: 65) }
                        }
                        HStack { Text("Start below"); Slider(value: $model.trigger, in: 35...150, step: 1); Text("\(Int(model.trigger))°").frame(width: 65) }
                    }.padding(8)
                }
                Button("Reset settings") { model.resetSettings(); sideView = false }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Text(model.displaySizeDescription + " · Target \(model.refreshRate) Hz").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }
    }
}

struct LidscapeMenu: View {
    @ObservedObject var model: FoldModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.enabled ? "Pause animation" : "Enable animation") { model.setEnabled(!model.enabled) }
        Button("Open Lidscape…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",")
        Divider()
        Button("Quit Lidscape") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

@main struct LidscapeApp: App {
    @StateObject private var model = FoldModel()
    var body: some Scene {
        Window("Lidscape", id: "settings") { SettingsView(model: model) }.windowResizability(.contentSize)
        MenuBarExtra("Lidscape", systemImage: "laptopcomputer") {
            LidscapeMenu(model: model)
        }
        Settings { SettingsView(model: model) }
    }
}
