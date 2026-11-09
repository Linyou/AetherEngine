import Foundation

/// Reel patch P-006: night mode, dialogue boost and volume boost as a live setting.
///
/// The effects run on PCM, and where the engine holds PCM decides what a change costs. The software
/// and FFmpeg audio-only hosts decode every track themselves, so their decoder takes a change on the
/// next buffer. The loopback route stream-copies most codecs into segments AVPlayer decodes, so the
/// effects there exist only through a bridge chosen when the session is built, and the segments
/// already cut carry the old value: the change is a rebuild at the playhead, exactly as it is for
/// the audio delay (`setAudioDelay`).
extension AetherEngine {

    /// The audio effects in force for this session (`LoadOptions.audioEffects`).
    public var audioEffects: AudioEffects { loadedOptions.audioEffects }

    /// Change the audio effects while playback runs.
    ///
    /// The value is stored in the options every rebuild replays, so it survives an audio-track
    /// switch, a background return and a reload at position. Passing the value already in force does
    /// nothing. What a change costs, per route:
    ///
    /// - `.software`, and an audio-only session on FFmpeg: applied in place, then the decoded lead
    ///   (up to `AudioLookaheadPolicy.targetLeadSeconds`) is replaced by a seek to the current
    ///   position, so the change is heard at once instead of after the lead drains.
    /// - `.loopback`: a session-preserving reload (`reloadAtCurrentPosition()`). Turning effects on
    ///   moves stream-copied audio onto the bridge, and **E-AC-3 Atmos then plays as its 5.1 bed**;
    ///   turning them off brings the stream copy back.
    /// - An audio-only session on AVPlayer: the same reload, which moves it to FFmpeg.
    /// - `.remoteBypass`: AVPlayer decodes the origin itself; the value is kept for a later load.
    ///
    /// A session that cannot re-anchor (live without a DVR window) keeps the value and lets it arrive
    /// with the audio decoded from here on, or at the next rebuild the session makes on its own.
    public func setAudioEffects(_ effects: AudioEffects) {
        guard effects != loadedOptions.audioEffects else { return }
        setLoadedAudioEffects(effects)

        // Same reasoning as `setAudioDelay`: a session being rebuilt reads the options it is about
        // to apply, so the value is on its way rather than unavailable.
        guard state != .loading else {
            EngineLog.emit(
                "[AetherEngine] P-006: audio effects = \(effects) set while the session is being rebuilt; "
                + "the load in flight reads them from the options",
                category: .engine
            )
            return
        }

        let application = AudioEffectsPolicy.application(
            route: videoRoute, ffmpegAudioHost: audioHost != nil, effects: effects)
        switch application {
        case .keptForNextLoad:
            EngineLog.emit(
                "[AetherEngine] P-006: audio effects = \(effects), kept for the next load: this session's "
                + "audio never reaches the engine as PCM (route=\(videoRoute.rawValue))",
                category: .engine
            )
        case .alreadyInForce:
            EngineLog.emit(
                "[AetherEngine] P-006: audio effects = \(effects); AVPlayer decodes this session untouched, "
                + "which is already what off means",
                category: .engine
            )
        case .decoder:
            softwareHost?.setAudioEffects(effects)
            audioHost?.setAudioEffects(effects)
            EngineLog.emit(
                "[AetherEngine] P-006: audio effects = \(effects) in the decoder (route=\(videoRoute.rawValue))",
                category: .engine
            )
            reanchorForAudioEffects()
        case .rebuild:
            EngineLog.emit(
                "[AetherEngine] P-006: audio effects = \(effects) need a rebuild at the playhead "
                + "(route=\(videoRoute.rawValue))",
                category: .engine
            )
            reanchorForAudioEffects()
        }
    }

