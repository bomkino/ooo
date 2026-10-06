import Foundation

/// The camera's path measured the way a viewer feels it: how fast each move
/// flies and turns at its peak, whether each emphasis comes all the way in,
/// and whether the picture ever jumps outside a cut. `ooo-lab motioncheck`
/// prints it; tests and CI fail on its problems.
public struct MotionCheck: Sendable {
    public struct BeatReport: Sendable {
        public let index: Int
        public let label: String
        public let land: Double
        public let travel: Double
        public let hold: Double
        public let move: MoveKind
        public let isOverview: Bool
        /// Peak zoom-and-pan rate in e-folds per second (see `Choreography.peakRate`).
        public let peakRate: Double
        /// Peak turn in degrees per second, arc included.
        public let peakTurn: Double
        /// How far the emphasis comes in at its height; nil when the shot has none.
        public let emphasisPeak: Float?
    }

    /// One rise or settle of a Lift, with whatever the camera is doing at the time.
    public struct LiftReport: Sendable {
        public let start: Double
        public let rising: Bool
        /// Peak zoom-and-pan rate of the picture while the stage moves, e-folds per second.
        public let peakRate: Double
    }

    public let beats: [BeatReport]
    public let lifts: [LiftReport]
    /// Single-frame jumps outside a cut, as times.
    public let pops: [Double]
    public let problems: [String]

    /// A move may run this far past a limit before it reads as rushed.
    public static let tolerance = 1.25
    /// The fastest the camera should turn at its peak, degrees per second.
    public static let turnLimit = 40.0

    public init(_ c: Choreography, rate: Double = 240) {
        let dt = 1 / rate
        var reports: [BeatReport] = []
        var problems: [String] = []
        for (i, beat) in c.beats.enumerated() {
            let name = beat.shot.label ?? (beat.isOverview ? (i == 0 ? "Opening" : "The whole slide") : "Shot \(i)")
            // The arrival's own pace belongs to the arrival; every other move is measured.
            let measured = i > 0 && beat.shot.move != .cut && beat.travel > 1e-3
            let peak = measured ? beat.peakRate : 0
            var turn = 0.0
            if measured {
                var t = beat.depart
                var last = c.basePose(at: t)
                while t < beat.land {
                    t = min(t + dt, beat.land)
                    let p = c.basePose(at: t)
                    let step = max(abs(p.yaw - last.yaw), abs(p.pitch - last.pitch), abs(p.roll - last.roll))
                    turn = max(turn, Double(degrees(step)) / dt)
                    last = p
                }
            }
            var emphasis: Float?
            // An emphasis its hold has no room for is left out, not cut short.
            if beat.shot.emphasis != .none && !beat.isOverview && c.emphasisSpan(i) != nil {
                var most: Float = 0
                var t = beat.land - 0.3
                while t < min(beat.leave + 0.1, c.duration) {
                    if let e = c.emphasis(at: t), e.beat == i { most = max(most, e.amount) }
                    t += dt
                }
                emphasis = most
            }
            reports.append(BeatReport(index: i, label: name, land: beat.land, travel: beat.travel, hold: beat.hold,
                                      move: beat.shot.move, isOverview: beat.isOverview, peakRate: peak, peakTurn: turn,
                                      emphasisPeak: emphasis))
            if peak > Choreography.peakRate * Self.tolerance {
                problems.append(name + String(format: ": rushed, %.1f e-folds/s at its peak (limit %.1f)", peak, Choreography.peakRate))
            }
            if turn > Self.turnLimit * Self.tolerance {
                problems.append(name + String(format: ": turns %.0f°/s at its peak (limit %.0f)", turn, Self.turnLimit))
            }
            if let e = emphasis, e < 0.95 {
                problems.append(name + ": its \(beat.shot.emphasis.rawValue)" + String(format: " only comes %.0f%% of the way in", e * 100))
            }
        }

        // The stage rising or settling: the camera's own move and the lift together.
        var lifts: [LiftReport] = []
        for m in c.lift?.moves(duration: c.duration) ?? [] {
            var most = 0.0
            var t = max(m.start, 0)
            var last = c.basePose(at: t)
            while t < min(m.end, c.duration) {
                t += dt
                let p = c.basePose(at: t)
                if c.cut(between: t - dt, and: t) == nil {
                    let h = Double(max(min(p.height, last.height), 1e-5))
                    let pan = Double((p.target - last.target).length) / h
                    let zoom = Double(abs(logf(max(p.height, 1e-5) / max(last.height, 1e-5))))
                    most = max(most, max(pan, zoom) / dt)
                }
                last = p
            }
            lifts.append(LiftReport(start: m.start, rising: m.rising, peakRate: most))
            if most > Choreography.peakRate * Self.tolerance {
                problems.append("the stage " + (m.rising ? "rising" : "settling")
                    + String(format: " at %.2f s: %.1f e-folds/s at its peak (limit %.1f)", m.start, most, Choreography.peakRate))
            }
        }

        // Jumps: a step between neighbouring samples far bigger than the steps around it.
        var steps: [Double] = []
        var times: [Double] = []
        var last = c.pose(at: 0)
        var t = dt
        while t <= c.duration {
            let p = c.pose(at: t)
            let h = Double(max(min(p.height, last.height), 1e-5))
            let pan = Double((p.target - last.target).length) / h
            let zoom = Double(abs(logf(max(p.height, 1e-5) / max(last.height, 1e-5))))
            let turn = Double(max(abs(p.yaw - last.yaw), abs(p.pitch - last.pitch), abs(p.roll - last.roll)))
            steps.append(max(pan, zoom, turn))
            times.append(t)
            last = p
            t += dt
        }
        var pops: [Double] = []
        let k = 6
        for i in steps.indices where steps[i] > 0.004 {
            let lo = max(0, i - k), hi = min(steps.count - 1, i + k)
            var around = (lo...hi).filter { $0 != i }.map { steps[$0] }
            around.sort()
            let median = around.isEmpty ? 0 : around[around.count / 2]
            guard steps[i] > 6 * max(median, 1e-5), c.cut(between: times[i] - dt, and: times[i]) == nil else { continue }
            if let previous = pops.last, times[i] - previous < 0.1 { continue }
            pops.append(times[i])
            problems.append(String(format: "the picture jumps at %.3f s", times[i]))
        }

        beats = reports
        self.lifts = lifts
        self.pops = pops
        self.problems = problems
    }

