import Foundation
import AetherLibavutil

/// Reel patch P-006: `AudioEffects` applied to Float32 PCM, in place.
///
/// The chain runs per frame (one sample of every channel) in the order the effects depend on each
/// other: the compressor measures the source as mastered, dialogue processing shapes what is left,
/// the volume boost scales it, and a brick-wall limiter (`PeakLimiter`'s, instant attack) takes
/// whatever the boost and the centre lift pushed over full scale. There is no lookahead anywhere: a
/// lookahead delays the audio and would move it against the video.
///
/// A value type with no buffers of its own: `process` neither allocates nor locks, so it can run on
/// a decode thread inside the caller's own lock. With `effects.isActive` false it returns before
/// touching a sample, so `.off` is a bit-exact passthrough.
struct AudioEffectsProcessor {

    // MARK: - Night mode

    /// A dialogue scene sits around −30 to −20 dBFS and an action peak near full scale, so −24 dBFS
    /// starts the compression just above speech. 3:1 takes a full-scale peak down 16 dB, which with
    /// the make-up gain puts it about 8 dB under where it was while speech comes up 8 dB.
    static let compressorThresholdDB: Float = -24
    static let compressorRatio: Float = 3
    /// Soft knee, so speech hovering at the threshold is not switched in and out of compression.
    static let compressorKneeDB: Float = 6
    static let compressorAttackSeconds: Double = 0.010
    /// Long enough not to pump on the gaps between words, short enough to let a quiet line after an
    /// explosion back up within a fraction of a second.
    static let compressorReleaseSeconds: Double = 0.200
    /// The level detector follows a rising peak at once and falls with this time constant, so the
    /// gain smoothing above is what shapes the attack and the detector does not ripple on bass.
    static let detectorReleaseSeconds: Double = 0.050
    static let makeupGainDB: Float = 8

    // MARK: - Dialogue

    /// +3 dB on the centre and −3 dB on every other channel: 6 dB in favour of speech without making
    /// the mix louder overall, which would only hand the limiter more work.
    static let centreLiftDB: Float = 3
    static let othersCutDB: Float = 3
    /// Peaking EQ on the stereo mid (or the mono) signal, centred on 2 kHz, where consonants carry
    /// intelligibility. Q 0.5 keeps more than half the boost (in dB) from 1 to 4 kHz and under 1 dB
    /// below 400 Hz, so voices come forward without the bass of the mix following them.
    static let speechBandCentreHz: Double = 2000
    static let speechBandQ: Double = 0.5
    static let speechBandGainDB: Double = 6
    /// Ambience and effects are mostly wide in a stereo mix and dialogue is mostly centred.
    static let sideCutDB: Float = 3

    /// Where dialogue lives in the channel order the PCM arrives in.
    struct ChannelRoles: Equatable, Sendable {
        let channelCount: Int
        /// Front centre, or nil for a layout without one (mono, stereo, 2.1).
        let centre: Int?

        init(channelCount: Int, centre: Int?) {
            self.channelCount = max(0, channelCount)
            self.centre = centre.flatMap { $0 >= 0 && $0 < channelCount ? $0 : nil }
        }

        /// Read off the layout the PCM is actually in, rather than assumed from a channel count:
        /// the bridge and the decoder both resample into FFmpeg layouts whose order differs by count
        /// (2.1 has no centre, 6.1(back) moves the back centre).
        init(layout: UnsafePointer<AVChannelLayout>) {
            let count = Int(layout.pointee.nb_channels)
            let centre = av_channel_layout_index_from_channel(layout, AV_CHAN_FRONT_CENTER)
            self.init(channelCount: count, centre: centre >= 0 ? Int(centre) : nil)
        }
    }

    /// How dialogue boost reaches the speech in a given layout.
    enum DialogueMode: Equatable {
        /// A layout with a front centre and channels besides it.
        case centre(Int)
        /// Front left and right with no centre: speech is the mid signal.
        case midSide(left: Int, right: Int)
        /// One channel: speech-band emphasis on it.
        case mono(Int)

