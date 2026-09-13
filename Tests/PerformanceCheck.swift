import AppKit
import SceneKit
import SwiftUI
final class FrameCounter: NSObject, SCNSceneRendererDelegate {
 let lock = NSLock()
 var stamps:[Double]=[]
 func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
  lock.lock(); stamps.append(ProcessInfo.processInfo.systemUptime); lock.unlock()
 }
}
@MainActor final class Driver: NSObject {
 let view:MacBookPreview
 let model:FoldModel
 let start=ProcessInfo.processInfo.systemUptime
 init(view:MacBookPreview,model:FoldModel) {self.view=view;self.model=model}
 @objc func tick(_ link:CADisplayLink) {
  let t=ProcessInfo.processInfo.systemUptime-start
  model.preview = 0.35+0.3*sin(t*2)
 }
}
@main struct PresentedCheck {
 @MainActor static func main() {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.accessory)
  let model=FoldModel()
  let host = NSHostingView(rootView: SettingsView(model: model))
  host.frame = NSRect(x:0,y:0,width:690,height:680)
  func findPreview(_ root:NSView) -> MacBookPreview? {
   if let preview = root as? MacBookPreview { return preview }
   return root.subviews.compactMap { findPreview($0) }.first
  }
  let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
  window.title="Lidscape performance check";window.contentView=host;window.center();window.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps:true)
  RunLoop.main.run(until:Date().addingTimeInterval(0.5))
  let view = findPreview(host)!
  model.editPreview(true)
  let counter=FrameCounter();view.delegate=counter
  let driver=Driver(view:view,model:model)
  let link=view.displayLink(target:driver,selector:#selector(Driver.tick))
  link.preferredFrameRateRange=CAFrameRateRange(minimum:80,maximum:120,preferred:120)
  link.add(to:.main,forMode:.common)
  RunLoop.main.run(until:Date().addingTimeInterval(8))
  link.invalidate()
  counter.lock.lock();let stamps=counter.stamps.filter{$0>driver.start+2};counter.lock.unlock()
  if let first=stamps.first,let last=stamps.last {
   let intervals=zip(stamps.dropFirst(),stamps).map{($0-$1)*1000}.sorted()
   print("Actual SceneKit render callbacks fps",Double(stamps.count-1)/(last-first),"p95 interval ms",intervals[Int(Double(intervals.count)*0.95)])
  }
  let image=view.snapshot()
  try! NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"build/gpu-preview.png"))
  window.orderOut(nil)
 }
}
