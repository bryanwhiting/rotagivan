import CoreGraphics
import Foundation

@MainActor protocol ExplorerPointerControlling: AnyObject {
    var onInterruption: (() -> Void)? { get set }
    @discardableResult func setLocked(_ locked: Bool) -> Bool
}

/// Scoped to a visible, non-editing Apple-controlled HUD. No cursor warping,
/// hidden cursor, synthetic events, or changes to macOS trackpad preferences.
/// The event tap dies with this object/process; it cannot leave a system-wide
/// mouse/cursor disassociation behind after a crash.
@MainActor final class ExplorerPointerLock: ExplorerPointerControlling {
    var onInterruption: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

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
        return true
    }

    private func release() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
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
            return owner.tap != nil && suppresses(type) ? nil : Unmanaged.passUnretained(event)
        }
    }
}
