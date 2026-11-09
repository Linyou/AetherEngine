import Foundation
import Testing
import AVFoundation
import CoreMedia
@testable import AetherEngine

/// Reel patch P-007: the time arithmetic of frame stepping.
@Suite("Reel P-007 frame step math")
struct ReelP007FrameStepMathTests {

    static let d = 1.0 / 24
    /// Frames on a 24 fps grid starting at 10 s.
    static let grid = (0..<10).map { 10 + Double($0) * d }

    @Test("a declared rate becomes a frame duration only when it is a picture rate")
    func declaredDuration() {
        #expect(FrameStep.frameDuration(frameRate: 25) == 0.04)
        #expect(FrameStep.frameDuration(frameRate: nil) == nil)
        #expect(FrameStep.frameDuration(frameRate: 0) == nil)
        #expect(FrameStep.frameDuration(frameRate: .infinity) == nil)
        #expect(FrameStep.frameDuration(frameRate: 90_000) == nil)
    }

    @Test("the measured interval is the median gap, so one hole does not move it")
    func measuredDuration() {
        var times = Self.grid
        times.remove(at: 4)   // a dropped frame
        let measured = FrameStep.measuredFrameDuration(presentations: times.shuffled())
        #expect(abs((measured ?? 0) - Self.d) < 1e-9)
        #expect(FrameStep.measuredFrameDuration(presentations: [1.0]) == nil)
        // Duplicates (the same frame reported twice) are one frame.
        let single = FrameStep.measuredFrameDuration(presentations: [1.0, 1.0, 1.0 + Self.d]) ?? 0
        #expect(abs(single - Self.d) < 1e-9)
    }

    @Test("the frame on screen is the newest one the stopped clock has reached")
    func displayed() {
        // Clock parked a hair past frame 3 (the presentation pad), and mid-way through frame 3.
        #expect(FrameStep.displayedFrame(presentations: Self.grid, clock: Self.grid[3] + FrameStep.presentationPad)
                == Self.grid[3])
        #expect(FrameStep.displayedFrame(presentations: Self.grid, clock: Self.grid[3] + Self.d * 0.9)
                == Self.grid[3])
        // A clock that rounded a nanosecond under the frame still names it.
        #expect(FrameStep.displayedFrame(presentations: Self.grid, clock: Self.grid[3] - 1e-9) == Self.grid[3])
        #expect(FrameStep.displayedFrame(presentations: Self.grid, clock: 9) == nil)
    }

    @Test("a forward step lands on the next frame, wherever in the interval the clock stands")
    func forward() {
        // Anywhere short of the next frame by more than the same-frame tolerance.
        for offset in [0, FrameStep.presentationPad, Self.d * 0.5, Self.d - 2 * FrameStep.sameFrameTolerance] {
            let clock = Self.grid[3] + offset
            #expect(FrameStep.forwardTarget(presentations: Self.grid, clock: clock, count: 1) == Self.grid[4])
            #expect(FrameStep.forwardTarget(presentations: Self.grid, clock: clock, count: 3) == Self.grid[6])
        }
        // Repeated steps from the parked clock walk the grid one frame at a time, without drift.
        var clock = Self.grid[0] + FrameStep.presentationPad
        for expected in Self.grid.dropFirst() {
            let next = FrameStep.forwardTarget(presentations: Self.grid.shuffled(), clock: clock, count: 1)
            #expect(next == expected)
            clock = (next ?? 0) + FrameStep.presentationPad
        }
        // Past what the renderer holds: no target yet, so the host decodes more.
        #expect(FrameStep.forwardTarget(presentations: Self.grid, clock: Self.grid[8], count: 2) == nil)
        #expect(FrameStep.forwardTarget(presentations: Self.grid, clock: Self.grid[3], count: 0) == nil)
    }

    @Test("a seek-based step decodes from half a frame before the frame wanted, either way")
    func seekThreshold() {
        let threshold = FrameStep.seekThreshold(displayed: Self.grid[5], count: -1, frameDuration: Self.d)
        #expect(threshold < Self.grid[4])
        #expect(threshold > Self.grid[3])
        // The first frame the seek decodes at or past it is the one wanted.
        #expect(FrameStep.firstFrame(atOrAfter: threshold, presentations: Self.grid) == Self.grid[4])
        let three = FrameStep.seekThreshold(displayed: Self.grid[5], count: -3, frameDuration: Self.d)
        #expect(FrameStep.firstFrame(atOrAfter: three, presentations: Self.grid) == Self.grid[2])
        let ahead = FrameStep.seekThreshold(displayed: Self.grid[2], count: 4, frameDuration: Self.d)
        #expect(FrameStep.firstFrame(atOrAfter: ahead, presentations: Self.grid) == Self.grid[6])
        // Never before the start.
        #expect(FrameStep.seekThreshold(displayed: 0.01, count: -1, frameDuration: Self.d) == 0)
        // A frame exactly on the threshold, give or take rounding, still counts.
        #expect(FrameStep.firstFrame(atOrAfter: Self.grid[4] + 1e-7, presentations: Self.grid) == Self.grid[4])
    }

    @Test("a seek-based step lands inside the interval of the frame it aims at")
    func seekTarget() {
        let onFrame = FrameStep.seekTarget(current: Self.grid[5], count: -1, frameDuration: Self.d)
        #expect(onFrame > Self.grid[4] && onFrame < Self.grid[5])
        let forward = FrameStep.seekTarget(current: Self.grid[5], count: 2, frameDuration: Self.d)
        #expect(forward > Self.grid[7] && forward < Self.grid[8])
        // From a target it set itself, the next step is exact again.
        let again = FrameStep.seekTarget(current: onFrame, count: -1, frameDuration: Self.d)
        #expect(again > Self.grid[3] && again < Self.grid[4])
        #expect(FrameStep.seekTarget(current: 0.01, count: -1, frameDuration: Self.d) == 0)
    }

    @Test("the renderer reports the frames it handed over, and forgets them at a flush")
    @MainActor
    func rendererRecordsHandedFrames() {
        let renderer = SampleBufferRenderer()
        func pixelBuffer() -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
            return buffer!
        }
        // Decode order with a B-frame run; reported ascending once handed over.
        for seconds in [0.00, 0.12, 0.04, 0.08, 0.20, 0.16] {
            renderer.enqueue(pixelBuffer: pixelBuffer(), pts: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        renderer.drainReorderBuffer()
        #expect(renderer.handedOverPresentationTimes() == [0.00, 0.04, 0.08, 0.12, 0.16, 0.20])
        renderer.flush(removingDisplayedImage: false)
        #expect(renderer.handedOverPresentationTimes().isEmpty)
    }
}

