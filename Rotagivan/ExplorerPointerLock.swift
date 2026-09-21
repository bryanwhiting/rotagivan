import CoreGraphics
import Foundation

@MainActor protocol ExplorerPointerControlling: AnyObject {
    var onInterruption: (() -> Void)? { get set }
    @discardableResult func setLocked(_ locked: Bool) -> Bool
}

/// Balanced cursor ownership, independently testable without moving the real
/// pointer. Warping generates no input event. Do not disassociate the system
/// mouse: that API is foreground-only and this HUD deliberately preserves focus.
final class ExplorerCursorHold {
    var position: () -> CGPoint? = { CGEvent(source: nil)?.location }
    var warp: (CGPoint) -> Bool = { CGWarpMouseCursorPosition($0) == .success }
    var hide: () -> Bool = { CGDisplayHideCursor(CGMainDisplayID()) == .success }
    var show: () -> Void = { _ = CGDisplayShowCursor(CGMainDisplayID()) }
    private(set) var anchor: CGPoint?
    private var hidden = false

    func acquire() -> Bool {
        if anchor != nil { return true }
        guard let point = position(), point.x.isFinite, point.y.isFinite else { return false }
        guard hide() else { return false }
        hidden = true
        anchor = point
        guard pin() else { release(); return false }
        return true
    }

    func pin() -> Bool {
        guard let anchor else { return false }
        return warp(anchor)
    }

    func release() {
        // Restore before showing; clear ownership first so repeated teardown
        // cannot warp back over a subsequent app-centering operation.
        let saved = anchor
        anchor = nil
        if let saved { _ = warp(saved) }
        if hidden { hidden = false; show() }
    }

    deinit { release() }
}

/// Scoped to a visible, non-editing Apple-controlled HUD. In addition to
/// swallowing motion events, pin the actual WindowServer cursor and balance
/// one hide/show pair. Never change native pointer preferences or app focus.
@MainActor final class ExplorerPointerLock: ExplorerPointerControlling {
    var onInterruption: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let cursor = ExplorerCursorHold()

    nonisolated static func suppresses(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return true
        default: return false
        }
    }

    static func shouldLock(enabled: Bool, appleEnabled: Bool, visible: Bool, editing: Bool,
                           owner: TrackpadInputSource?, appleConnected: Bool) -> Bool {
        enabled && appleEnabled && visible && !editing &&
            (owner?.isApple == true || (owner == nil && appleConnected))
    }

    @discardableResult func setLocked(_ locked: Bool) -> Bool {
        guard locked else { release(); return true }
        // Touch reports call this frequently. Do not query WindowServer per frame;
        // the disabled-tap callback clears the handle if macOS interrupts capture.
        if tap != nil { return true }
        release()
        let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { release(); return false }
        guard cursor.acquire() else { release(); return false }
        return true
    }

    private func release() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        cursor.release()
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    nonisolated private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        // This tap is attached only to the main run loop. Ordinary motion filtering
        // does no gesture processing, settings writes, or UI rendering.
        return MainActor.assumeIsolated {
            let owner = Unmanaged<ExplorerPointerLock>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.release()
                // Fail open instead of fighting macOS/user-requested disable.
                owner.onInterruption?()
                return Unmanaged.passUnretained(event)
            }
            guard owner.tap != nil && suppresses(type) else { return Unmanaged.passUnretained(event) }
            // Dropping an event alone can leave the on-screen cursor moving.
            // Update its real position as well, without posting another event.
            guard owner.cursor.pin() else {
                owner.release()
                owner.onInterruption?()
                return Unmanaged.passUnretained(event)
            }
            if let anchor = owner.cursor.anchor { event.location = anchor }
            event.setDoubleValueField(.mouseEventDeltaX, value: 0)
            event.setDoubleValueField(.mouseEventDeltaY, value: 0)
            return nil
        }
    }
}
