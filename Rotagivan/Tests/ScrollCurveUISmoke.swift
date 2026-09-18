import AppKit
import SwiftUI

@main struct ScrollCurveUISmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let current = MotionProfile.normal
        var tuned = current
        tuned.scrollResponse = ScrollResponse(slowMultiplier:0.2,fastMultiplier:3,transitionSpeed:1400)
        let root = HStack(alignment:.top,spacing:24) {
            VStack(alignment:.leading,spacing:16) {
                Text("Current response").font(.headline)
                ScrollCurveEditor(profile:.constant(current))
            }.frame(width:290)
            VStack(alignment:.leading,spacing:16) {
                Text("Customized response").font(.headline)
                ScrollCurveEditor(profile:.constant(tuned))
            }.frame(width:290)
        }.padding(28).frame(width:660,height:510).background(Color(nsColor:.windowBackgroundColor))
        let view = NSHostingView(rootView:root)
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:660,height:510),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.contentView=view
        panel.orderFront(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        panel.orderOut(nil)
        print("Scroll curve UI rendered: legacy flat response and customized smooth curve.")
    }
}
