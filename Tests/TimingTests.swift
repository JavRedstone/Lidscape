import Foundation
@main struct TimingTests {
 static func main() {
        var playback = PreviewPlayback(value: 0)
        for _ in 0..<600 { _ = playback.advance(dt: 0.01, holdDelay: 1) }
        precondition(playback.value == 1.0 && playback.pauseRemaining > 0)
        for _ in 0..<600 { _ = playback.advance(dt: 0.01, holdDelay: 1) }
        precondition(playback.value == 0 && playback.pauseRemaining > 0)

  var hold = HoldResetState()
  for step in 0...240 { _ = hold.update(angle: 70, now: Double(step)/120, delay: 1) }
  precondition(hold.amount == 1)
  // Capture latency must not consume the return transition offscreen.
  for step in 241...300 {
   precondition(hold.update(angle: 60, now: Double(step)/120, delay: 1, canRenderReturn: false) == 1)
   precondition(hold.resuming)
  }
  let firstVisible = hold.update(angle: 60, now: 301.0/120, delay: 1)
  precondition(firstVisible > 0.8 && firstVisible < 1)
  let nextVisible = hold.update(angle: 60, now: 302.0/120, delay: 1)
  precondition(nextVisible < firstVisible && nextVisible > 0)

  var results:[Double]=[]
  for fps in [30,60,120] {
   var value=SmoothValue()
   for _ in 0..<(fps/5) { _=value.advance(to:1,dt:1/Double(fps),response:0.055) }
   results.append(value.value)
  }
  precondition(abs(results[0]-results[2])<1e-10 && abs(results[1]-results[2])<1e-10)
  var settle=SettledCalibration()
  for t in 0..<60 {precondition(settle.update(angle:110 + (t%2 == 0 ? 0.3 : -0.3),now:Double(t)/30,delay:2)==nil)}
  precondition(settle.update(angle:110,now:2,delay:2)==110)
  precondition(settle.update(angle:110,now:8,delay:2)==nil)
  precondition(settle.update(angle:115,now:9,delay:2)==nil)
  precondition(settle.update(angle:115,now:11,delay:2)==115)
  precondition(settle.update(angle:nil,now:12,delay:2)==nil)
  var fast=SettledCalibration()
  _=fast.update(angle:110,now:0,delay:0.5)
  precondition(fast.update(angle:110,now:0.5,delay:0.5)==110)
  print("PASS: smoothing independent of refresh rate; independent calibration delay, jitter rejection, once-per-hold and movement rearm")
 }
}
