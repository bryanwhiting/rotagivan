import AppKit

enum ExplorerMediaAction: Int, CaseIterable {
    // Public IOKit hidsystem/ev_keymap.h NX_KEYTYPE values.
    case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, next = 17, previous = 18
    var direction: SwipeDirection {
        switch self { case .volumeUp: return .up; case .volumeDown: return .down; case .mute: return .topLeft; case .playPause: return .topRight; case .next: return .right; case .previous: return .left }
    }
    var title: String {
        switch self { case .volumeUp: return "Volume up"; case .volumeDown: return "Volume down"; case .mute: return "Mute / unmute"; case .playPause: return "Play / pause"; case .next: return "Next track"; case .previous: return "Previous track" }
    }
    var symbol: String {
        switch self { case .volumeUp: return "speaker.wave.3.fill"; case .volumeDown: return "speaker.wave.1.fill"; case .mute: return "speaker.slash.fill"; case .playPause: return "playpause.fill"; case .next: return "forward.end.fill"; case .previous: return "backward.end.fill" }
    }
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
