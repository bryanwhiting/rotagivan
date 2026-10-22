import Foundation

@main
struct SwipeDirectionTests {
    static func main() {
        let directions: [(SwipeDirection, Double)] = [
            (.right, 0),
            (.bottomRight, 45),
            (.down, 90),
            (.bottomLeft, 135),
            (.left, 180),
            (.topLeft, 225),
            (.up, 270),
            (.topRight, 315),
        ]

        for (expected, degrees) in directions {
            precondition(classify(degrees) == expected, "Expected \(expected) at \(degrees) degrees")
            precondition(classify(degrees - 19) == expected)
            precondition(classify(degrees + 19) == expected)
        }

        for boundary in stride(from: 22.5, to: 360, by: 45) {
            precondition(classify(boundary) == nil, "Boundary at \(boundary) degrees must be ambiguous")
            precondition(classify(boundary - 2.9) == nil)
            precondition(classify(boundary + 2.9) == nil)
        }

        precondition(SwipeDirection.classify(dx: 0, dy: 0) == nil)
        precondition(SwipeDirection.classify(dx: .nan, dy: 1) == nil)
        precondition(SwipeDirection.classify(dx: 1, dy: .infinity) == nil)
        precondition(SwipeDirection.classify(dx: -.infinity, dy: 1) == nil)
        print("Passed eight-direction classification, wraparound, and boundary dead-zone checks.")
    }

    private static func classify(_ degrees: Double) -> SwipeDirection? {
        let radians = degrees * Double.pi / 180
        return SwipeDirection.classify(dx: cos(radians), dy: sin(radians))
    }
}
