import AppKit
import Foundation

@main
@MainActor
struct AppleTrackpadInputTests {
    static func near(_ actual: Double, _ expected: Double) {
        precondition(abs(actual - expected) < 0.000_001, "\(actual) != \(expected)")
    }

    static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    static func put<T>(_ value: T, at offset: Int, in record: inout [UInt8]) {
        let valueBytes = bytes(of: value)
        record.replaceSubrange(offset..<(offset + valueBytes.count), with: valueBytes)
    }

    static func record(identifier: Int32, state: Int32 = 4, normalizedX: Float = 0.25,
                       normalizedY: Float = 0.75, millimetersX: Float = 11,
                       millimetersY: Float = 22) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: AppleMultitouchFrame.contactStride)
        put(identifier, at: 16, in: &result)
        put(state, at: 20, in: &result)
        put(normalizedX, at: 32, in: &result)
        put(normalizedY, at: 36, in: &result)
        put(millimetersX, at: 68, in: &result)
        put(millimetersY, at: 72, in: &result)
        return result
    }

    static func decoded(_ records: [[UInt8]], frame: Int32 = 65_537) -> AppleMultitouchFrame? {
        let raw = records.flatMap { $0 }
        return raw.withUnsafeBytes {
            AppleMultitouchFrame.copy(from: $0.baseAddress, count: Int32(records.count), number: frame)
        }
    }

    static func main() {
        let suite = "Rotagivan.AppleLegacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = ["enabled": true, "threeFingerTap": "enter"]
        let original = try! JSONSerialization.data(withJSONObject: ["macTrackpad": legacy])
        defaults.set(original, forKey: "settings.v1")
        AppleTrackpadInput.preserveLegacySettings(defaults)
        let archived = defaults.data(forKey: "input.legacyAppleTrackpadSettings")!
        precondition(NSDictionary(dictionary: try! JSONSerialization.jsonObject(with: archived) as! [String: Any]).isEqual(to: legacy))
        precondition(defaults.data(forKey: "settings.v1") == original, "Archiving must never rewrite user layers")
        precondition(!defaults.bool(forKey: "input.appleTrackpadActions"), "Legacy settings must not implicitly enable new gestures")
        defaults.set(Data("{}".utf8), forKey: "settings.v1")
        AppleTrackpadInput.preserveLegacySettings(defaults)
        precondition(defaults.data(forKey: "input.legacyAppleTrackpadSettings") == archived)
        let frame = decoded([record(identifier: 7)])!
        let report = AppleTrackpadInput.report(from: frame)!
        precondition(report.contacts.count == 1 && report.contacts[0].id == 7)
        precondition(report.contacts[0].touching && report.contacts[0].confident)
        near(report.contacts[0].x, 11 * AppleTrackpadInput.unitsPerMillimeter)
        near(report.contacts[0].y, -22 * AppleTrackpadInput.unitsPerMillimeter)
        precondition(report.scanTime == 1 && !report.buttonDown)

        let fallbackFrame = decoded([record(identifier: 8, millimetersX: .nan)])!
        let fallback = AppleTrackpadInput.report(from: fallbackFrame)!.contacts[0]
        precondition(!fallback.confident)
        near(fallback.x, 0.25 * 2_048)
        near(fallback.y, -0.75 * 2_048)

        let colliding = decoded([record(identifier: 1), record(identifier: 257)])!
        precondition(AppleTrackpadInput.report(from: colliding) == nil)
        precondition(decoded([record(identifier: 1, state: 99)]) == nil)
        precondition(AppleMultitouchFrame.copy(from: nil, count: 1, number: 0) == nil)
        precondition(AppleMultitouchFrame.copy(from: nil, count: 33, number: 0) == nil)
        let empty = AppleMultitouchFrame.copy(from: nil, count: 0, number: 9)!
        precondition(AppleTrackpadInput.report(from: empty)?.contacts.isEmpty == true)

        precondition(AppleTrackpadInput.callbackIsCurrent(running: true, callbackGeneration: 4,
                                                          currentGeneration: 4, deviceKnown: true))
        precondition(!AppleTrackpadInput.callbackIsCurrent(running: false, callbackGeneration: 4,
                                                           currentGeneration: 4, deviceKnown: true))
        precondition(!AppleTrackpadInput.callbackIsCurrent(running: true, callbackGeneration: 3,
                                                           currentGeneration: 4, deviceKnown: true))
        precondition(!AppleTrackpadInput.callbackIsCurrent(running: true, callbackGeneration: 4,
                                                           currentGeneration: 4, deviceKnown: false))

        let input = AppleTrackpadInput()
        var observed: [AppleTrackpadInput.Status] = []
        var reports = 0
        input.onStatus = { observed.append($0) }
        input.onReport = { _, _, _, _ in reports += 1 }

        input.start()
        let started = input.status
        precondition(started != .stopped)
        input.refresh()
        input.stop()

        precondition(input.status == .stopped)
        precondition(observed.last == .stopped)
        print("Apple trackpad raw-frame decoding, mm scaling, malformed/collision rejection, generation gating, and observation-only lifecycle passed: \(started); frames observed without generating input: \(reports).")
    }
}
