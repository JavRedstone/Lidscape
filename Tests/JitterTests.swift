import Foundation
@main struct JitterTests {
 static func main() {
  var filter=LidAngleFilter()
  var gate=FoldThreshold()
  for tick in 0..<240 {
   let raw=90 + (tick%2 == 0 ? 0.8 : -0.8)
   let angle=filter.update(raw,now:Double(tick)/60)
   precondition(!gate.update(angle:angle,threshold:90), "Noise must not enter the effect")
  }
  for tick in 240..<280 {_=gate.update(angle:filter.update(86,now:Double(tick)/60),threshold:90)}
  precondition(gate.active)
  for tick in 280..<400 {
   let raw=90 + (tick%2 == 0 ? 0.8 : -0.8)
   precondition(gate.update(angle:filter.update(raw,now:Double(tick)/60),threshold:90), "Noise must not exit the effect")
  }
  for tick in 400..<440 {_=gate.update(angle:filter.update(95,now:Double(tick)/60),threshold:90)}
  precondition(!gate.active)
  var spikes=LidAngleFilter()
  for tick in 0..<10 {_=spikes.update(100,now:Double(tick)/60)}
  precondition(abs(spikes.update(40,now:10.0/60)!-100)<0.001)
  precondition(spikes.update(nil,now:11.0/60) != nil)
  precondition(spikes.update(nil,now:1) == nil)
  var hold=HoldResetState()
  for tick in 0..<240 {
   precondition(hold.update(angle:60,now:Double(tick)/60,delay:1,enabled:false)==0)
  }
  hold.rearm()
  for tick in 240..<340 {_=hold.update(angle:60,now:Double(tick)/60,delay:1)}
  precondition(hold.amount==1)
  let fading=hold.update(angle:60,now:341.0/60,delay:1,enabled:false)
  precondition(fading>0 && fading<1)
  var minimumGate = ResetAngleGate()
  precondition(minimumGate.update(angle:40,minimum:30))
  precondition(!minimumGate.update(angle:29.9,minimum:30))
  for angle in [30.1,29.8,30.2,30.8] { precondition(!minimumGate.update(angle:angle,minimum:30)) }
  precondition(minimumGate.update(angle:32,minimum:30))
  precondition(!minimumGate.update(angle:35,minimum:40))
  var conditional=HoldResetState()
  for tick in 0..<300 { _=conditional.update(angle:20,now:Double(tick)/60,delay:1,enabled:false) }
  precondition(conditional.amount==0)
  for tick in 300..<359 { precondition(conditional.update(angle:40,now:Double(tick)/60,delay:1,enabled:true)==0) }
  var unrestrictedHold = HoldResetState()
  for tick in 0..<120 { _ = unrestrictedHold.update(angle:10,now:Double(tick)/60,delay:1,enabled:true) }
  precondition(unrestrictedHold.amount == 1, "Hold reset must work below the calibration minimum")
  print("PASS: no threshold chatter, genuine crossings, isolated spike rejection, missing-report grace, optional hold reset")
 }
}
