import AppKit

@MainActor final class MockRealtimeTransport: RealtimeVoiceTransport {
    var callback: ((RealtimeStreamEvent)->Void)?
    var uploaded = Data(), commits = 0, closed = false
    var automaticFinal = true
    var sendReady = true
    func start(onEvent: @escaping (RealtimeStreamEvent)->Void) async throws { callback=onEvent; if sendReady { onEvent(.ready) } }
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
@main struct RealtimeLauncherTests {
 @MainActor static func eventually(_ condition: ()->Bool) async throws {
    for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds:1_000_000) }
    precondition(condition(),"Async fixture did not drain")
 }
 @MainActor static func main() async throws {
    precondition(OpenAIRealtimeCredential.parse("OTHER_KEY=hidden\nexport OPENAI_ROTA_KEY='fixture-not-a-real-key'") == "fixture-not-a-real-key")
    precondition(OpenAIRealtimeCredential.parse("OPENAI_ROTA_KEY=$(cat secret)") == "$(cat")
    let config = OpenAIRealtimeTransport.sessionUpdate
    let sessionConfig = config["session"] as! [String:Any]
    precondition(sessionConfig["type"] as? String == "transcription")
    precondition(!String(describing:config).contains("response.create"))
    var parser = RealtimeTranscriptAccumulator()
    precondition(parser.accept(["type":"session.updated"]) == .ready)
    precondition(parser.accept(["type":"input_audio_buffer.committed","item_id":"a"]) == nil)
    precondition(parser.accept(["type":"conversation.item.input_audio_transcription.delta","item_id":"a","event_id":"1","delta":"Open Sa"]) == .transcript("Open Sa",final:false))
    precondition(parser.accept(["type":"conversation.item.input_audio_transcription.delta","item_id":"a","event_id":"1","delta":"Open Sa"]) == nil)
    precondition(parser.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Open Safari"]) == .transcript("Open Safari",final:true))
    precondition(parser.accept(["type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"late"]) == nil)
    _ = parser.accept(["type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"])
    precondition(parser.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"settings"]) == .transcript("Open Safari settings",final:true))
    if case .failure(let message) = parser.accept(["type":"error","error":["message":"fixture-secret"]]) {
        precondition(!message.contains("fixture-secret"))
    } else { preconditionFailure("Errors must be surfaced without provider echo") }
    let transport=MockRealtimeTransport(), mic=MockRealtimeMicrophone(), voice=RealtimeLauncherSession()
    let gate=VoiceMicrophoneAdmission()
    voice.admission=gate; voice.automaticTicks=false
    voice.makeTransport={transport}; voice.makeMicrophone={mic}; voice.requestPermission={true}
    var deltas:[String]=[]; voice.onTranscript={deltas.append($0)}
    voice.start(); try await eventually { voice.phase == .listening }
    precondition(mic.starts == 1 && gate.occupied)
    transport.callback?(.transcript("Open Sa",final:false))
    precondition(deltas.last == "Open Sa")
    mic.buffer.append(Data(repeating:1,count:9600),rms:0.1)
    voice.tick(); try await eventually { transport.uploaded.count == 9600 }
    voice.tick(); await Task.yield(); precondition(transport.uploaded.count == 9600,"PCM must not be resent per tick")
    voice.finish(); try await eventually { voice.phase == .ready }
    precondition(transport.commits == 1 && transport.closed && !gate.occupied && mic.stops > 0)
    precondition(deltas.last == "Open Safari")
    transport.callback?(.transcript("late old session",final:false))
    precondition(deltas.last == "Open Safari","Closed sessions cannot replace a final transcript")
    let denied=RealtimeLauncherSession(), deniedTransport=MockRealtimeTransport(), deniedMic=MockRealtimeMicrophone()
    denied.automaticTicks=false; denied.admission=VoiceMicrophoneAdmission(); denied.makeTransport={deniedTransport}; denied.makeMicrophone={deniedMic}; denied.requestPermission={false}
    denied.start(); try await eventually { denied.phase == .failed }
    precondition(deniedMic.starts == 0 && deniedTransport.closed)
    let privacy=RealtimeLauncherSession(), privacyTransport=MockRealtimeTransport(), privacyMic=MockRealtimeMicrophone(), privacyGate=VoiceMicrophoneAdmission()
    privacy.automaticTicks=false; privacy.admission=privacyGate; privacy.makeTransport={privacyTransport}; privacy.makeMicrophone={privacyMic}; privacy.requestPermission={true}
    privacy.start(); try await eventually { privacy.phase == .listening }
    let editor=UUID(); privacyGate.beginPrivateEntry(editor)
    precondition(privacy.phase == .cancelled && privacyTransport.closed && !privacyGate.occupied)
    privacyGate.endPrivateEntry(editor)
    let disconnected=RealtimeLauncherSession(), disconnectTransport=MockRealtimeTransport()
    disconnected.automaticTicks=false; disconnected.admission=VoiceMicrophoneAdmission(); disconnected.makeTransport={disconnectTransport}; disconnected.makeMicrophone={MockRealtimeMicrophone()}; disconnected.requestPermission={true}
    disconnected.start(); try await eventually { disconnected.phase == .listening }
    disconnectTransport.callback?(.failure("Network disconnected"))
    precondition(disconnected.phase == .failed && disconnectTransport.closed)
    // An explicit retry starts a fresh transport; no hidden reconnect or audio replay.
    let retried=MockRealtimeTransport(); disconnected.makeTransport={retried}
    disconnected.start(); try await eventually { disconnected.phase == .listening }
    precondition(disconnected.transcript.isEmpty); disconnected.cancel()
    let clockVoice=RealtimeLauncherSession(); var clock=0.0
    clockVoice.now={clock}; clockVoice.automaticTicks=false; clockVoice.admission=VoiceMicrophoneAdmission()
    clockVoice.makeTransport={ throw VoiceError.message("No key") }
    clockVoice.start(); try await eventually { clockVoice.phase == .failed }
    precondition(!clockVoice.admission.occupied)
    clock=100; clockVoice.tick()
    let pending=RealtimeLauncherSession(), pendingGate=VoiceMicrophoneAdmission(), pendingTransport=MockRealtimeTransport()
    var permission:CheckedContinuation<Bool,Never>?
    pending.admission=pendingGate; pending.automaticTicks=false; pending.makeTransport={pendingTransport}
    pending.requestPermission={await withCheckedContinuation { permission=$0 }}
    pending.start(); try await eventually { permission != nil }
    pending.cancel(); precondition(pendingGate.occupied,"Keep microphone lease until pending permission returns")
    permission!.resume(returning:true); try await eventually { !pendingGate.occupied }
    precondition(pending.phase == .cancelled && pendingTransport.closed)
    let timeout=RealtimeLauncherSession(), timeoutTransport=MockRealtimeTransport(); timeoutTransport.sendReady=false
    var timeoutClock=0.0; timeout.now={timeoutClock}; timeout.automaticTicks=false
    timeout.admission=VoiceMicrophoneAdmission(); timeout.makeTransport={timeoutTransport}; timeout.requestPermission={true}
    timeout.start(); try await eventually { timeoutTransport.callback != nil }
    timeoutClock=11; timeout.tick(); precondition(timeout.phase == .failed && timeoutTransport.closed)
    precondition(LauncherMenuCatalog.scan(pid:ProcessInfo.processInfo.processIdentifier).isEmpty)
    precondition(LauncherMenuCatalog.execute(LauncherMenuAction(pid:-1,indices:[],titles:[])) != nil)
    let app=ExplorerApplication(bundleID:"com.example.safari",name:"Safari",url:URL(fileURLWithPath:"/tmp/Safari.app"))
    let actions=LauncherAction.apps([app])+[.settings,LauncherAction(id:"menu",name:"File → Open",detail:"confirm",target:.menu(LauncherMenuAction(pid:-1,indices:[0],titles:["Open"])))]
    precondition(LauncherAction.search("please open Safari",actions:actions).first?.target == .app(app))
    precondition(LauncherAction.search("Rota settings",actions:actions).first?.target == .rotaSettings)
    let builtIns = VoiceActionRegistry.make(settings: StoredSettings()).filter { $0.enabled && $0.action.kind != .openApp && $0.action.command != .activateVoiceMode }
    let engine=RustApplicationSearch(path:CommandLine.arguments[1]); precondition(engine.isAvailable)
    let liveApps=ExplorerApplicationCatalog.scan()
    let fixtureMenus=(0..<200).map { i in LauncherAction(id:"menu-fixture-\(i)",name:"File Menu Action \(i)",detail:"Synthetic menu",target:.menu(LauncherMenuAction(pid:-1,indices:[i],titles:["Action \(i)"]))) }
    let benchmarkActions=LauncherAction.apps(liveApps)+[.settings]+LauncherAction.registered(builtIns)+fixtureMenus
    var samples:[Double]=[]
    for i in 0..<1000 {
        let start=CFAbsoluteTimeGetCurrent()
        _=LauncherAction.search(["open Safari","settings","volume","file action","missing"][i%5],actions:benchmarkActions,engine:engine)
        samples.append((CFAbsoluteTimeGetCurrent()-start)*1000)
    }
    samples.sort()
    print("Full Rust action query: \(benchmarkActions.count) entries (200 synthetic menus), median \(samples[500])ms p95 \(samples[950])ms max \(samples[999])ms; excludes rendering/network")
    print("Default reusable Mac action catalog: \(builtIns.count) actions; Chrome-only additions: \(VoiceActionRegistry.chromeDefaults.count); Slack-only additions: \(VoiceActionRegistry.slackDefaults.count)")
    print("Realtime mocks passed: config, key-name parser, deltas/finals/order/dedup, redacted errors, PCM streaming without replay, final commit, mic denial, private-note cancellation, disconnect/retry, missing key, local action routing, menu unavailability.")
 }
}
