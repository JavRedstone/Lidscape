import AppKit
import CoreImage
@main struct BlurTests {
 static func main() {
  let size = 256
  var pixels = [UInt8](repeating: 255, count: size * size * 4)
  for y in 0..<size { for x in 0..<size {
   let value: UInt8 = (x / 8) % 2 == 0 ? 0 : 255
   for c in 0..<3 { pixels[(y * size + x) * 4 + c] = value }
  } }
  let input = CIImage(bitmapData: Data(pixels), bytesPerRow: size * 4, size: CGSize(width: size, height: size), format: .RGBA8, colorSpace: nil)
  let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
  var output = pixels
  context.render(FoldCanvas.frost(input, amount: 0.6), toBitmap: &output, rowBytes: size * 4, bounds: input.extent, format: .RGBA8, colorSpace: nil)
  func contrast(_ row: Int) -> Double {
   let values = (32..<224).map { Double(output[(row * size + $0) * 4]) }
   let mean = values.reduce(0,+) / Double(values.count)
   return sqrt(values.map { pow($0 - mean, 2) }.reduce(0,+) / Double(values.count))
  }
  let top = contrast(10), middle = contrast(128), bottom = contrast(245)
  precondition(bottom > middle * 1.2 && middle > top * 2 && top < bottom * 0.1, "Blur gradient bottom=\(bottom) middle=\(middle) top=\(top)")
  context.render(FoldCanvas.frost(input, amount: 0), toBitmap: &output, rowBytes: size * 4, bounds: input.extent, format: .RGBA8, colorSpace: nil)
  precondition(output == pixels, "Reset must restore the sharp image exactly")
  let white = CIImage(color: .white).cropped(to: input.extent)
  let shaded = FoldCanvas.darken.apply(extent: input.extent, arguments: [white, Double(size), 1.0])!
  context.render(shaded, toBitmap: &output, rowBytes: size * 4, bounds: input.extent, format: .RGBA8, colorSpace: nil)
  precondition(output[(10 * size + 128) * 4] < output[(245 * size + 128) * 4], "Fade must be strongest at top")
  let resetFrame = FoldCanvas.frame(source: white, progress: 0.5, referenceDegrees: 90, resetAmount: 1, blurStrength: 0, geometry: ViewingGeometry(), fadeStrength: 2)!
  context.render(resetFrame, toBitmap: &output, rowBytes: size * 4, bounds: input.extent, format: .RGBA8, colorSpace: nil)
  precondition(output[(128 * size + 128) * 4] == 255, "Hold reset must remove fade")
  print("PASS: spatial fade and reset")
  print("PASS: spatial blur contrast bottom/middle/top:",bottom,middle,top)
 }
}
