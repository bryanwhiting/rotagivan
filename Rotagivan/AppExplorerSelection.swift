import Foundation
import CoreGraphics

/// Pure input gate: consume the trigger's remaining contact, then use a fresh
/// one-finger displacement. No cursor events or app activation occur here.
struct AppExplorerSelection {
    enum Result: Equatable { case waiting, highlight(ExplorerSlot?), select(ExplorerSlot), back, cancel }
    var waitingForLift: Bool
    var slotCount = 8
    private var contactID: UInt8?
    private var origin = CGPoint.zero
    private var last = CGPoint.zero
    private var selected: ExplorerSlot?
    private var finished = false
    private var started = Date.distantPast
    private var maximumTravel = 0.0
    static let minimumDistance = 60.0

    init(waitingForLift: Bool, slotCount: Int = 8) { self.waitingForLift = waitingForLift; self.slotCount = slotCount }

    mutating func process(_ report: TrackpadReport, at now: Date = Date()) -> Result {
        guard !finished else { return .waiting }
        let contacts = report.contacts.filter(\.touching)
        if waitingForLift {
            if contacts.isEmpty && !report.buttonDown { waitingForLift = false }
            return .waiting
        }
        guard !report.buttonDown, contacts.count <= 1, contacts.allSatisfy(\.confident) else {
            finished = true; return .cancel
        }
        guard let contact = contacts.first else {
            guard contactID != nil else { return .waiting }
            finished = true
            if let selected { return .select(selected) }
            return maximumTravel <= 25 && now.timeIntervalSince(started) <= 0.35 ? .back : .cancel
        }
        let point = CGPoint(x: contact.x, y: contact.y)
        guard let contactID else {
            self.contactID = contact.id
            origin = point; last = point
            started = now
            return .waiting
        }
        guard contact.id == contactID, hypot(point.x - last.x, point.y - last.y) < 400 else {
            finished = true; return .cancel
        }
        last = point
        let dx = point.x - origin.x, dy = point.y - origin.y
        maximumTravel = max(maximumTravel, hypot(dx, dy))
        let direction = hypot(dx, dy) >= Self.minimumDistance ? ExplorerSlot.classify(dx: dx, dy: dy, count: slotCount) : nil
        guard selected != direction else { return .waiting }
        selected = direction
        return .highlight(direction)
    }
}

/// Persist only bundle identifiers, not window names, documents, or app contents.
struct AppExplorerRecents {
    private(set) var identifiers: [String]
    init(_ identifiers: [String] = []) {
        var seen = Set<String>()
        self.identifiers = Array(identifiers.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(64))
    }
    mutating func record(_ identifier: String) {
        identifiers.removeAll { $0 == identifier }
        identifiers.insert(identifier, at: 0)
        identifiers = Array(identifiers.prefix(64))
    }
    func ordered(available: [String], excluding: Set<String>, limit: Int = 8) -> [String] {
        let allowed = Set(available).subtracting(excluding)
        var seen = Set<String>()
        return Array((identifiers + available).filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(max(0, min(16, limit))))
    }
}