        static func resolve(_ roles: ChannelRoles) -> DialogueMode? {
            if let centre = roles.centre, roles.channelCount >= 3 { return .centre(centre) }
            if roles.channelCount >= 2 { return .midSide(left: 0, right: 1) }
            if roles.channelCount == 1 { return .mono(0) }
            return nil
        }
    }

    private(set) var effects: AudioEffects
    let roles: ChannelRoles
    let sampleRate: Int
    private let dialogueMode: DialogueMode?

    private let detectorReleaseCoefficient: Float
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    /// Linear peak the compressor is reacting to.
    private var detectorEnvelope: Float = 0
    /// Gain reduction in force, in dB (positive = quieter).
    private var reductionDB: Float = 0
    private var speechEQ: Biquad
    private var limiter: PeakLimiter
    private var volume: Float

    init(effects: AudioEffects, sampleRate: Int, roles: ChannelRoles) {
        self.effects = effects
        self.roles = roles
        self.sampleRate = max(1, sampleRate)
        dialogueMode = DialogueMode.resolve(roles)
        let rate = Double(self.sampleRate)
        detectorReleaseCoefficient = Self.onePoleCoefficient(seconds: Self.detectorReleaseSeconds, sampleRate: rate)
        attackCoefficient = Self.onePoleCoefficient(seconds: Self.compressorAttackSeconds, sampleRate: rate)
        releaseCoefficient = Self.onePoleCoefficient(seconds: Self.compressorReleaseSeconds, sampleRate: rate)
        speechEQ = Biquad.peaking(centreHz: Self.speechBandCentreHz, q: Self.speechBandQ,
                                  gainDB: Self.speechBandGainDB, sampleRate: rate)
        limiter = PeakLimiter(sampleRate: self.sampleRate)
        volume = Self.linear(dB: effects.gainDecibels)
    }

    /// Change the effects without forgetting the envelopes, so a toggle mid-stream does not restart
    /// the compressor from silence.
    mutating func update(effects: AudioEffects) {
        self.effects = effects
        volume = Self.linear(dB: effects.gainDecibels)
    }

    /// Forget everything measured so far (a seek or restart: the next audio has nothing to do with the last).
    mutating func reset() {
        detectorEnvelope = 0
        reductionDB = 0
        speechEQ.reset()
        limiter.reset()
    }

    /// Process `frameCount` interleaved frames of `roles.channelCount` channels in place.
    mutating func process(interleaved samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard effects.isActive, roles.channelCount > 0, frameCount > 0 else { return }
        run(InterleavedSamples(base: samples, stride: roles.channelCount), frameCount: frameCount)
    }

    /// Process `frameCount` frames held one plane per channel, in place.
    mutating func process(planes: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard effects.isActive, roles.channelCount > 0, frameCount > 0,
              planes.count == roles.channelCount else { return }
        run(PlanarSamples(planes: planes), frameCount: frameCount)
    }

    /// What the limiter has done since the last call, for a log line.
    mutating func takeLimitedFrames() -> (frames: Int, deepestDB: Float) {
        limiter.takeLimitedFrames()
    }

    // MARK: - The chain

