import Foundation

@main
struct ReportTests {
    static func main() {
        let packet: [UInt8] = [1, 3, 0, 0, 4, 0, 2, 3, 1, 0, 6, 0, 5, 52, 18, 18]
        let result = packet.withUnsafeBufferPointer { TrackpadReport.parse($0.baseAddress!, length: $0.count) }!
        precondition(result.contacts.count == 2)
        precondition(result.contacts[0].x == 1024 && result.contacts[0].y == 512)
        precondition(result.contacts[1].id == 1 && result.contacts[1].y == 1280)
        precondition(result.buttonDown && result.scanTime == 0x1234)
        for length in 0..<16 {
            precondition(packet.withUnsafeBufferPointer { TrackpadReport.parse($0.baseAddress!, length: length) } == nil)
        }
        var release = packet
        release[1] = 1
        release[7] = 1
        let lifted = release.withUnsafeBufferPointer { TrackpadReport.parse($0.baseAddress!, length: $0.count) }!
        precondition(lifted.contacts.allSatisfy { !$0.touching })
        print("Passed report decoding, truncation, coordinate and lift-off checks")
    }
}
