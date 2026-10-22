import Foundation

extension SwipeDirection {
    /// Classifies a displacement into eight equal 45-degree sectors.
    ///
    /// A narrow dead zone around each sector boundary prevents a nearly even
    /// gesture from choosing one of two shortcuts arbitrarily.
    static func classify(dx: Double, dy: Double) -> SwipeDirection? {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }

        let sectorWidth = Double.pi / 4
        let boundaryDeadZone = 3 * Double.pi / 180
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * Double.pi }

        let nearestSector = Int((angle / sectorWidth).rounded()) % 8
        let center = Double(nearestSector) * sectorWidth
        let directDistance = abs(angle - center)
        let angularDistance = min(directDistance, 2 * Double.pi - directDistance)
        guard angularDistance <= sectorWidth / 2 - boundaryDeadZone else { return nil }

        switch nearestSector {
        case 0: return .right
        case 1: return .bottomRight
        case 2: return .down
        case 3: return .bottomLeft
        case 4: return .left
        case 5: return .topLeft
        case 6: return .up
        default: return .topRight
        }
    }
}
