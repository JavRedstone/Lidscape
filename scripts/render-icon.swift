import AppKit
import SceneKit
@main struct RenderIcon {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let suite="Lidscape.icon."+UUID().uuidString
  let prefs=UserDefaults(suiteName:suite)!
  defer { prefs.removePersistentDomain(forName:suite) }
  let model=FoldModel(preferences:prefs)
  let view=MacBookPreview(frame:NSRect(x:0,y:0,width:1024,height:1024))
  view.fadeStrength=0.35
  view.update(progress:0.22,source:model.artwork,reference:90,geometry:model.geometry,sideView:false,blurStrength:1,model:"Simple")
  view.backgroundColor = .clear
  view.scene?.background.contents = NSColor.clear
  view.pointOfView?.position=SCNVector3(0,360,740)
  view.pointOfView?.look(at:SCNVector3(0,85,35))
  let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
  renderer.scene = view.scene; renderer.pointOfView = view.pointOfView
  renderer.autoenablesDefaultLighting = true
  let image=renderer.snapshot(atTime: 0, with: NSSize(width:1024,height:1024), antialiasingMode:.multisampling4X)
  let pixels = NSBitmapImageRep(data: image.tiffRepresentation!)!
  var left=pixels.pixelsWide, right=0, top=pixels.pixelsHigh, bottom=0
  for y in 0..<pixels.pixelsHigh { for x in 0..<pixels.pixelsWide {
   if (pixels.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0.01 {
    left=min(left,x); right=max(right,x); top=min(top,y); bottom=max(bottom,y)
   }
  } }
  let crop=pixels.cgImage!.cropping(to:CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1))!
  let cropped=NSImage(cgImage:crop,size:NSSize(width:crop.width,height:crop.height))
  let factor=900 / max(cropped.size.width,cropped.size.height)
  let size=NSSize(width:cropped.size.width*factor,height:cropped.size.height*factor)
  let icon=NSImage(size:NSSize(width:1024,height:1024))
  icon.lockFocus()
  cropped.draw(in:NSRect(x:(1024-size.width)/2,y:(1024-size.height)/2,width:size.width,height:size.height))
  icon.unlockFocus()
  try NSBitmapImageRep(data:icon.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"Resources/AppIcon/AppIcon.png"))
 }
}
