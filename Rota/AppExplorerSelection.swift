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
    var invertDirection: Bool
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

    init(waitingForLift: Bool, slotCount: Int = 8, deepSlots: Set<ExplorerSlot> = [], invertDirection: Bool = false) {
        self.waitingForLift = waitingForLift; self.slotCount = slotCount; self.deepSlots = deepSlots
        self.invertDirection = invertDirection
    }

    init(continuing continuation: Continuation, slotCount: Int, fanOrigin: ExplorerSlot, invertDirection: Bool = false) {
        waitingForLift = false
        self.invertDirection = invertDirection
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
        // Keep continuity and jump detection in physical coordinates. Only the
        // vector used to classify a picker sector follows this preference.
        let sign = invertDirection ? -1.0 : 1.0
        let direction = distance >= Self.minimumDistance
            ? (fanOrigin.map { DeepSwipeFan.classify(dx: dx * sign, dy: dy * sign, count: slotCount, origin: $0) }
                ?? ExplorerSlot.classify(dx: dx * sign, dy: dy * sign, count: slotCount))
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
    /// Pin the foreground application, then use MRU order without duplicating it.
    func activeFirst(available: [String], active: String?, limit: Int = 8) -> [String] {
        let count = max(0, min(16, limit))
        guard count > 0 else { return [] }
        guard let active, available.contains(active) else {
            return ordered(available: available, excluding: [], limit: count)
        }
        return [active] + ordered(available: available, excluding: [active], limit: count - 1)
    }

    func ordered(available: [String], excluding: Set<String>, limit: Int = 8) -> [String] {
        Array(mostRecentFirst(available: available, excluding: excluding).prefix(max(0, min(16, limit))))
    }

    func mostRecentFirst(available: [String], excluding: Set<String> = []) -> [String] {
        let allowed = Set(available).subtracting(excluding)
        var seen = Set<String>()
        return (identifiers + available).filter { allowed.contains($0) && seen.insert($0).inserted }
    }
}

enum RecentPlace<Tab: Equatable>: Equatable { case app(String), tab(Tab), slack(String) }

/// One most-recent-first list of apps, Chrome tabs and Slack channels. Chrome and
/// Slack appear only as their tabs and channels. Stamps come from one shared
/// clock; unstamped places keep their input order.
enum RecentPlaces {
    static let chromeBundleID = "com.google.Chrome"
    static let slackBundleID = "com.tinyspeck.slackmacgap"
    /// `apps` arrive in MRU order, `tabs` with Chrome's selected tab first and
    /// `slack` most active first. The current place (the active app, Chrome's
    /// selected tab, or Slack's open channel) always leads.
    static func merged<Tab: Equatable>(apps: [String], tabs: [Tab], slack: [String] = [], active: String?,
                                       appStamp: (String) -> UInt64?, tabStamp: (Tab) -> UInt64?,
                                       slackStamp: (String) -> UInt64? = { _ in nil }) -> [RecentPlace<Tab>] {
        var current: RecentPlace<Tab>?
        if active == chromeBundleID { current = tabs.first.map { .tab($0) } }
        else if active == slackBundleID, let first = slack.first { current = .slack(first) }
        else if let active, apps.contains(active) { current = .app(active) }
        var candidates: [(RecentPlace<Tab>, UInt64)] = []
        for app in apps where app != chromeBundleID && (app != slackBundleID || slack.isEmpty) {
            candidates.append((.app(app), appStamp(app) ?? 0))
        }
        for tab in tabs { candidates.append((.tab(tab), tabStamp(tab) ?? 0)) }
        for channel in slack { candidates.append((.slack(channel), slackStamp(channel) ?? 0)) }
        let rest = candidates.enumerated().filter { $0.element.0 != current }.sorted { lhs, rhs in
            lhs.element.1 == rhs.element.1 ? lhs.offset < rhs.offset : lhs.element.1 > rhs.element.1
        }.map(\.element.0)
        return (current.map { [$0] } ?? []) + rest
    }
}
