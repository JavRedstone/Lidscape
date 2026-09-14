import AppKit
@main struct LifetimeTests {
 @MainActor static func main() {
  _ = NSApplication.shared
  let suite="Lidscape.lifetime."+UUID().uuidString
  let prefs=UserDefaults(suiteName:suite)!
  defer { prefs.removePersistentDomain(forName:suite) }
  weak var modelReference: FoldModel?
  autoreleasepool {
   let model=FoldModel(preferences:prefs)
   modelReference=model
  }
  precondition(modelReference == nil, "Display link retained discarded model")
  for _ in 0..<20 {
   weak var previewReference: MacBookPreview?
   autoreleasepool {
    let view=MacBookPreview(frame:NSRect(x:0,y:0,width:320,height:200))
    previewReference=view
    let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    window.contentView=view
    window.contentView=nil
    window.close()
   }
   precondition(previewReference == nil, "Display link retained discarded preview")
  }
  print("PASS: model and 20 detached previews release their display links")
 }
}
