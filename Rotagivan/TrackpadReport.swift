import Foundation

struct FingerContact: Equatable {
    let id: UInt8
    let x: Double
    let y: Double
    let touching: Bool
    let confident: Bool
}

struct TrackpadReport: Equatable {
    let contacts: [FingerContact]
    let buttonDown: Bool
    let scanTime: UInt16

    static func parse(_ bytes: UnsafePointer<UInt8>, length: Int) -> TrackpadReport? {
        guard length == 16, bytes[0] == 0x01 else { return nil }
        var contacts: [FingerContact] = []
        for offset in [1, 7] {
            let flags = bytes[offset]
            let touching = flags & 0x02 != 0
            let confident = flags & 0x01 != 0
            let id = bytes[offset + 1] & 0x07
            let x = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
            let y = UInt16(bytes[offset + 4]) | (UInt16(bytes[offset + 5]) << 8)
            if touching || flags != 0 {
                contacts.append(FingerContact(id: id, x: Double(x), y: Double(y), touching: touching, confident: confident))
            }
        }
        let scanTime = UInt16(bytes[13]) | (UInt16(bytes[14]) << 8)
        let buttonDown = bytes[15] & 0x10 != 0
        return TrackpadReport(contacts: contacts, buttonDown: buttonDown, scanTime: scanTime)
    }
}
