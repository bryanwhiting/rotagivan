import Foundation
import CoreGraphics

/// Pure input gate: consume the trigger's remaining contact, then use a fresh
/// one-finger displacement. No cursor events or app activation occur here.
struct AppExplorerSelection {
    struct Continuation: Equatable {
        let contactID: UInt8
        let origin: CGPoint
        let point: CGPoint
    }
    enum Result: Equatable { case waiting, highlight(ExplorerSlot?), deepen(ExplorerSlot, Continuation), select(ExplorerSlot), back, cancel }
    var waitingForLift: Bool
    var slotCount = 8
    var deepSlots: Set<ExplorerSlot> = []
    var fanOrigin: ExplorerSlot?
    private var contactID: UInt8?
    private var origin = CGPoint.zero
    private var last = CGPoint.zero
    private var selected: ExplorerSlot?
    private var selectedAt = Date.distantPast
    private var finished = false
    private var started = Date.distantPast
    private var maximumTravel = 0.0
    static let minimumDistance = 60.0

    static let deepHoldDuration = 0.48

    init(waitingForLift: Bool, slotCount: Int = 8, deepSlots: Set<ExplorerSlot> = []) {
        self.waitingForLift = waitingForLift; self.slotCount = slotCount; self.deepSlots = deepSlots
    }

    init(continuing continuation: Continuation, slotCount: Int, fanOrigin: ExplorerSlot) {
        waitingForLift = false
        self.slotCount = slotCount
        self.fanOrigin = fanOrigin
        contactID = continuation.contactID
        origin = continuation.origin
        last = continuation.point
        started = Date()
    }

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
        let distance = hypot(dx, dy)
        let direction = distance >= Self.minimumDistance
            ? (fanOrigin.map { DeepSwipeFan.classify(dx: dx, dy: dy, count: slotCount, origin: $0) }
                ?? ExplorerSlot.classify(dx: dx, dy: dy, count: slotCount))
            : nil
        if fanOrigin == nil, let selected, selected == direction, deepSlots.contains(selected),
           now.timeIntervalSince(selectedAt) >= Self.deepHoldDuration {
            deepSlots.remove(selected)
            return .deepen(selected, Continuation(contactID: contactID, origin: origin, point: point))
        }
        guard selected != direction else { return .waiting }
        selected = direction
        selectedAt = now
        return .highlight(direction)
    }
}

enum DeepSwipeFan {
    static func span(count: Int) -> Double { min(140, max(72, Double(count) * 14)) }
    static func angle(for slot: ExplorerSlot, count: Int, origin: ExplorerSlot) -> Double {
        let slots = ExplorerSlot.slots(count)
        guard let index = slots.firstIndex(of: slot) else { return origin.angle }
        let width = span(count: count) / Double(count)
        return origin.angle - span(count: count) / 2 + width * (Double(index) + 0.5)
    }
    static func classify(dx: Double, dy: Double, count: Int, origin: ExplorerSlot) -> ExplorerSlot? {
        let angle = atan2(dy, dx) * 180 / .pi
        return ExplorerSlot.slots(count).min {
            ExplorerSlot.distance(Self.angle(for: $0, count: count, origin: origin), angle) <
                ExplorerSlot.distance(Self.angle(for: $1, count: count, origin: origin), angle)
        }.flatMap {
            ExplorerSlot.distance(Self.angle(for: $0, count: count, origin: origin), angle) <= span(count: count) / 2 ? $0 : nil
        }
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
