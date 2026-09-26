import AppKit
import SwiftUI

private final class PickerCatalogFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0
    let gate = DispatchSemaphore(value: 0)
    var calls: Int { lock.lock(); defer { lock.unlock() }; return scans }
    func scan() -> ExplorerApplicationCatalog.ScanResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock(); scans += 1; let number = scans; lock.unlock()
        if number == 1 { gate.wait() }
        let name = number == 1 ? "Shared Fixture Alpha" : "Shared Fixture Beta"
        return .init(applications: [.init(bundleID: "fixture.shared", name: name,
            url: URL(fileURLWithPath: "/Fixture/\(name).app"))], errors: [])
    }
}

@main struct SharedApplicationPickerTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let fixture = PickerCatalogFixture()
        let index = VoiceApplicationIndex(scan: { fixture.scan() })
        let destination = NSHostingView(rootView: ExplorerDestinationPicker(direction: .up,
            onSave: { _, _ in preconditionFailure("Fixture must not execute") }, onCancel: {}, applicationIndex: index))
        let action = NSHostingView(rootView: ActionPickerModal(current: .openURL("https://example.com"),
            dictionary: [], layers: [], destinations: [], applicationIndex: index,
            onSelect: { _ in preconditionFailure("Fixture must not execute") }, onCancel: {}))
        let hosts: [NSView] = [destination, action]
        let windows = hosts.map { host in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            return window
        }
        defer { windows.forEach { $0.orderOut(nil); $0.close() }; index.stop() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        func wait(_ message: String, _ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !predicate(), Date() < deadline { settle() }
            if !predicate() {
                for (number, host) in hosts.enumerated() {
                    let nodes: [AnyObject] = views(host).flatMap { elements($0) }
                    print("HOST", number, nodes.compactMap { $0.accessibilityLabel?() })
                    if CommandLine.arguments.count > 1, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to:
                            URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("shared-picker-failure-\(number).png"))
                    }
                }
                fflush(stdout)
            }
            precondition(predicate(), "Native picker fixture timed out: \(message); scans=\(fixture.calls), apps=\(index.applications)")
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func elements(_ object: Any) -> [AnyObject] {
            let element = object as AnyObject
            return [element] + (element.accessibilityChildren?() ?? []).flatMap(elements)
        }
        func contains(_ name: String, in host: NSView) -> Bool {
            let accessible: [AnyObject] = views(host).flatMap { elements($0) }
            return accessible.contains { (element: AnyObject) in
                let label = element.accessibilityLabel?() ?? ""
                let selector = NSSelectorFromString("accessibilityValue")
                let node = element as? NSObject
                let value = node?.responds(to: selector) == true
                    ? node?.perform(selector)?.takeUnretainedValue() as? String : nil
                return label.contains(name) || (value ?? "").contains(name)
            }
        }
        wait("initial scan") { fixture.calls == 1 }; settle()
        precondition(fixture.calls == 1, "Concurrent pickers must coalesce initial scan")
        func search(_ text: String, in host: NSView) {
            host.window?.makeKeyAndOrderFront(nil); NSApp.activate(); settle()
            guard let field = views(host).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else {
                preconditionFailure("Missing actual native search field")
            }
            field.selectText(nil)
            guard let editor = field.window?.firstResponder as? NSTextView else {
                preconditionFailure("Missing native field editor")
            }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            field.window?.makeFirstResponder(nil); settle(); host.layoutSubtreeIfNeeded()
        }
        // Filter before the initial result so lazy action rows are genuinely
        // visible, rather than relying on offscreen accessibility descendants.
        hosts.forEach { search("Shared Fixture", in: $0) }
        precondition(fixture.calls == 1, "Native queries must not dispatch additional scans")
        fixture.gate.signal()
        wait("Alpha rendered in destination/action") { hosts.allSatisfy { contains("Shared Fixture Alpha", in: $0) } }
        Task { await index.refresh(force: true) }
        wait("Beta rendered in destination/action") { hosts.allSatisfy { contains("Shared Fixture Beta", in: $0) } }
        precondition(hosts.allSatisfy { !contains("Shared Fixture Alpha", in: $0) },
            "Both open pickers must remove obsolete snapshot rows")
        for host in hosts {
            search("Shared Fixture Beta", in: host)
        }
        precondition(fixture.calls == 2, "Searching and rerendering must not scan again")
        precondition(hosts.allSatisfy { contains("Shared Fixture Beta", in: $0) })
        if CommandLine.arguments.count > 1 {
            for (position, host) in hosts.enumerated() {
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    preconditionFailure("Native picker capture unavailable")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("shared-picker-\(position).png"))
            }
        }
        print("Shared picker index passed: concurrent admission, live snapshot replacement, and scan-free native searching.")
    }
}
