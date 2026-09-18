import Foundation

@main
struct GestureCalibrationTests {
    private static let epsilon = 0.000_000_1

    static func main() {
        testDoubleTapMedianAndTiming()
        testTripleTap()
        testSingleTapSwipe()
        testSwipeMedianAndTiming()
        testRejectedTapInputsAndRecovery()
        testRejectedSwipeInputs()
        testInitialLiftContinuousContactAndInstructions()
        testTimeoutTicks()
        print("Passed gesture calibration medians, timing, rejection, quiet-gap, timeout, and completion checks.")
    }

    private static func testTripleTap() {
        var recorder = makeRecorder(.tripleTap)
        arm(&recorder, at: 0)
        for index in 0..<10 {
            let start = 1.0 + Double(index) * 3
            let first = 0.10 + Double(index) * 0.01
            let second = 0.20 + Double(index) * 0.01
            let secondLift = performDoubleTap(&recorder, start: start, interval: first)
            precondition(recorder.samples.count == index, "Two taps cannot complete a triple-tap attempt")
            recorder.process(report([(0, 800, 800, true)]), at: secondLift + second - 0.03)
            recorder.process(emptyReport, at: secondLift + second)
            precondition(recorder.samples.count == index + 1)
        }
        precondition(recorder.isComplete)
        precondition(close(recorder.medianDoubleTapInterval, 0.145))
        precondition(close(recorder.medianSecondTapInterval, 0.245))
        precondition(close(recorder.combinedTripleInterval, 0.390))
        precondition(recorder.medianSwipeWindow == nil)
        for invalid in 0..<3 {
            var rejected = makeRecorder(.tripleTap)
            arm(&rejected, at: 0)
            let lift = performDoubleTap(&rejected, start: 1, interval: 0.15)
            if invalid == 0 { rejected.tick(at: lift + 1.6) }
            else {
                rejected.process(report([(0,500,500,true)]), at: lift + 0.1)
                if invalid == 1 { rejected.tick(at: lift + 0.4) }
                else { rejected.process(report([(0,600,500,true)]), at: lift + 0.15) }
                rejected.process(emptyReport, at: lift + 0.45)
            }
            precondition(rejected.samples.isEmpty, "Reject timed-out, held or moving third taps")
        }
        print("Triple calibration passed: independent medians, combined rhythm, no partial samples, timeout/hold/movement rejection.")
    }

    private static func testDoubleTapMedianAndTiming() {
        var recorder = makeRecorder(.doubleTap)
        arm(&recorder, at: 0)
        let intervals = [0.20, 0.11, 0.18, 0.12, 0.17, 0.13, 0.16, 0.14, 0.15, 0.19]
        var start = 1.0

        for interval in intervals {
            let end = performDoubleTap(&recorder, start: start, interval: interval)
            if !recorder.isComplete {
                recorder.tick(at: end + 0.71)
            }
            start = end + 0.8
        }

        precondition(recorder.isComplete)
        precondition(recorder.samples.count == 10)
        precondition(close(recorder.medianDoubleTapInterval, 0.155))
        precondition(recorder.medianSwipeWindow == nil)
        for (sample, expected) in zip(recorder.samples, intervals) {
            precondition(close(sample.doubleTapInterval, expected))
            precondition(sample.swipeWindow == nil)
        }

        let completedSamples = recorder.samples
        let completedInstruction = recorder.instruction
        _ = performDoubleTap(&recorder, start: start, interval: 0.3)
        recorder.tick(at: start + 10)
        precondition(recorder.samples == completedSamples)
        precondition(recorder.instruction == completedInstruction)
    }

    private static func testSingleTapSwipe() {
        var recorder = makeRecorder(.singleTapSwipe)
        arm(&recorder, at: 0)
        for index in 0..<10 {
            let t = 1.0 + Double(index) * 2
            let gap = 0.10 + Double(index) * 0.01
            let duration = 0.08 + Double(index) * 0.01
            recorder.process(report([(0,500,500,true)]), at: t)
            recorder.process(emptyReport, at: t + 0.03)
            let start = t + 0.03 + gap
            recorder.process(report([(0,800,800,true)]), at: start)
            recorder.process(report([(0,900,800,true)]), at: start + 0.04)
            recorder.process(emptyReport, at: start + duration)
            precondition(recorder.samples.count == index + 1)
        }
        precondition(recorder.isComplete && close(recorder.medianSwipeWindow, 0.145))
        precondition(close(recorder.medianSwipeDuration, 0.125))
        for invalid in 0..<4 {
            var rejected = makeRecorder(.singleTapSwipe)
            arm(&rejected, at: 0)
            rejected.process(report([(0,500,500,true)]), at: 1)
            rejected.process(emptyReport, at: 1.03)
            rejected.process(report([(0,500,500,true)]), at: 1.10)
            let x: Double = invalid == 1 ? 510 : (invalid == 2 ? 1100 : 600)
            rejected.process(report([(0,x,500,invalid != 3)]), at: 1.14)
            rejected.process(emptyReport, at: invalid == 0 ? 1.5 : 1.2)
            precondition(rejected.samples.isEmpty, "Reject slow holds, undersized swipes, jumps, and uncertain contacts")
        }
    }

