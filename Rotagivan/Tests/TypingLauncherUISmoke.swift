import AppKit
@main struct TypingLauncherUISmoke {
 @MainActor static func main() async throws {
  _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
  await VoiceApplicationIndex.shared.load()
  precondition(VoiceApplicationIndex.shared.applications.contains { $0.bundleID == "com.apple.finder" }, "Finder should be part of type-to-find")
  let folderFixture = URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("folder-catalog-fixture", isDirectory:true)
  let projects = folderFixture.appendingPathComponent("Documents/Client Projects", isDirectory:true)
  try FileManager.default.createDirectory(at:projects, withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:folderFixture) }
  let foundFolders = ExplorerFolderCatalog.scan(home:folderFixture)
  precondition(foundFolders.contains { $0.url == projects.standardizedFileURL }, "Visible child folders should be indexed")
  let matchingFolders = LauncherAction.search("client projects", actions:LauncherAction.folders(foundFolders))
  precondition(matchingFolders.first?.name == "Client Projects", "Folder names should be searchable")
  let applicationFolders = LauncherAction.search("Applications", actions:LauncherAction.folders(foundFolders))
  precondition(applicationFolders.contains { if case .folder(let folder) = $0.target { return folder.url.path == "/Applications" }; return false }, "Applications should be a searchable folder")
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
  let tabActions = LauncherAction.chromeTabs([
   ChromeRecentTab(windowIndex:1,tabIndex:1,title:"Alpha panel",url:"https://alpha.example/"),
   ChromeRecentTab(windowIndex:1,tabIndex:2,title:"Beta dashboard",url:"https://beta.example/")
  ])
  let tabResults = LauncherAction.search("chrome",actions:tabActions)
  precondition(tabResults.map(\.name) == ["Chrome tab · Alpha panel","Chrome tab · Beta dashboard"],"Chrome tabs remain listed in window/tab order")
  var settingsOpened = false
  controller.onSettings = { settingsOpened = true }
  controller.show(waitingForLift:false)
  precondition(controller.processLayerKey(key(44,"/")),"Slash should open settings")
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(settingsOpened && !controller.isVisible,"Slash opens settings without consuming a search character")
  controller.frontmostPID = { 999_999 }
  controller.frontmostBundleID = { nil }
  controller.voiceCatalog = { [VoiceRegisteredAction(action: .command(.syncSettings), detail: "Sync fixture")] }
  var dispatched: [BindingAction] = []
  controller.onKeyboardBindingAction = { dispatched.append($0) }
  controller.show(waitingForLift:false)
  precondition(controller.processLayerKey(key(0,"sync settings")))
  precondition(controller.displayedLauncherActions.first?.name == "Sync settings")
  precondition(controller.processLayerKey(key(36)))
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(dispatched == [.command(.syncSettings)] && !controller.isVisible,
               "One Return confirms and executes a selected action, without a second confirmation")
  controller.showWindowManager(waitingForLift:false)
  _ = controller.processLayerKey(key(0,"s"))
  precondition(controller.displayedLauncherQuery.isEmpty,"Window Manager retains its key routing")
  controller.dismiss()
  print("Native launcher: immediate key focus, rapid typing, ranking, navigation, injected safe launch, reopen reset, Unicode backspace, empty Enter, Escape, and Window Manager isolation passed")
 }
}
