import AppKit

extension ExplorerMediaAction {
    static func events(for action: Self) -> [NSEvent] {
        [true, false].compactMap { down in
            let state = down ? 0xA : 0xB
            return NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 8,
                data1: (action.rawValue << 16) | (state << 8), data2: -1)
        }
    }
    static func perform(_ action: Self) {
        for event in events(for: action) { event.cgEvent?.post(tap: .cghidEventTap) }
    }
}