    private static func testSwipeMedianAndTiming() {
        var recorder = makeRecorder(.doubleTapSwipe)
        arm(&recorder, at: 0)
        let intervals = [0.14, 0.22, 0.16, 0.20, 0.18, 0.12, 0.24, 0.10, 0.26, 0.28]
        let windows = [0.30, 0.21, 0.29, 0.22, 0.28, 0.23, 0.27, 0.24, 0.26, 0.25]
        let vectors: [(Double, Double)] = [
            (80, 0), (80, 80), (0, 80), (-80, 80),
            (-80, 0), (-80, -80), (0, -80), (80, -80),
            (80, 0), (80, 80),
        ]
        var start = 1.0

        for index in intervals.indices {
            let end = performSwipe(&recorder, start: start, interval: intervals[index], window: windows[index],
                dx: vectors[index].0, dy: vectors[index].1)
            if !recorder.isComplete {
                recorder.tick(at: end + 0.71)
            }
            start = end + 0.8
        }

        precondition(recorder.isComplete)
        precondition(close(recorder.medianDoubleTapInterval, 0.19))
        precondition(close(recorder.medianSwipeWindow, 0.255))
        for index in recorder.samples.indices {
            precondition(close(recorder.samples[index].doubleTapInterval, intervals[index]))
            precondition(close(recorder.samples[index].swipeWindow, windows[index]))
        }
    }

    private static func testRejectedTapInputsAndRecovery() {
        assertRejectedTapAttempt { recorder, time in
            recorder.process(report([(0, 500, 500, true), (1, 520, 500, true)]), at: time)
            return (time + 0.01, true)
        }
        assertRejectedTapAttempt { recorder, time in
            recorder.process(report([(0, 500, 500, false)]), at: time)
            return (time + 0.01, true)
        }
        assertRejectedTapAttempt { recorder, time in
            recorder.process(report([(0, 500, 500, true)], buttonDown: true), at: time)
            return (time + 0.01, true)
        }
        assertRejectedTapAttempt { recorder, time in
            recorder.process(report([(0, 500, 500, true)]), at: time)
            recorder.process(report([(0, 520, 500, true)]), at: time + 0.02)
            return (time + 0.03, true)
        }
        assertRejectedTapAttempt { recorder, time in
            recorder.process(report([(0, 500, 500, true)]), at: time)
            recorder.process(report([(0, 900, 500, true)]), at: time + 0.02)
            return (time + 0.03, true)
        }
        assertRejectedTapAttempt { recorder, time in
            recorder.process(report([(0, 500, 500, true)]), at: time)
            recorder.tick(at: time + 0.21)
            return (time + 0.22, true)
        }

        // A held second contact is invalid, not a completed double tap.
        assertRejectedTapAttempt { recorder, time in
            recorder.process(report([(0, 500, 500, true)]), at: time)
            recorder.process(emptyReport, at: time + 0.04)
            recorder.process(report([(0, 500, 500, true)]), at: time + 0.10)
            recorder.tick(at: time + 0.31)
            return (time + 0.32, true)
        }
    }