    /// One line per move, then the problems (or that there are none).
    public var summary: String {
        var lines: [String] = []
        for b in beats {
            let name = String(b.label.prefix(34)).padding(toLength: 34, withPad: " ", startingAt: 0)
            let move = b.move.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
            var line = String(format: "%2d ", b.index) + name
                + String(format: " land %6.2f  travel %4.2f  hold %4.2f  ", b.land, b.travel, b.hold) + move
            if b.peakRate > 0 { line += String(format: "  %.2f e-folds/s  %3.0f°/s", b.peakRate, b.peakTurn) }
            if let e = b.emphasisPeak { line += String(format: "  emphasis %.0f%%", e * 100) }
            lines.append(line)
        }
        for l in lifts {
            lines.append("   the stage " + (l.rising ? "rises   " : "settles ") + String(format: "at %6.2f  %.2f e-folds/s", l.start, l.peakRate))
        }
        lines.append(problems.isEmpty ? "motioncheck: no problems" : "motioncheck: \(problems.count) problem(s)")
        lines.append(contentsOf: problems.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }
}

extension Choreography.Beat {
    /// The move's peak zoom-and-pan rate in e-folds per second: how much of
    /// the view changes per second at its fastest. 0 for a cut.
    public var peakRate: Double {
        guard shot.move != .cut, travel > 1e-3 else { return 0 }
        let span = shot.move == .push ? Choreography.span(from: from, to: pose, move: .push, rho: Float(path.rho), canvasAspect: 1)
            : path.rho * abs(path.length)
        return span * Double(curve.peakSlope) / travel
    }
}
