import AppKit

// Exercise AppKit's real text selection without posting clicks into the user's apps.
@main
struct ParagraphSelectionTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        text.string = "First paragraph has several words.\nSecond paragraph stays unselected."
        text.font = NSFont.systemFont(ofSize: 16)
        window.contentView = text
        window.makeFirstResponder(text)
        text.layoutManager!.ensureLayout(for: text.textContainer!)
        let glyph = text.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 10, length: 1),
                                                     in: text.textContainer!)
        let point = text.convert(NSPoint(x: glyph.midX + text.textContainerOrigin.x,
                                         y: glyph.midY + text.textContainerOrigin.y), to: nil)
        var sequence = EventPoster.ClickSequence()
        for index in 0..<3 {
            let events = sequence.events(position: point, at: Double(index) * 0.1, interval: 0.5)
            let counts = events.map { Int($0.getIntegerValueField(.mouseEventClickState)) }
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: Double(index) * 0.1, windowNumber: window.windowNumber, context: nil,
                eventNumber: index * 2, clickCount: counts[0], pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: Double(index) * 0.1 + 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: index * 2 + 1, clickCount: counts[1], pressure: 0)!
            app.postEvent(up, atStart: true)
            text.mouseDown(with: down)
            if index == 0 { precondition(text.selectedRange().length == 0) }
            if index == 1 { precondition(text.selectedRange().length > 0 && text.selectedRange().length < 34) }
        }
        let selected = (text.string as NSString).substring(with: text.selectedRange())
        precondition(selected == "First paragraph has several words.\n", "Triple tap must select exactly the first paragraph: \(selected)")
        print("AppKit text selection passed: caret, word, then whole paragraph on three ordinary tap-clicks.")
    }
}