    /// Bring a change to the playhead, folding the presses that arrive while one is in flight into a
    /// catch-up pass, as `setAudioDelay` does: every press writes `loadedOptions.audioEffects` (and
    /// the decoder) synchronously, so a pass delivers whatever is newest when it runs.
    private func reanchorForAudioEffects() {
        guard Self.audioDelayRecutIsPossible(state: state, isLive: isLive, liveWindow: liveWindow) else {
            EngineLog.emit(
                "[AetherEngine] P-006: audio effects = \(loadedOptions.audioEffects) stand, but this session "
                + "cannot re-anchor at the playhead (state=\(state), live=\(isLive)); they arrive with the "
                + "audio decoded from here on",
                category: .engine
            )
            return
        }
        guard !audioEffectsReanchorInFlight else {
            EngineLog.emit(
                "[AetherEngine] P-006: audio effects = \(loadedOptions.audioEffects) folded into the "
                + "re-anchor already in flight",
                category: .engine
            )
            return
        }
        audioEffectsReanchorInFlight = true
        Task { @MainActor in
            defer { self.audioEffectsReanchorInFlight = false }
            var delivered = self.loadedOptions.audioEffects
            await self.reanchorAudioEffectsOnce()
            while delivered != self.loadedOptions.audioEffects {
                guard Self.audioDelayRecutIsPossible(
                    state: self.state, isLive: self.isLive, liveWindow: self.liveWindow) else { return }
                delivered = self.loadedOptions.audioEffects
                await self.reanchorAudioEffectsOnce()
            }
        }
    }

    /// One pass, decided on the route as it is NOW: a rebuild can move an audio-only session from
    /// AVPlayer to FFmpeg, after which a further change is a decoder change.
    private func reanchorAudioEffectsOnce() async {
        let effects = loadedOptions.audioEffects
        switch AudioEffectsPolicy.application(route: videoRoute, ffmpegAudioHost: audioHost != nil,
                                              effects: effects) {
        case .decoder:
            softwareHost?.setAudioEffects(effects)
            audioHost?.setAudioEffects(effects)
            await seek(to: positionForSessionRebuild, origin: .host)
        case .rebuild:
            if let refusal = sessionReloadRefusal {
                EngineLog.emit(
                    "[AetherEngine] P-006: audio effects = \(effects) stand, but this session cannot be "
                    + "rebuilt in place (\(refusal.rawValue)); they arrive at the next rebuild",
                    category: .engine
                )
                return
            }
            do {
                try await reloadAtCurrentPosition()
                EngineLog.emit("[AetherEngine] P-006: rebuilt at the playhead with audio effects = \(effects)",
                               category: .engine)
            } catch is CancellationError {
                EngineLog.emit(
                    "[AetherEngine] P-006: the rebuild was superseded by a newer load, which reads the "
                    + "effects in force (\(loadedOptions.audioEffects)) from the options",
                    category: .engine
                )
            } catch {
                EngineLog.emit(
                    "[AetherEngine] P-006: the rebuild at the playhead failed (\(error)); audio effects = "
                    + "\(effects) stand and arrive at the next rebuild",
                    category: .engine
                )
            }
        case .keptForNextLoad, .alreadyInForce:
            return
        }
    }
}

/// Reel patch P-006: what applying a change of `AudioEffects` takes on a given route. Pure, so the
/// rule is testable without a session.
enum AudioEffectsPolicy {

    enum Application: Equatable {
        /// The session's decoder produces PCM; it takes the change itself.
        case decoder
        /// The PCM stage is fixed when the session is built (the loopback bridge, or AVPlayer decoding
        /// an audio-only source), so the change is a rebuild at the playhead.
        case rebuild
        /// AVPlayer decodes the origin itself (`.remoteBypass`) or there is no session.
        case keptForNextLoad
        /// Turning effects off on an AVPlayer audio-only session, which never had them.
        case alreadyInForce
    }

    static func application(route: VideoRoute, ffmpegAudioHost: Bool, effects: AudioEffects) -> Application {
        switch route {
        case .software: return .decoder
        case .loopback: return .rebuild
        case .audio:
            if ffmpegAudioHost { return .decoder }
            return effects.isActive ? .rebuild : .alreadyInForce
        case .remoteBypass, .none: return .keptForNextLoad
        }
    }
}
