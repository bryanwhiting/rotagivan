import AppKit
import SwiftUI

@main struct AppOverridesUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "Rotagivan.AppOverridesUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defaults.set(true,forKey:"migration.rotagivan.v1")
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = SettingsStore(defaults:defaults)
        let view = NSHostingView(rootView:AppOverridesView(store:store).padding(24).frame(width:720,height:520).background(Color(nsColor:.windowBackgroundColor)))
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:720,height:520),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.contentView = view
        window.orderFront(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        window.orderOut(nil)
        precondition(store.settings.appOverrides == nil, "Viewing rules must not rewrite preferences")
        print("Apps settings rendered with Chrome preset, without changing settings.")
    }
}
