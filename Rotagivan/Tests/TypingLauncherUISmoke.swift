import AppKit
@main struct TypingLauncherUISmoke {
 @MainActor static func main() async throws {
  _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
  await VoiceApplicationIndex.shared.load()
  let suite = "Rotagivan.TypingSmoke." + UUID().uuidString
  let defaults = UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  precondition(RustApplicationSearch.shared.isAvailable, "Native UI must load the bundled Rust engine")
  let controller = AppExplorerController(defaults:defaults)
  controller.configuration = { AppExplorerSettings() }
  func key(_ code:UInt16,_ text:String="",_ modifiers:NSEvent.ModifierFlags=[]) -> NSEvent {
   NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
  }
  controller.show(waitingForLift:false)
  let panel = NSApp.windows.first{$0.title == "App Explorer"}!
  precondition(panel.isKeyWindow,"Launcher must immediately receive keyboard input")
  for ch in "safari" { precondition(controller.processLayerKey(key(0,String(ch)))) }
  precondition(controller.displayedLauncherQuery == "safari")
  precondition(controller.displayedLauncherResults.first?.name == "Safari")
  precondition(controller.processLayerKey(key(125)))
  precondition(controller.displayedLauncherSelection == min(1,controller.displayedLauncherActions.count-1))
  precondition(controller.processLayerKey(key(126)))
  precondition(controller.displayedLauncherSelection == 0)
  panel.contentView!.layoutSubtreeIfNeeded()
  let content = panel.contentView!
  let image = content.bitmapImageRepForCachingDisplay(in:content.bounds)!
  content.cacheDisplay(in:content.bounds,to:image)
  try image.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  var opened:URL?
  controller.openApplication = { url, _, completion in opened=url; completion(nil) }
  precondition(controller.processLayerKey(key(36)))
  precondition(!controller.isVisible)
  await Task.yield()
  try await Task.sleep(nanoseconds: 100_000_000)
  precondition(opened?.lastPathComponent == "Safari.app")
  controller.show(waitingForLift:false)
  precondition(controller.displayedLauncherQuery.isEmpty)
  precondition(controller.displayedLauncherResults.isEmpty)
  precondition(controller.processLayerKey(key(0,"東京")))
  precondition(controller.displayedLauncherQuery == "東京")
  precondition(controller.processLayerKey(key(51)))
  precondition(controller.displayedLauncherQuery == "東")
  precondition(controller.processLayerKey(key(51)))
  precondition(controller.displayedLauncherQuery.isEmpty)
  precondition(controller.processLayerKey(key(0,"notanapp")))
  precondition(controller.displayedLauncherResults.isEmpty)
  precondition(controller.processLayerKey(key(36)))
  precondition(controller.isVisible)
  precondition(controller.processLayerKey(key(53)))
  precondition(!controller.isVisible)
  controller.showWindowManager(waitingForLift:false)
  _ = controller.processLayerKey(key(0,"s"))
  precondition(controller.displayedLauncherQuery.isEmpty,"Window Manager retains its key routing")
  controller.dismiss()
  print("Native launcher: immediate key focus, rapid typing, ranking, navigation, injected safe launch, reopen reset, Unicode backspace, empty Enter, Escape, and Window Manager isolation passed")
 }
}
