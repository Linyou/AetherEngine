import Foundation

/// Reel patch P-007: single-frame stepping, for a viewer who pauses to look at one frame or to find
/// the exact frame of a cut.
///
/// Each route steps the way its presenter can:
///
/// - `.loopback` / `.remoteBypass`: AVPlayer's own `AVPlayerItem.step(byCount:)` where the item
///   says it can step in that direction. Where it cannot, a zero-tolerance seek by the declared
///   frame duration (`sourceVideoFrameRate`), nudged into the interval of the frame it aims at.
/// - `.software`: forward parks the stopped synchronizer on the next frame the display layer already
///   holds. A step the layer cannot serve (backward, or past what it holds) is an accurate seek to
///   half a frame before the frame wanted, then the same parking on the first frame the seek decodes.
///
/// Either way the engine clock (`currentTime`, `clock.sourceTime`) publishes the frame landed on.
extension AetherEngine {

    /// Whether `stepFrame(by:)` can do anything now: a paused or playing VOD session with a picture,
    /// on a route that can step. Live sessions cannot. Audio-only sessions have nothing to step.
    public var canStepFrames: Bool {
        guard !isLive else { return false }
        switch state {
        case .playing, .paused: break
        default: return false
        }
        switch videoRoute {
        case .software:
            return softwareHost?.canStepFrames ?? false
        case .loopback, .remoteBypass:
            guard nativeHost != nil, let item = currentAVPlayerItem else { return false }
            return item.canStepForward || item.canStepBackward || declaredFrameDuration != nil
        case .audio, .none:
            return false
        }
    }

    /// Show the frame `count` frames after (positive) or before (negative) the one on screen. Pauses
    /// first if playing, since a step is a paused operation. Returns once the frame is on screen and
    /// the clock reports it, or does nothing when `canStepFrames` is false.
    ///
    /// On `.software` a step past the last frame ends the session the way playing into the end does.
    public func stepFrame(by count: Int) async {
        guard count != 0 else { return }
        guard canStepFrames else {
            EngineLog.emit(
                "[AetherEngine] P-007 stepFrame(by: \(count)) ignored: this session cannot step "
                + "(state=\(state), route=\(videoRoute.rawValue), live=\(isLive))",
                category: .engine
            )
            return
        }
        if state == .playing { pause() }
        switch videoRoute {
        case .software:
            await stepSoftwareFrames(count)
        case .loopback, .remoteBypass:
            await stepNativeFrames(count)
        case .audio, .none:
            return
        }
    }

    /// One frame of the source as declared, nil when the probe found no usable rate.
    var declaredFrameDuration: Double? { FrameStep.frameDuration(frameRate: sourceVideoFrameRate) }

    private func stepNativeFrames(_ count: Int) async {
        guard let host = nativeHost else { return }
        if await host.stepFrames(by: count) { return }
        guard let frame = declaredFrameDuration else {
            EngineLog.emit(
                "[AetherEngine] P-007 the item did not step by \(count) and the source declares no frame rate "
                + "to seek by",
                category: .engine
            )
            return
        }
        let target = FrameStep.seekTarget(current: currentTime, count: count, frameDuration: frame)
        EngineLog.emit(
            "[AetherEngine] P-007 the item did not step by \(count); seeking by \(count) frame(s) to "
            + "\(String(format: "%.4f", target))s",
            category: .engine
        )
        await seek(to: duration > 0 ? min(target, duration) : target, origin: .host)
    }

    private func stepSoftwareFrames(_ count: Int) async {
        guard let host = softwareHost else { return }
        // A forward step into frames the layer already holds is a move of the stopped clock.
        if count > 0, host.presentHeldFrame(forwardBy: count) { return }
        guard let frame = host.presentedFrameDuration ?? declaredFrameDuration,
              let displayed = host.displayedFrameSourceSeconds(),
              let clock = host.clockSourceSeconds else {
            EngineLog.emit("[AetherEngine] P-007 step by \(count): no frame interval known", category: .engine)
            return
        }
        // Everything else is an accurate seek to just before the frame wanted, then that frame.
        let threshold = FrameStep.seekThreshold(displayed: displayed, count: count, frameDuration: frame)
        // The seek speaks the engine's own axis and the threshold is on the source axis; the step is
        // the distance between them, so it is applied as a delta and no axis is converted.
        let target = max(0, currentTime + (threshold - clock))
        let loadGen = loadGeneration
        await seek(to: target, origin: .host)
        guard loadGeneration == loadGen, softwareHost === host, state == .paused else { return }
        if !(await host.presentFrameAfterSeek(atOrAfter: threshold)) {
            EngineLog.emit("[AetherEngine] P-007 step by \(count) did not present a frame", category: .engine)
        }
    }
}
