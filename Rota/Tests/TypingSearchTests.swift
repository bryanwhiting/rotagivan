import AppKit
@main struct Tests {
 static func main() {
  let search = RustApplicationSearch(path: CommandLine.arguments[1]); precondition(search.isAvailable)
  let apps = [ExplorerApplication(bundleID:"com.safari.helper",name:"Safari Helper",url:URL(fileURLWithPath:"/tmp/helper.app")),ExplorerApplication(bundleID:"com.apple.safari",name:"Safari",url:URL(fileURLWithPath:"/tmp/Safari.app")),ExplorerApplication(bundleID:"com.cafe",name:"Café 東京",url:URL(fileURLWithPath:"/tmp/cafe.app")),ExplorerApplication(bundleID:"com.chrome.profile1",name:"Safari",url:URL(fileURLWithPath:"/tmp/profile1/Safari.app"))]
  precondition(search.search("SAFARI",applications:apps).map(\.id) == [apps[1].id,apps[3].id,apps[0].id])
  precondition(search.search("cafe 東京",applications:apps).first == apps[2])
  precondition(search.search("sfr",applications:apps).first == apps[1])
  precondition(search.search("none",applications:apps).isEmpty)
  precondition(search.search("safari",applications:Array(apps.prefix(1))).count == 1)
  let live = ExplorerApplicationCatalog.scanWithStatus(); precondition(live.errors.isEmpty)
  var samples:[Double]=[]
  for i in 0..<1000 { let start=CFAbsoluteTimeGetCurrent(); _=search.search(["safari","chr","gdrive","cafe","missing"][i % 5],applications:live.applications); samples.append((CFAbsoluteTimeGetCurrent()-start)*1000) }
  samples.sort(); print("Swift→Rust cached queries: \(live.applications.count) installed apps, median \(samples[500])ms p95 \(samples[950])ms max \(samples[999])ms (includes initial indexing)")
  print("Chrome/Safari app bundles: \(live.applications.filter{$0.url.path.contains("Chrome Apps") || $0.bundleID.contains("Safari.WebApp")}.map(\.name))")
  print("Typing search bridge assertions passed")
 }
}
