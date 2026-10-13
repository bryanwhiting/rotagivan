import AppKit

@MainActor final class MockRealtimeTransport: RealtimeVoiceTransport {
    var callback: ((RealtimeStreamEvent)->Void)?
    var uploaded = Data(), commits = 0, closed = false
    var automaticFinal = true
    func start(onEvent: @escaping (RealtimeStreamEvent)->Void) async throws { callback=onEvent; onEvent(.ready) }
    func append(_ pcm:Data) async throws { uploaded.append(pcm) }
    func commit() async throws { commits += 1; if automaticFinal { callback?(.transcript("Open Safari",final:true)) } }
    func close() { closed = true }
}
@MainActor final class MockRealtimeMicrophone: VoiceAudioCapturing {
    let buffer = VoiceAudioBuffer(maximumBytes:576000)
    var starts=0, stops=0
    func start() throws { starts += 1 }
    func stop() { stops += 1 }
}
@main struct RealtimeLauncherUISmoke {
 @MainActor static func wait(_ condition:()->Bool) async throws {
    for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds:1_000_000) }
    precondition(condition())
 }
 @MainActor static func main() async throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    await VoiceApplicationIndex.shared.load()
    precondition(RustApplicationSearch.shared.isAvailable)
    let suite="Rotagivan.RealtimeSmoke."+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    let controller=AppExplorerController(defaults:defaults)
    controller.configuration={AppExplorerSettings()}; controller.microphoneAdmission=VoiceMicrophoneAdmission()
    let service=MockRealtimeTransport(), mic=MockRealtimeMicrophone(), voice=RealtimeLauncherSession()
    voice.automaticTicks=false; voice.makeTransport={service}; voice.makeMicrophone={mic}; voice.requestPermission={true}
    controller.makeRealtimeSession={voice}; controller.useRealtimeVoice={true}
    var opened:URL?
    controller.openApplication={url,_,completion in opened=url;completion(nil)}
    controller.show(waitingForLift:false); controller.activateVoiceMode()
    try await wait { voice.phase == .listening }
    service.callback?(.transcript("open Sa",final:false))
    service.callback?(.transcript("open Safari",final:false))
    precondition(controller.displayedLauncherActions.first?.name == "Safari")
    precondition(opened == nil && controller.isVisible,"Speech must not launch anything")
    let window=NSApp.windows.first{$0.title == "App Explorer"}!
    precondition(window.isKeyWindow)
    let content=window.contentView!; content.layoutSubtreeIfNeeded()
    let image=content.bitmapImageRepForCachingDisplay(in:content.bounds)!
    content.cacheDisplay(in:content.bounds,to:image)
    try image.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    func key(_ code:UInt16,_ text:String="")->NSEvent {
       NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    precondition(controller.processLayerKey(key(36)))
    try await wait { opened != nil }
    precondition(opened?.lastPathComponent == "Safari.app" && service.closed && !controller.isVisible)
    service.callback?(.transcript("stale words",final:false))
    precondition(controller.displayedLauncherQuery.isEmpty)
    controller.useRealtimeVoice={false}
    let record=VoiceRegisteredAction(action:.command(.showDesktop),detail:"Synthetic action",actionName:"Fixture action")
    var records=[record]; controller.voiceCatalog={records}
    var executions=0; controller.onKeyboardBindingAction={_ in executions += 1}
    controller.show(waitingForLift:false)
    precondition(controller.processLayerKey(key(0,"Fixture action")))
    precondition(controller.displayedLauncherActions.first?.target == .registered(record.id))
    precondition(controller.processLayerKey(key(36)))
    precondition(executions == 0 && controller.isVisible,"First Return confirms only")
    let repeatedReturn=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:true,keyCode:36)!
    precondition(controller.processLayerKey(repeatedReturn))
    precondition(executions == 0 && controller.isVisible,"Holding Return cannot confirm")
    records=[]
    precondition(controller.processLayerKey(key(36)))
    precondition(executions == 0 && controller.isVisible,"Changed actions must never execute")
    controller.dismiss(); records=[record]
    controller.show(waitingForLift:false)
    precondition(controller.processLayerKey(key(0,"Fixture action")))
    precondition(controller.processLayerKey(key(36)))
    precondition(executions == 0)
    precondition(controller.processLayerKey(key(36)))
    try await wait { executions == 1 }
    precondition(!controller.isVisible)
    print("Native mocked Realtime HUD passed incremental Rust search, focus, no speech execution, deliberate injected launch, cancellation/stale deltas, double-Return confirmation, stale action rejection, and one-shot injected execution.")
 }
}
