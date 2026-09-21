import CoreGraphics
import Foundation

@main struct ExplorerPointerLockTests {
    @MainActor static func main() {
        for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            precondition(ExplorerPointerLock.suppresses(type))
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                     .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
                     .tapDisabledByTimeout, .tapDisabledByUserInput] {
            precondition(!ExplorerPointerLock.suppresses(type), "Never swallow buttons, scrolling, Escape, or system disable notifications")
        }
        for enabled in [true, false] {
            for apple in [true, false] {
                for visible in [true, false] {
                    for editing in [true, false] {
                        for owner in [nil, TrackpadInputSource.navigator, .apple(12)] {
                            for connected in [true, false] {
                                let expected = enabled && apple && visible && !editing &&
                                    (owner == .apple(12) || (owner == nil && connected))
                                precondition(ExplorerPointerLock.shouldLock(enabled: enabled, appleEnabled: apple,
                                    visible: visible, editing: editing, owner: owner, appleConnected: connected) == expected)
                            }
                        }
                    }
                }
            }
        }
        // Constructing/stopping the controller never creates an event tap.
        let pointer = ExplorerPointerLock()
        precondition(pointer.setLocked(false))
        precondition(pointer.setLocked(false))
        print("Pointer lock passed: motion-only filter, complete lifecycle/source policy, idempotent unlock. No live pointer capture used.")
    }
}