    private static func testRejectedSwipeInputs() {
        // Short motion does not qualify as a swipe.
        assertRejectedSwipeAttempt { recorder, time in
            let secondLift = performDoubleTapLeadIn(&recorder, start: time, interval: 0.16)
            recorder.process(report([(0, 500, 500, true)]), at: secondLift + 0.2)
            recorder.process(report([(0, 530, 500, true)]), at: secondLift + 0.24)
            recorder.process(emptyReport, at: secondLift + 0.27)
            return (secondLift + 0.27, false)
        }

        // A sector boundary, sensor jump, multifinger, unconfident, and button input reject.
        assertRejectedSwipeAttempt { recorder, time in
            let secondLift = performDoubleTapLeadIn(&recorder, start: time, interval: 0.16)
            recorder.process(report([(0, 500, 500, true)]), at: secondLift + 0.2)
            recorder.process(report([(0, 600, 541.421356, true)]), at: secondLift + 0.24)
            recorder.process(emptyReport, at: secondLift + 0.27)
            return (secondLift + 0.27, false)
        }
        assertRejectedSwipeAttempt { recorder, time in
            let secondLift = performDoubleTapLeadIn(&recorder, start: time, interval: 0.16)
            recorder.process(report([(0, 500, 500, true)]), at: secondLift + 0.2)
            recorder.process(report([(0, 900, 500, true)]), at: secondLift + 0.24)
            return (secondLift + 0.25, true)
        }
        assertRejectedSwipeAttempt { recorder, time in
            let secondLift = performDoubleTapLeadIn(&recorder, start: time, interval: 0.16)
            recorder.process(report([(0, 500, 500, true)]), at: secondLift + 0.2)
            recorder.process(report([(0, 570, 500, true), (1, 550, 520, true)]), at: secondLift + 0.24)
            return (secondLift + 0.25, true)
        }
        assertRejectedSwipeAttempt { recorder, time in
            let secondLift = performDoubleTapLeadIn(&recorder, start: time, interval: 0.16)
            recorder.process(report([(0, 500, 500, true)]), at: secondLift + 0.2)
            recorder.process(report([(0, 570, 500, false)]), at: secondLift + 0.24)
            return (secondLift + 0.25, true)
        }
        assertRejectedSwipeAttempt { recorder, time in
            let secondLift = performDoubleTapLeadIn(&recorder, start: time, interval: 0.16)
            recorder.process(report([(0, 500, 500, true)]), at: secondLift + 0.2)
            recorder.process(report([(0, 570, 500, true)], buttonDown: true), at: secondLift + 0.24)
            return (secondLift + 0.25, true)
        }
    }

    private static func testInitialLiftContinuousContactAndInstructions() {
        var recorder = makeRecorder(.doubleTap)
        recorder.process(report([(0, 500, 500, true)]), at: 0)
        recorder.process(report([(0, 500, 500, true)]), at: 1.0)
        recorder.process(emptyReport, at: 1.1)
        recorder.process(report([(0, 500, 500, true)]), at: 1.7) // Only 0.6 seconds quiet.
        recorder.process(emptyReport, at: 1.71)
        precondition(recorder.samples.isEmpty)

        recorder.tick(at: 2.42)
        recorder.process(report([(0, 500, 500, true)]), at: 2.5)
        let tapInstruction = recorder.instruction
        recorder.process(report([(0, 503, 500, true)]), at: 2.52)
        precondition(recorder.instruction == tapInstruction)
        recorder.process(emptyReport, at: 2.54)
        recorder.process(report([(0, 500, 500, true)]), at: 2.62)
        recorder.process(emptyReport, at: 2.70)
        precondition(recorder.samples.count == 1)

        var swipeRecorder = makeRecorder(.doubleTapSwipe)
        arm(&swipeRecorder, at: 0)
        let secondLift = performDoubleTapLeadIn(&swipeRecorder, start: 1, interval: 0.15)
        swipeRecorder.process(report([(0, 500, 500, true)]), at: secondLift + 0.2)
        let swipeInstruction = swipeRecorder.instruction
        precondition(swipeInstruction.contains("horizontally, vertically, or diagonally"))
        swipeRecorder.process(report([(0, 570, 500, true)]), at: secondLift + 0.25)
        precondition(swipeRecorder.instruction == swipeInstruction)
    }

    private static func testTimeoutTicks() {
        var doubleRecorder = makeRecorder(.doubleTap)
        arm(&doubleRecorder, at: 0)
        doubleRecorder.process(report([(0, 500, 500, true)]), at: 1)
        doubleRecorder.process(emptyReport, at: 1.04)
        doubleRecorder.tick(at: 2.55)
        precondition(doubleRecorder.samples.isEmpty)
        doubleRecorder.tick(at: 3.26)
        _ = performDoubleTap(&doubleRecorder, start: 3.3, interval: 0.2)
        precondition(doubleRecorder.samples.count == 1)

        var swipeRecorder = makeRecorder(.doubleTapSwipe)
        arm(&swipeRecorder, at: 0)
        let secondLift = performDoubleTapLeadIn(&swipeRecorder, start: 1, interval: 0.2)
        swipeRecorder.tick(at: secondLift + 1.51)
        precondition(swipeRecorder.samples.isEmpty)

        // Once the third contact begins, its own 0.7-second deadline is timed.
        swipeRecorder.tick(at: secondLift + 2.22)
        let recoveredSecondLift = performDoubleTapLeadIn(&swipeRecorder, start: secondLift + 2.3, interval: 0.2)
        swipeRecorder.process(report([(0, 500, 500, true)]), at: recoveredSecondLift + 0.2)
        swipeRecorder.tick(at: recoveredSecondLift + 0.91)
        swipeRecorder.process(emptyReport, at: recoveredSecondLift + 0.92)
        precondition(swipeRecorder.samples.isEmpty)
    }

