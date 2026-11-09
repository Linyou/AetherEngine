import Foundation

/// Reel patch P-006: listening aids applied to the decoded audio, for a viewer who has to keep the
/// volume down or cannot follow the dialogue.
///
/// Every field works on PCM, so the effects exist only where the engine holds PCM:
///
/// - `.software` and FFmpeg audio-only sessions decode every track to PCM anyway, and take a change
///   on the next buffer (`AetherEngine.setAudioEffects(_:)`).
/// - `.loopback` stream-copies AAC, AC-3, E-AC-3, FLAC and ALAC untouched. While any effect is on,
///   those are decoded and re-encoded through the audio bridge instead (FLAC, or E-AC-3 for
///   surround in `.surroundCompat`), so a change there costs a session-preserving reload. **Dolby
///   Atmos in E-AC-3 (JOC) is lost on that path**: the objects only survive a stream copy, and the
///   bridge carries the 5.1 bed. TrueHD Atmos and DTS:X rendered by `objectAudioRendering` keep
///   their objects, the effects are applied to the rendered bed.
/// - `.remoteBypass` hands AVPlayer the origin and never sees a sample, so there the value is kept
///   for a later load and does nothing.
///
/// `.off` (the default) leaves every route exactly as it was: no bridge is forced and the audio is
/// not touched, not even by a limiter.
public struct AudioEffects: Sendable, Equatable {

    /// Dynamic range compression for late-night listening: loud passages come down, quiet ones come
    /// up, so the volume can stay low without losing the dialogue to the explosions.
    public var nightMode: Bool

    /// Raise speech against everything else: on surround the centre channel is lifted 6 dB against
    /// the others, on stereo and mono the speech band (about 1 to 4 kHz) of the mid signal is
    /// emphasised and the side signal lowered.
    public var dialogueBoost: Bool

    /// Volume boost in dB, for sources mastered too quietly. Meant for 0, 3, 6 or 9; clamped to
    /// `0...maxGainDecibels`. A brick-wall limiter after the boost keeps the output under full scale.
    public var gainDecibels: Float {
        didSet {
            let clamped = Self.clampedGain(gainDecibels)
            if clamped != gainDecibels { gainDecibels = clamped }
        }
    }

    /// Largest volume boost the engine applies.
    public static let maxGainDecibels: Float = 12

    /// No effect at all.
    public static let off = AudioEffects()

    /// Whether any effect is on. False is a bit-exact passthrough, and on `.loopback` it is also what
    /// keeps stream copy (and with it E-AC-3 Atmos) available.
    public var isActive: Bool { nightMode || dialogueBoost || gainDecibels > 0 }

    public init(nightMode: Bool = false, dialogueBoost: Bool = false, gainDecibels: Float = 0) {
        self.nightMode = nightMode
        self.dialogueBoost = dialogueBoost
        self.gainDecibels = Self.clampedGain(gainDecibels)
    }

    /// A non-finite value (an unset slider) is no boost rather than a NaN in every sample.
    static func clampedGain(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(max(decibels, 0), maxGainDecibels)
    }
}

extension AudioEffects: CustomStringConvertible {
    public var description: String {
        guard isActive else { return "off" }
        var parts: [String] = []
        if nightMode { parts.append("night") }
        if dialogueBoost { parts.append("dialogue") }
        // Exact, not rounded: a reload names a changed field by comparing these descriptions.
        if gainDecibels > 0 { parts.append("+\(gainDecibels) dB") }
        return parts.joined(separator: "+")
    }
}
