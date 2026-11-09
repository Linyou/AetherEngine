import Foundation

/// Reel patch P-007: the time arithmetic of single-frame stepping, kept apart from the hosts so it
/// can be tested without a session.
///
/// Stepping is decided on frames, not on a clock plus a nominal duration, wherever the engine knows
/// the frames: a paused clock rarely sits exactly on a frame, a variable-rate or deinterlaced source
/// has no single duration, and a clock moved by `1/fps` from wherever it stands drifts against the
/// frames until a step shows the same picture twice or skips one.
enum FrameStep {

    /// Two presentation times this close are the same frame. Far below any frame interval (8.3 ms at
    /// 120 fps) and far above the rounding a time picks up crossing `CMTime` timescales.
    static let sameFrameTolerance = 0.0005

    /// How far past a frame's own timestamp a stopped clock is parked to show it. A display layer
    /// presents a frame once the clock has reached its timestamp, and a timestamp converted to another
    /// timescale can land a nanosecond below it.
    static let presentationPad = 0.0001

    /// Where a seek-based step lands relative to the frame interval it aims at, as a fraction of a
    /// frame. A target on the frame's own timestamp can round to just below it and show the frame
    /// before; an eighth in is clear of that and still well inside the interval.
    static let seekTargetNudge = 0.125

    /// The duration of one frame of a source declaring `frameRate`, or nil for a rate no picture
    /// stream has (unknown, zero, or a container's placeholder).
    static func frameDuration(frameRate: Double?) -> Double? {
        guard let frameRate, frameRate.isFinite, frameRate >= 1, frameRate <= 1000 else { return nil }
        return 1 / frameRate
    }

    /// The frame interval the presented frames actually have: the median gap between consecutive
    /// distinct timestamps. Measured rather than declared because a field-rate deinterlacer doubles
    /// the declared rate. Nil with fewer than two frames.
    static func measuredFrameDuration(presentations: [Double]) -> Double? {
        let times = distinctSorted(presentations)
        guard times.count >= 2 else { return nil }
        var gaps: [Double] = []
        gaps.reserveCapacity(times.count - 1)
        for i in 1..<times.count { gaps.append(times[i] - times[i - 1]) }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    /// The frame on screen for a stopped clock: the newest one whose timestamp the clock has reached.
    static func displayedFrame(presentations: [Double], clock: Double) -> Double? {
        distinctSorted(presentations).last { $0 <= clock + sameFrameTolerance }
    }

    /// Where a forward step by `count` lands: the `count`th frame after the one on screen, or nil when
    /// that frame has not been presented to the renderer yet.
    static func forwardTarget(presentations: [Double], clock: Double, count: Int) -> Double? {
        guard count > 0 else { return nil }
        let ahead = distinctSorted(presentations).filter { $0 > clock + sameFrameTolerance }
        return ahead.count >= count ? ahead[count - 1] : nil
    }

    /// The first frame at or after `threshold`, which after a seek is the frame the seek was aimed at.
    static func firstFrame(atOrAfter threshold: Double, presentations: [Double]) -> Double? {
        distinctSorted(presentations).first { $0 >= threshold - sameFrameTolerance }
    }

    /// The decode threshold for a step by `count` frames (negative steps back) from the frame on
    /// screen, when it is done as an accurate seek: half a frame before the frame wanted, so that
    /// frame passes the post-seek skip and the one before it does not, whichever way the timestamps
    /// round.
    static func seekThreshold(displayed: Double, count: Int, frameDuration: Double) -> Double {
        max(0, displayed + (Double(count) - 0.5) * frameDuration)
    }

    /// A step done as a seek where the frames are not visible to the engine (AVPlayer, when its item
    /// cannot step): `count` frame durations from `current`, nudged into the interval of the frame it
    /// aims at. Negative `count` steps back.
    static func seekTarget(current: Double, count: Int, frameDuration: Double) -> Double {
        max(0, current + (Double(count) + seekTargetNudge) * frameDuration)
    }

    private static func distinctSorted(_ times: [Double]) -> [Double] {
        var sorted = times.filter(\.isFinite).sorted()
        var write = 0
        for value in sorted where write == 0 || value - sorted[write - 1] > sameFrameTolerance {
            sorted[write] = value
            write += 1
        }
        sorted.removeSubrange(write...)
        return sorted
    }
}