/// Reel patches P-006 and P-007 on real sessions: a generated clip on the software and native routes.
@Suite("Reel P-006/P-007 on a live session", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ReelPatchSessionTests {

    static let frame = 1.0 / Double(ReelPatchClipFixture.frameRate)

    private func softwareSession(_ file: URL, effects: AudioEffects = .off) async throws
        -> (AetherEngine, SoftwarePlaybackHost, AetherPlayerView) {
        let engine = try AetherEngine()
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        var options = LoadOptions()
        options.preferredDecodePath = .software
        options.audioEffects = effects
        _ = try await engine.load(url: file, options: options)
        #expect(engine.playbackBackend == .software)
        let host = try #require(engine.softwareHost)
        try await waitFor { host.isVideoReadyForDisplay }
        return (engine, host, view)
    }

    @Test("software route: steps forward and back land on exact frames and the clock reports them")
    func softwareStepping() async throws {
        let file = try await ReelPatchClipFixture.write()
        defer { try? FileManager.default.removeItem(at: file) }
        let (engine, host, _) = try await softwareSession(file)
        defer { engine.stop() }

        try await waitFor { engine.currentTime > 1.0 }
        // A step while playing pauses first.
        await engine.stepFrame(by: 1)
        #expect(engine.state == .paused)
        #expect(!host.isPlaying)
        #expect(engine.canStepFrames)

        let start = try #require(host.displayedFrameSourceSeconds())
        // On the frame grid: the step parks the clock on a frame's own timestamp.
        #expect(abs(start / Self.frame - (start / Self.frame).rounded()) < 0.01)

        func expectOn(_ frames: Int, _ note: Comment) {
            let wanted = start + Double(frames) * Self.frame
            #expect(abs(engine.currentTime - wanted) < 0.002, "\(note): at \(engine.currentTime), wanted \(wanted)")
            #expect(abs((host.displayedFrameSourceSeconds() ?? -1) - wanted) < 0.002, note)
            #expect(engine.state == .paused, note)
        }

        await engine.stepFrame(by: 1)
        expectOn(1, "+1")
        await engine.stepFrame(by: 1)
        expectOn(2, "+1 again")
        await engine.stepFrame(by: -1)
        expectOn(1, "-1")
        await engine.stepFrame(by: 12)
        expectOn(13, "+12, past what the layer holds")
        await engine.stepFrame(by: -3)
        expectOn(10, "-3")

        // The clock really stands still between steps.
        let parked = engine.currentTime
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.currentTime == parked)

        // And play resumes from the stepped frame.
        engine.play()
        try await waitFor { engine.currentTime > parked + 0.3 }
        #expect(engine.state == .playing)
    }

    @Test("native route: a step moves the clock by about one frame each way")
    func nativeStepping() async throws {
        let file = try await ReelPatchClipFixture.write()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: file)
        #expect(engine.videoRoute == .loopback)
        try await waitFor { engine.currentTime > 1.0 }
        engine.pause()
        try await waitFor { engine.state == .paused }
        #expect(engine.canStepFrames)

        let before = engine.currentTime
        await engine.stepFrame(by: 1)
        let forward = engine.currentTime - before
        #expect(forward > Self.frame * 0.5 && forward < Self.frame * 1.6, "forward \(forward)")
        let mid = engine.currentTime
        await engine.stepFrame(by: -1)
        let backward = mid - engine.currentTime
        #expect(backward > Self.frame * 0.5 && backward < Self.frame * 1.6, "backward \(backward)")
        #expect(engine.state == .paused)
    }

    @Test("a live session or no session cannot step, and asking does nothing")
    func refusals() async throws {
        let engine = try AetherEngine()
        #expect(!engine.canStepFrames)
        await engine.stepFrame(by: 1)
        #expect(engine.state == .idle)
    }

    // MARK: - P-006 on sessions

    @Test("software route: setAudioEffects reaches the decoded audio at once")
    func softwareLiveEffects() async throws {
        let file = try await ReelPatchClipFixture.write(frames: 240)
        defer { try? FileManager.default.removeItem(at: file) }
        let (engine, host, _) = try await softwareSession(file)
        defer { engine.stop() }

        let meter = BufferMeter()
        host.audioTapSink = { meter.record($0) }
        try await waitFor { meter.count(phase: 0) >= 10 }
        meter.phase = 1
        engine.setAudioEffects(AudioEffects(gainDecibels: 9))
        #expect(engine.audioEffects == AudioEffects(gainDecibels: 9))
        #expect(host.audioEffects == AudioEffects(gainDecibels: 9))
        try await waitFor { meter.count(phase: 1) >= 20 }
        host.audioTapSink = nil

        let before = try #require(meter.medianRMS(phase: 0))
        let after = try #require(meter.medianRMS(phase: 1, dropFirst: 4))
        #expect(abs(20 * log10(after / before) - 9) < 0.5, "before \(before) after \(after)")
        #expect(engine.state == .playing)
    }

    @Test("loopback route: effects move stream-copied AAC onto the bridge, off keeps the copy")
    func loopbackRouting() async throws {
        let file = try await ReelPatchClipFixture.write()
        defer { try? FileManager.default.removeItem(at: file) }

        let plain = try AetherEngine()
        _ = try await plain.load(url: file)
        #expect(plain.videoRoute == .loopback)
        #expect(plain.audioDelivery == .streamCopy)
        plain.stop()

        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.audioEffects = AudioEffects(nightMode: true)
        _ = try await engine.load(url: file, options: options)
        #expect(engine.videoRoute == .loopback)
        #expect(engine.audioDelivery == .bridged)
    }
}

/// RMS of each tapped audio buffer, tagged with the phase the test was in when it arrived.
private final class BufferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _phase = 0
    private var entries: [(phase: Int, rms: Float)] = []

    var phase: Int {
        get { lock.withLock { _phase } }
        set { lock.withLock { _phase = newValue } }
    }

    func record(_ buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        guard !data.isEmpty else { return }
        data.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        let rms = Float((data.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(data.count)).squareRoot())
        lock.withLock { entries.append((_phase, rms)) }
    }

    func count(phase: Int) -> Int { lock.withLock { entries.filter { $0.phase == phase }.count } }

    func medianRMS(phase: Int, dropFirst: Int = 0) -> Float? {
        let values = lock.withLock { entries.filter { $0.phase == phase }.map(\.rms) }
            .dropFirst(dropFirst).sorted()
        return values.isEmpty ? nil : values[values.count / 2]
    }
}
