import CoreGraphics
import Foundation

@main struct ExplorerPointerLockTests {
    @MainActor static func main() {
        for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel] {
            precondition(ExplorerPointerLock.suppresses(type))
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                     .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .flagsChanged,
                     .tapDisabledByTimeout, .tapDisabledByUserInput] {
            precondition(!ExplorerPointerLock.suppresses(type), "Never swallow buttons, Escape, or system disable notifications")
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
        let saved = CGPoint(x: -820, y: 420)
        var current = saved
        var hides = 0, shows = 0
        var warped: [CGPoint] = []
        var allowHide = true, allowWarp = true
        var hold: ExplorerCursorHold? = ExplorerCursorHold()
        hold!.position = { current }
        hold!.hide = { if allowHide { hides += 1 }; return allowHide }
        hold!.show = { shows += 1 }
        hold!.warp = { warped.append($0); if allowWarp { current = $0 }; return allowWarp }
        precondition(hold!.acquire() && hold!.acquire())
        precondition(hides == 1 && shows == 0 && hold!.anchor == saved)
        for index in 0..<500 {
            current = CGPoint(x: Double(index), y: 999)
            precondition(hold!.pin() && current == saved, "Every motion pins the real position")
        }
        hold!.release()
        precondition(current == saved && hides == shows && hold!.anchor == nil)
        current = CGPoint(x: 10, y: 20) // An app-centering operation after release.
        let warpCount = warped.count
        hold!.release()
        precondition(warped.count == warpCount && shows == 1, "Repeated teardown must not undo centering")
        allowHide = false
        precondition(!hold!.acquire() && hides == shows && hold!.anchor == nil)
        allowHide = true; allowWarp = false
        precondition(!hold!.acquire() && hides == shows && hold!.anchor == nil, "Failed pin balances its hide")
        allowWarp = true
        precondition(hold!.acquire())
        hold = nil
        precondition(hides == shows, "Deallocation also restores and shows exactly once")
        let noPosition = ExplorerCursorHold()
        noPosition.position = { nil }
        noPosition.hide = { preconditionFailure("No position: do not hide") }
        precondition(!noPosition.acquire())
        print("Pointer lock passed: HUD motion/scroll suppression, pinning, hide/restore pairing, repeated teardown, failed capture, and deallocation. No live pointer capture used.")
    }
}
