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
        print("PASS: live frame replacement, static desktop, suspended/blank/stopped invalidation, fresh-frame resume, late callback rejection")
    }
}
