import Foundation

/// A stretch of the video where the stage rises into the top of the frame.
public struct LiftSpan: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Seconds from the start when the stage starts to rise.
    public var start: Double
    /// When it has settled back down; nil stays up to the end.
    public var end: Double?

    public init(id: UUID = UUID(), start: Double, end: Double?) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// Room for you: the slide, its camera and its titles rise into the top of
/// the frame and leave the bottom clear, for a talking head laid over the
/// video afterwards (green screen in Edits or Premiere). Each span rises in
/// and settles back on its own, and whatever the camera is doing carries on
/// through it: every framing is solved again for the part of the frame left
/// above the room, and the camera eases between the two.
public struct Lift: Codable, Hashable, Sendable {
    /// How much of the frame's height stays clear at the bottom.
    public var room: Float
    public var spans: [LiftSpan]

    public init(room: Float = Lift.defaultRoom, spans: [LiftSpan] = []) {
        self.room = room
        self.spans = spans
    }

    /// Two-fifths of a 9:16 frame: room for head and shoulders under the slide.
    public static let defaultRoom: Float = 0.42
    public static let roomRange: ClosedRange<Float> = 0.25...0.6
    /// Seconds the stage takes to rise, and to settle back down.
    public static let rise: Double = 1.4
    /// Spans closer together than this rise as one: the stage never dips for a moment.
    public static let join: Double = 0.4

    /// Spans written out: `whole`, or `start-end` pairs separated by commas,
    /// an empty end staying up to the end (`4-10,14-`). Nil if it doesn't read.
    public init?(spec: String, room: Float = Lift.defaultRoom) {
        self.init(room: room)
        if spec == "whole" {
            spans = [LiftSpan(start: 0, end: nil)]
            return
        }
        for part in spec.split(separator: ",") {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
            guard ends.count == 2, let start = Double(ends[0]) else { return nil }
            if !ends[1].isEmpty && Double(ends[1]) == nil { return nil }
            spans.append(LiftSpan(start: start, end: Double(ends[1])))
        }
        if spans.isEmpty { return nil }
    }

    public var isEmpty: Bool { spans.isEmpty }

    /// The part of the canvas framings sit in while the stage is up: the
    /// platform's own margins, above the room.
    public func safe(_ base: SafeArea) -> SafeArea {
        SafeArea(top: base.top, bottom: max(base.bottom, min(max(room, Self.roomRange.lowerBound), Self.roomRange.upperBound)),
                 left: base.left, right: base.right)
    }

    /// The spans as they play: in order, the ones that touch or nearly touch
    /// joined, each ending (nil: at the end) no earlier than it starts.
    public func stretches(duration: Double) -> [(start: Double, end: Double?)] {
        var out: [(start: Double, end: Double?)] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            let start = max(s.start, 0)
            let end = s.end.map { max($0, start) }.flatMap { $0 >= duration - 0.05 ? nil : $0 }
            if let last = out.last, last.end.map({ start <= $0 + Self.join }) ?? true {
                let joined: Double? = last.end.flatMap { a in end.map { max(a, $0) } }
                out[out.count - 1].end = joined
            } else {
                out.append((start, end))
            }
        }
        return out
    }

    /// How far the stage has risen at `t`, 0 (down) … 1 (up). A span from the
    /// first moment is up from the first frame; one to the end stays up.
    /// A span too short for a full rise and fall rises and settles quicker.
    public func amount(at t: Double, duration: Double) -> Float {
        var most: Float = 0
        for s in stretches(duration: duration) {
            let ramp = Self.ramp(s)
            let up: Float = s.start <= 0.05 ? 1 : Curves.settle(Float((t - s.start) / ramp))
            let down: Float = s.end.map { 1 - Curves.settle(Float((t - ($0 - ramp)) / ramp)) } ?? 1
            most = max(most, min(up, down))
        }
        return most
    }

    /// When the stage is on the move: each rise and each settle, in order.
    public func moves(duration: Double) -> [(start: Double, end: Double, rising: Bool)] {
        stretches(duration: duration).flatMap { s -> [(start: Double, end: Double, rising: Bool)] in
            let ramp = Self.ramp(s)
            var out: [(start: Double, end: Double, rising: Bool)] = []
            if s.start > 0.05 { out.append((s.start, s.start + ramp, true)) }
            if let end = s.end { out.append((end - ramp, end, false)) }
            return out
        }
    }

    /// The shortest span the editor makes: room for a quick rise and settle.
    public static let shortest: Double = 1.6

    private static func ramp(_ s: (start: Double, end: Double?)) -> Double {
        max(min(rise, ((s.end ?? .infinity) - s.start) / 2), 1e-3)
    }
}

extension CameraPose {
    /// Between two poses of the same shot: the aim slides and the view
    /// scales evenly, as `w` goes from 0 (`a`) to 1 (`b`).
    public static func blend(_ a: CameraPose, _ b: CameraPose, _ w: Float) -> CameraPose {
        if w <= 0 { return a }
        if w >= 1 { return b }
        return CameraPose(target: lerp(a.target, b.target, w),
                          height: expf(lerp(logf(max(a.height, 1e-6)), logf(max(b.height, 1e-6)), w)),
                          yaw: lerp(a.yaw, b.yaw, w), pitch: lerp(a.pitch, b.pitch, w), roll: lerp(a.roll, b.roll, w),
                          fov: lerp(a.fov, b.fov, w), aperture: lerp(a.aperture, b.aperture, w))
    }
}
