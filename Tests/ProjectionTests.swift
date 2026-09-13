import AppKit
import CoreImage

@main struct ProjectionTests {
    @MainActor static func main() {
        let size = 128
        // A coordinate-encoded source tests the actual GPU kernel, not a copy
        // of its mapping: red encodes horizontal position, green vertical.
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            pixels[(y * size + x) * 4] = UInt8(x * 2)
            pixels[(y * size + x) * 4 + 1] = UInt8(y * 2)
        } }
        let source = CIImage(bitmapData: Data(pixels), bytesPerRow: size * 4,
                             size: CGSize(width: size, height: size), format: .RGBA8, colorSpace: nil)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var checks = 0
        for height in [195.0, 225.0] { for distance in [350.0, 550.0, 900.0] {
            for degrees in [90.0, 75.0, 60.0, 30.0, 5.0] {
                let a = degrees * Double.pi / 180
                let image = FoldCanvas.projection.apply(extent: source.extent, roiCallback: { _, _ in source.extent },
                    arguments: [source, 301.0, height, distance, 300.0, a, Double.pi / 2, 128.0, 128.0])!
                var output = [UInt8](repeating: 0, count: pixels.count)
                context.render(image, toBitmap: &output, rowBytes: size * 4, bounds: source.extent, format: .RGBA8, colorSpace: nil)
                for y in [8, 32, 64, 100] { for x in [16, 64, 112] {
                    // Independent closed-form perspective intersection at z=0.
                    let panelY = (127.5 - Double(y)) / 128 * height
                    let z = panelY * cos(a)
                    let magnification = distance / (distance - z)
                    let u = ((Double(x) + 0.5) / 128 - 0.5) * magnification + 0.5
                    let v = (300 + (panelY * sin(a) - 300) * magnification) / height
                    let index = (y * size + x) * 4
                    if u < 0 || u > 1 || v < 0 || v > 1 {
                        precondition(output[index + 3] == 0, "Outside-plane ray must be transparent")
                    } else {
                        precondition(abs(Double(output[index]) - (u * 128 - 0.5) * 2) < 3, "Horizontal mismatch actual=\(output[index]) expected=\((u * 128 - 0.5) * 2) x=\(x) y=\(y) angle=\(degrees)")
                        precondition(abs(Double(output[index + 1]) - ((1 - v) * 128 - 0.5) * 2) < 3, "Vertical perspective mismatch")
                    }
                    checks += 1
                } }
            }
        } }
        print("PASS: \(checks) GPU samples across angles, display sizes and viewing distances")
    }
}