    private mutating func run<Samples: EffectSamples>(_ samples: Samples, frameCount: Int) {
        let channels = roles.channelCount
        let night = effects.nightMode
        let dialogue = effects.dialogueBoost ? dialogueMode : nil
        let centreLift = Self.linear(dB: Self.centreLiftDB)
        let othersCut = Self.linear(dB: -Self.othersCutDB)
        let sideCut = Self.linear(dB: -Self.sideCutDB)

        for frame in 0..<frameCount {
            var gain = volume
            if night {
                var peak: Float = 0
                for channel in 0..<channels { peak = max(peak, abs(samples[channel, frame])) }
                detectorEnvelope = peak > detectorEnvelope
                    ? peak
                    : detectorEnvelope + (peak - detectorEnvelope) * detectorReleaseCoefficient
                let target = Self.gainReductionDB(levelDB: Self.decibels(detectorEnvelope))
                let coefficient = target > reductionDB ? attackCoefficient : releaseCoefficient
                reductionDB += (target - reductionDB) * coefficient
                // Both decay geometrically through silence; stop them before they turn subnormal,
                // which costs a hundredfold per operation on Intel.
                if detectorEnvelope < 1e-9 { detectorEnvelope = 0 }
                if reductionDB < 1e-6 { reductionDB = 0 }
                gain *= Self.linear(dB: Self.makeupGainDB - reductionDB)
            }

            var outputPeak: Float = 0
            switch dialogue {
            case .centre(let centre)?:
                for channel in 0..<channels {
                    let y = samples[channel, frame] * gain * (channel == centre ? centreLift : othersCut)
                    samples[channel, frame] = y
                    outputPeak = max(outputPeak, abs(y))
                }
            case .midSide(let left, let right)?:
                let l = samples[left, frame] * gain
                let r = samples[right, frame] * gain
                let mid = speechEQ.process((l + r) * 0.5)
                let side = (l - r) * 0.5 * sideCut
                samples[left, frame] = mid + side
                samples[right, frame] = mid - side
                outputPeak = max(abs(mid + side), abs(mid - side))
                for channel in 0..<channels where channel != left && channel != right {
                    let y = samples[channel, frame] * gain
                    samples[channel, frame] = y
                    outputPeak = max(outputPeak, abs(y))
                }
            case .mono(let only)?:
                let y = speechEQ.process(samples[only, frame] * gain)
                samples[only, frame] = y
                outputPeak = abs(y)
            case nil:
                for channel in 0..<channels {
                    let y = samples[channel, frame] * gain
                    samples[channel, frame] = y
                    outputPeak = max(outputPeak, abs(y))
                }
            }

            let limit = limiter.gain(forFramePeak: outputPeak)
            if limit < 1 {
                for channel in 0..<channels { samples[channel, frame] *= limit }
            }
        }
    }

    // MARK: - Math

    /// Soft-knee gain computer: the reduction in dB for a detector level in dBFS.
    static func gainReductionDB(levelDB: Float) -> Float {
        let over = levelDB - compressorThresholdDB
        let slope = 1 - 1 / compressorRatio
        if 2 * over <= -compressorKneeDB { return 0 }
        if 2 * over >= compressorKneeDB { return slope * over }
        let into = over + compressorKneeDB / 2
        return slope * into * into / (2 * compressorKneeDB)
    }

    static func linear(dB: Float) -> Float { pow(10, dB / 20) }

    static func decibels(_ linear: Float) -> Float { linear > 1e-6 ? 20 * log10(linear) : -120 }

    static func onePoleCoefficient(seconds: Double, sampleRate: Double) -> Float {
        Float(1 - exp(-1 / (seconds * sampleRate)))
    }
}

// MARK: - Sample access

/// One sample of one channel, wherever the layout keeps it. Generic rather than a closure so the
/// per-sample access compiles to pointer arithmetic.
private protocol EffectSamples {
    subscript(channel: Int, frame: Int) -> Float { get nonmutating set }
}

private struct InterleavedSamples: EffectSamples {
    let base: UnsafeMutablePointer<Float>
    let stride: Int
    subscript(channel: Int, frame: Int) -> Float {
        get { base[frame * stride + channel] }
        nonmutating set { base[frame * stride + channel] = newValue }
    }
}

private struct PlanarSamples: EffectSamples {
    let planes: [UnsafeMutablePointer<Float>]
    subscript(channel: Int, frame: Int) -> Float {
        get { planes[channel][frame] }
        nonmutating set { planes[channel][frame] = newValue }
    }
}

// MARK: - Speech band filter

/// RBJ biquad, transposed direct form II.
struct Biquad {
    private let b0, b1, b2, a1, a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    /// Peaking EQ: `gainDB` at `centreHz`, bandwidth set by `q`. The centre is kept below Nyquist so
    /// an 8 kHz source still gets a valid filter.
    static func peaking(centreHz: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let f0 = min(centreHz, sampleRate * 0.45)
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(b0: Float((1 + alpha * a) / a0),
                      b1: Float(-2 * cosW0 / a0),
                      b2: Float((1 - alpha * a) / a0),
                      a1: Float(-2 * cosW0 / a0),
                      a2: Float((1 - alpha / a) / a0))
    }

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        // The state rings down to subnormals after the input goes silent.
        if abs(z1) < 1e-20 { z1 = 0 }
        if abs(z2) < 1e-20 { z2 = 0 }
        return y
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