    private static func assertRejectedTapAttempt(
        _ attempt: (inout GestureCalibrationRecorder, Double) -> (time: Double, needsLift: Bool)
    ) {
        var recorder = makeRecorder(.doubleTap)
        arm(&recorder, at: 0)
        let outcome = attempt(&recorder, 1)
        precondition(recorder.samples.isEmpty)
        if outcome.needsLift {
            recorder.process(emptyReport, at: outcome.time)
        }
        recorder.tick(at: outcome.time + 0.71)
        _ = performDoubleTap(&recorder, start: outcome.time + 0.8, interval: 0.2)
        precondition(recorder.samples.count == 1)
    }

    private static func assertRejectedSwipeAttempt(
        _ attempt: (inout GestureCalibrationRecorder, Double) -> (time: Double, needsLift: Bool)
    ) {
        var recorder = makeRecorder(.doubleTapSwipe)
        arm(&recorder, at: 0)
        let outcome = attempt(&recorder, 1)
        precondition(recorder.samples.isEmpty)
        if outcome.needsLift {
            recorder.process(emptyReport, at: outcome.time)
        }
        recorder.tick(at: outcome.time + 0.71)
        _ = performSwipe(&recorder, start: outcome.time + 0.8, interval: 0.2, window: 0.25)
        precondition(recorder.samples.count == 1)
    }

    private static func makeRecorder(_ mode: GestureCalibrationMode) -> GestureCalibrationRecorder {
        GestureCalibrationRecorder(mode: mode, tapMaxDuration: 0.2, tapMaxMovement: 12, swipeDistance: 60)
    }

    private static func arm(_ recorder: inout GestureCalibrationRecorder, at time: Double) {
        recorder.process(emptyReport, at: time)
        recorder.tick(at: time + 0.7)
    }

    @discardableResult
    private static func performDoubleTap(
        _ recorder: inout GestureCalibrationRecorder,
        start: Double,
        interval: Double
    ) -> Double {
        let secondLift = performDoubleTapLeadIn(&recorder, start: start, interval: interval)
        return secondLift
    }

    @discardableResult
    private static func performDoubleTapLeadIn(
        _ recorder: inout GestureCalibrationRecorder,
        start: Double,
        interval: Double
    ) -> Double {
        let firstLift = start + 0.04
        let secondLift = firstLift + interval
        recorder.process(report([(0, 500, 500, true)]), at: start)
        recorder.process(emptyReport, at: firstLift)
        recorder.process(report([(0, 500, 500, true)]), at: secondLift - 0.04)
        recorder.process(emptyReport, at: secondLift)
        return secondLift
    }

    @discardableResult
    private static func performSwipe(
        _ recorder: inout GestureCalibrationRecorder,
        start: Double,
        interval: Double,
        window: Double,
        dx: Double = 80,
        dy: Double = 0
    ) -> Double {
        let secondLift = performDoubleTapLeadIn(&recorder, start: start, interval: interval)
        let swipeStart = secondLift + window
        recorder.process(report([(0, 500, 500, true)]), at: swipeStart)
        recorder.process(report([(0, 500 + dx, 500 + dy, true)]), at: swipeStart + 0.05)
        recorder.process(emptyReport, at: swipeStart + 0.08)
        return swipeStart + 0.08
    }

    private static var emptyReport: TrackpadReport {
        TrackpadReport(contacts: [], buttonDown: false, scanTime: 0)
    }

    private static func report(
        _ contacts: [(id: UInt8, x: Double, y: Double, confident: Bool)],
        buttonDown: Bool = false
    ) -> TrackpadReport {
        TrackpadReport(
            contacts: contacts.map {
                FingerContact(id: $0.id, x: $0.x, y: $0.y, touching: true, confident: $0.confident)
            },
            buttonDown: buttonDown,
            scanTime: 0
        )
    }

    private static func close(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < epsilon
    }
}
