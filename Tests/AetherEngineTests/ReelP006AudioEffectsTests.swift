import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Reel patch P-006: night mode, dialogue boost and volume boost on PCM.
@Suite("Reel P-006 audio effects DSP")
struct ReelP006AudioEffectsDSPTests {

    static let rate = 48_000

    // MARK: - Signals

    /// `seconds` of a sine at `amplitude`, interleaved over `channels` with per-channel gains.
    static func sine(hz: Double, amplitude: Float, seconds: Double, channels: Int,
                     channelGains: [Float]? = nil) -> [Float] {
        let frames = Int(seconds * Double(rate))
        var out = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let v = amplitude * Float(sin(2 * Double.pi * hz * Double(i) / Double(rate)))
            for c in 0..<channels { out[i * channels + c] = v * (channelGains?[c] ?? 1) }
        }
        return out
    }

    static func process(_ samples: inout [Float], channels: Int, effects: AudioEffects,
                        centre: Int? = nil) {
        var processor = AudioEffectsProcessor(
            effects: effects, sampleRate: rate,
            roles: .init(channelCount: channels, centre: centre))
        let frames = samples.count / channels
        samples.withUnsafeMutableBufferPointer { buffer in
            // Odd chunk sizes, the way the decoder and the bridge hand frames over.
            var start = 0
            while start < frames {
                let n = min(997, frames - start)
                processor.process(interleaved: buffer.baseAddress! + start * channels, frameCount: n)
                start += n
            }
        }
    }

    static func rms(_ samples: [Float], channel: Int, of channels: Int, frames: Range<Int>) -> Float {
        var sum: Double = 0
        for i in frames { let x = Double(samples[i * channels + channel]); sum += x * x }
        return Float((sum / Double(frames.count)).squareRoot())
    }

    static func peak(_ samples: [Float], frames: Range<Int>, channels: Int) -> Float {
        var p: Float = 0
        for i in frames { for c in 0..<channels { p = max(p, abs(samples[i * channels + c])) } }
        return p
    }

    // MARK: - Off

    @Test(".off is a bit-exact passthrough, on every path")
    func offIsBitExact() {
        var generator = SystemRandomNumberGenerator()
        let original = (0..<(4096 * 6)).map { _ in Float.random(in: -1.5...1.5, using: &generator) }
        var interleaved = original
        Self.process(&interleaved, channels: 6, effects: .off, centre: 2)
        #expect(interleaved.map(\.bitPattern) == original.map(\.bitPattern))

        // Planar: the same rule.
        var left = (0..<1024).map { original[$0 * 6] }
        var right = (0..<1024).map { original[$0 * 6 + 1] }
        let before = left + right
        var processor = AudioEffectsProcessor(effects: .off, sampleRate: Self.rate,
                                              roles: .init(channelCount: 2, centre: nil))
        left.withUnsafeMutableBufferPointer { p0 in
            right.withUnsafeMutableBufferPointer { p1 in
                processor.process(planes: [p0.baseAddress!, p1.baseAddress!], frameCount: 1024)
            }
        }
        #expect((left + right).map(\.bitPattern) == before.map(\.bitPattern))
        #expect(!AudioEffects.off.isActive)
    }

    // MARK: - Night mode

    @Test("night mode brings a loud burst down and a quiet passage up")
    func compressorNarrowsTheRange() {
        // quiet (-40 dBFS) 1 s, loud (-3 dBFS) 1 s, quiet again 1 s.
        let quiet = Self.sine(hz: 1000, amplitude: 0.01, seconds: 1, channels: 2)
        let loud = Self.sine(hz: 1000, amplitude: 0.708, seconds: 1, channels: 2)
        let input = quiet + loud + quiet
        var output = input
        Self.process(&output, channels: 2, effects: AudioEffects(nightMode: true), centre: nil)

        let r = Self.rate
        // Steady state of each passage (past attack and release).
        let quietWindow = (r / 2)..<r
        let loudWindow = (r + r / 4)..<(2 * r)
        let afterWindow = (2 * r + r / 2)..<(3 * r)
        #expect(Self.rms(output, channel: 0, of: 2, frames: quietWindow)
                > Self.rms(input, channel: 0, of: 2, frames: quietWindow) * 2)          // +8 dB make-up
        // -3 dBFS is 21 dB over the threshold: 14 dB off, 8 dB of make-up back, 6 dB down net.
        let burstDrop = 20 * log10(Self.peak(output, frames: loudWindow, channels: 2)
                                   / Self.peak(input, frames: loudWindow, channels: 2))
        #expect(burstDrop < -5 && burstDrop > -7)
        #expect(Self.rms(output, channel: 0, of: 2, frames: afterWindow)
                > Self.rms(input, channel: 0, of: 2, frames: afterWindow) * 2)
        // The range between the two passages shrank: 37 dB in, well under 25 dB out.
        let inRange = Self.rms(input, channel: 0, of: 2, frames: loudWindow)
            / Self.rms(input, channel: 0, of: 2, frames: quietWindow)
        let outRange = Self.rms(output, channel: 0, of: 2, frames: loudWindow)
            / Self.rms(output, channel: 0, of: 2, frames: quietWindow)
        #expect(20 * log10(outRange) < 25)
        #expect(20 * log10(inRange) > 36)
        // The onset transient, before the attack has acted, is caught by the limiter.
        #expect(Self.peak(output, frames: 0..<(3 * r), channels: 2) <= 1.0)
    }

    @Test("the gain computer is flat below the knee and 3:1 above it")
    func gainComputer() {
        #expect(AudioEffectsProcessor.gainReductionDB(levelDB: -40) == 0)
        #expect(AudioEffectsProcessor.gainReductionDB(levelDB: -27.5) == 0)
        let above = AudioEffectsProcessor.gainReductionDB(levelDB: -6)
        #expect(abs(above - 12) < 0.001)   // 18 dB over, 2/3 of it taken off
        // Continuous through the knee.
        let lower = AudioEffectsProcessor.gainReductionDB(levelDB: -27)
        let upper = AudioEffectsProcessor.gainReductionDB(levelDB: -21)
        #expect(abs(lower - 0) < 0.001)
        #expect(abs(upper - 2) < 0.001)
    }

    // MARK: - Gain and limiter

    @Test("volume boost with the limiter never exceeds full scale", arguments: [3, 6, 9, 12] as [Float])
    func boostNeverClips(gain: Float) {
        var generator = SystemRandomNumberGenerator()
        // Full-scale noise and a full-scale square, the worst cases for a boost.
        var noise = (0..<(Self.rate * 6)).map { _ in Float.random(in: -1...1, using: &generator) }
        var square = (0..<(Self.rate * 2)).map { Float(($0 / 50) % 2 == 0 ? 1 : -1) }
        let effects = AudioEffects(nightMode: true, dialogueBoost: true, gainDecibels: gain)
        Self.process(&noise, channels: 6, effects: effects, centre: 2)
        Self.process(&square, channels: 2, effects: AudioEffects(gainDecibels: gain))
        #expect(noise.allSatisfy { abs($0) <= 1.0 })
        #expect(square.allSatisfy { abs($0) <= 1.0 })
        #expect(square.allSatisfy { abs($0) <= PeakLimiter.threshold + 1e-6 })
    }

    @Test("volume boost raises a quiet signal by the asked amount")
    func boostIsExact() {
        let input = Self.sine(hz: 440, amplitude: 0.05, seconds: 0.5, channels: 2)
        var output = input
        Self.process(&output, channels: 2, effects: AudioEffects(gainDecibels: 9))
        let frames = 0..<(Self.rate / 2)
        let ratio = Self.rms(output, channel: 1, of: 2, frames: frames) / Self.rms(input, channel: 1, of: 2, frames: frames)
        #expect(abs(20 * log10(ratio) - 9) < 0.01)
    }

    @Test("the gain is clamped to 0...12 dB, and a NaN is no boost")
    func gainClamp() {
        #expect(AudioEffects(gainDecibels: 30).gainDecibels == AudioEffects.maxGainDecibels)
        #expect(AudioEffects(gainDecibels: -6).gainDecibels == 0)
        #expect(AudioEffects(gainDecibels: .nan).gainDecibels == 0)
        var effects = AudioEffects()
        effects.gainDecibels = 99
        #expect(effects.gainDecibels == 12)
        #expect(effects.isActive)
        effects.gainDecibels = 0
        #expect(!effects.isActive)
        #expect(AudioEffects(gainDecibels: 30) == AudioEffects(gainDecibels: 12))
    }

    // MARK: - Dialogue

    @Test("dialogue boost lifts the 5.1 centre 6 dB against left and right")
    func centreBoost() {
        let input = Self.sine(hz: 300, amplitude: 0.1, seconds: 0.5, channels: 6)
        var output = input
        Self.process(&output, channels: 6, effects: AudioEffects(dialogueBoost: true), centre: 2)
        let frames = 0..<(Self.rate / 2)
        let centre = Self.rms(output, channel: 2, of: 6, frames: frames)
        let left = Self.rms(output, channel: 0, of: 6, frames: frames)
        let right = Self.rms(output, channel: 1, of: 6, frames: frames)
        #expect(abs(20 * log10(centre / left) - 6) < 0.05)
        #expect(abs(20 * log10(centre / right) - 6) < 0.05)
        // And without raising the mix as a whole: the centre comes up 3, the rest down 3.
        let inCentre = Self.rms(input, channel: 2, of: 6, frames: frames)
        #expect(abs(20 * log10(centre / inCentre) - 3) < 0.05)
    }

    @Test("stereo dialogue boost emphasises the centred speech band and lowers the sides")
    func stereoDialogue() {
        let frames = (Self.rate / 4)..<(Self.rate / 2)
        func gainDB(hz: Double, gains: [Float]) -> Float {
            let input = Self.sine(hz: hz, amplitude: 0.1, seconds: 0.5, channels: 2, channelGains: gains)
            var output = input
            Self.process(&output, channels: 2, effects: AudioEffects(dialogueBoost: true))
            return 20 * log10(Self.rms(output, channel: 0, of: 2, frames: frames)
                              / Self.rms(input, channel: 0, of: 2, frames: frames))
        }
        // Centred (L = R): +6 dB at 2 kHz, little at 100 Hz.
        #expect(abs(gainDB(hz: 2000, gains: [1, 1]) - 6) < 0.3)
        #expect(gainDB(hz: 1000, gains: [1, 1]) > 3)
        #expect(gainDB(hz: 4000, gains: [1, 1]) > 3)
        #expect(abs(gainDB(hz: 100, gains: [1, 1])) < 1)
        // Wide (L = -R): pure side, down 3 dB.
        #expect(abs(gainDB(hz: 100, gains: [1, -1]) + 3) < 0.1)
    }

    @Test("dialogue boost on mono emphasises the speech band")
    func monoDialogue() {
        let frames = (Self.rate / 4)..<(Self.rate / 2)
        let input = Self.sine(hz: 2000, amplitude: 0.1, seconds: 0.5, channels: 1)
        var output = input
        Self.process(&output, channels: 1, effects: AudioEffects(dialogueBoost: true))
        let ratio = Self.rms(output, channel: 0, of: 1, frames: frames) / Self.rms(input, channel: 0, of: 1, frames: frames)
        #expect(abs(20 * log10(ratio) - 6) < 0.3)
    }

    @Test("interleaved and planar processing produce the same samples")
    func planarMatchesInterleaved() {
        let channels = 6
        let input = Self.sine(hz: 700, amplitude: 0.9, seconds: 0.25, channels: channels,
                              channelGains: [1, 0.5, 1, 0.2, 0.3, 0.3])
        var interleaved = input
        let effects = AudioEffects(nightMode: true, dialogueBoost: true, gainDecibels: 6)
        Self.process(&interleaved, channels: channels, effects: effects, centre: 2)

        let frames = input.count / channels
        var planes = (0..<channels).map { c in (0..<frames).map { input[$0 * channels + c] } }
        var processor = AudioEffectsProcessor(effects: effects, sampleRate: Self.rate,
                                              roles: .init(channelCount: channels, centre: 2))
        let pointers = (0..<channels).map { c in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { pointers.forEach { $0.deallocate() } }
        for c in 0..<channels { pointers[c].update(from: planes[c], count: frames) }
        var start = 0
        while start < frames {
            let n = min(997, frames - start)
            processor.process(planes: pointers.map { $0 + start }, frameCount: n)
            start += n
        }
        for c in 0..<channels { planes[c] = Array(UnsafeBufferPointer(start: pointers[c], count: frames)) }
        for i in 0..<frames {
            for c in 0..<channels { #expect(planes[c][i] == interleaved[i * channels + c]) }
        }
    }

    // MARK: - Layouts

    @Test("the centre is read off the actual FFmpeg layout")
    func rolesFromLayouts() {
        func roles(_ name: String) -> AudioEffectsProcessor.ChannelRoles {
            var layout = AVChannelLayout()
            #expect(av_channel_layout_from_string(&layout, name) >= 0)
            defer { av_channel_layout_uninit(&layout) }
            return AudioEffectsProcessor.ChannelRoles(layout: &layout)
        }
        #expect(roles("stereo").centre == nil)
        #expect(roles("2.1").centre == nil)
        #expect(roles("5.1").centre == 2)
        #expect(roles("6.1(back)").centre == 2)
        #expect(roles("7.1").centre == 2)
        #expect(roles("mono").centre == 0)
        #expect(AudioEffectsProcessor.DialogueMode.resolve(roles("mono")) == .mono(0))
        #expect(AudioEffectsProcessor.DialogueMode.resolve(roles("2.1")) == .midSide(left: 0, right: 1))
        #expect(AudioEffectsProcessor.DialogueMode.resolve(roles("5.1")) == .centre(2))
    }
}

/// Reel patch P-006: the option rides the reload machinery and the routing rules.
@Suite("Reel P-006 audio effects options")
struct ReelP006AudioEffectsOptionsTests {

    @Test("audioEffects defaults to off and is a known, correctable field")
    func knownAndCorrectable() {
        #expect(LoadOptions().audioEffects == .off)
        #expect(SessionOptionCorrection.knownFields.contains("audioEffects"))
        #expect(!SessionOptionCorrection.loadIdentityFields.contains("audioEffects"))
        #expect(Mirror(reflecting: LoadOptions()).children.compactMap(\.label)
                == SessionOptionCorrection.knownFields)

        let base = LoadOptions()
        var proposed = base
        proposed.audioEffects = AudioEffects(nightMode: true, gainDecibels: 6)
        #expect(base != proposed)
        #expect(SessionOptionCorrection.refusedFields(from: base, to: proposed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed) == ["audioEffects"])
        let split = SessionOptionCorrection.partitionChanges(["audioEffects"], sessionOwnsTransport: true)
        #expect(split.applied == ["audioEffects"])

        // A round trip back to the same value is no change at all.
        var back = proposed
        back.audioEffects = .off
        #expect(back == base)
        #expect(SessionOptionCorrection.changedFields(from: base, to: back).isEmpty)
    }

    @Test("a correction installs the effects on an engine without a session")
    @MainActor
    func correctionInstallsTheEffects() throws {
        let engine = try AetherEngine()
        var corrected = engine.loadedOptions
        corrected.audioEffects = AudioEffects(dialogueBoost: true)
        engine.applySessionOptionCorrection(corrected)
        #expect(engine.audioEffects == AudioEffects(dialogueBoost: true))
        // The live setter writes the same field and does nothing more without a session.
        engine.setAudioEffects(AudioEffects(gainDecibels: 3))
        #expect(engine.loadedOptions.audioEffects == AudioEffects(gainDecibels: 3))
    }

    @Test("where a change lands, per route")
    func policy() {
        let on = AudioEffects(nightMode: true)
        #expect(AudioEffectsPolicy.application(route: .software, ffmpegAudioHost: false, effects: on) == .decoder)
        #expect(AudioEffectsPolicy.application(route: .software, ffmpegAudioHost: false, effects: .off) == .decoder)
        #expect(AudioEffectsPolicy.application(route: .loopback, ffmpegAudioHost: false, effects: on) == .rebuild)
        #expect(AudioEffectsPolicy.application(route: .loopback, ffmpegAudioHost: false, effects: .off) == .rebuild)
        #expect(AudioEffectsPolicy.application(route: .audio, ffmpegAudioHost: true, effects: on) == .decoder)
        #expect(AudioEffectsPolicy.application(route: .audio, ffmpegAudioHost: false, effects: on) == .rebuild)
        #expect(AudioEffectsPolicy.application(route: .audio, ffmpegAudioHost: false, effects: .off) == .alreadyInForce)
        #expect(AudioEffectsPolicy.application(route: .remoteBypass, ffmpegAudioHost: false, effects: on) == .keptForNextLoad)
        #expect(AudioEffectsPolicy.application(route: .none, ffmpegAudioHost: false, effects: on) == .keptForNextLoad)
    }
}

/// Reel patch P-006: the loopback route's PCM stage, the bridge between decoder and encoder.
@Suite("Reel P-006 audio effects in the bridge")
struct ReelP006AudioBridgeEffectsTests {

    /// Raw S16 PCM in, the bridge's FLAC or E-AC-3 out, decoded back to Float for measuring.
    static func roundTrip(channels: Int32, amplitudes: [Float], effects: AudioEffects,
                          mode: AudioBridgeMode) throws -> (channelRMS: [Float], peak: Float, codec: AVCodecID) {
        let rate: Int32 = 48_000
        let par = avcodec_parameters_alloc()!
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        par.pointee.sample_rate = rate
        par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        par.pointee.bits_per_coded_sample = 16
        par.pointee.block_align = channels * 2
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        let tb = AVRational(num: 1, den: rate)

        let bridge = try AudioBridge(srcCodecpar: par, srcTimeBase: tb, mode: mode, audioEffects: effects)
        defer { bridge.close() }
        let outPar = try #require(bridge.encoderCodecpar)

        // Decoder for what the bridge emits.
        let codec = try #require(avcodec_find_decoder(outPar.pointee.codec_id))
        var dec: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&dec) }
        #expect(avcodec_parameters_to_context(dec, outPar) >= 0)
        #expect(avcodec_open2(dec, codec, nil) >= 0)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }

        var decoded: [[Float]] = Array(repeating: [], count: Int(channels))
        func drain(_ packets: [UnsafeMutablePointer<AVPacket>]) {
            for pkt in packets {
                _ = avcodec_send_packet(dec, pkt)
                while avcodec_receive_frame(dec, frame) >= 0, let f = frame {
                    let n = Int(f.pointee.nb_samples)
                    let fmt = AVSampleFormat(rawValue: f.pointee.format)
                    for c in 0..<Int(channels) {
                        for i in 0..<n {
                            let v: Float
                            switch fmt {
                            case AV_SAMPLE_FMT_FLTP:
                                v = UnsafeRawPointer(f.pointee.extended_data[c]!).assumingMemoryBound(to: Float.self)[i]
                            case AV_SAMPLE_FMT_S16:
                                v = Float(UnsafeRawPointer(f.pointee.data.0!).assumingMemoryBound(to: Int16.self)[i * Int(channels) + c]) / 32_768
                            case AV_SAMPLE_FMT_S32:
                                v = Float(Double(UnsafeRawPointer(f.pointee.data.0!).assumingMemoryBound(to: Int32.self)[i * Int(channels) + c]) / 2_147_483_648)
                            default:
                                v = .nan
                            }
                            decoded[c].append(v)
                        }
                    }
                }
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            }
        }

        // One second of a 300 Hz sine, per-channel amplitudes, in 1024-frame packets.
        let framesPerPacket = 1024
        var written = 0
        while written < Int(rate) {
            let pkt = try #require(trackedPacketAlloc())
            let bytes = framesPerPacket * Int(channels) * 2
            #expect(av_new_packet(pkt, Int32(bytes)) >= 0)
            let pcm = UnsafeMutableRawPointer(pkt.pointee.data!).assumingMemoryBound(to: Int16.self)
            for i in 0..<framesPerPacket {
                let s = sin(2 * Double.pi * 300 * Double(written + i) / Double(rate))
                for c in 0..<Int(channels) {
                    pcm[i * Int(channels) + c] = Int16((Double(amplitudes[c]) * s * 32_767).rounded())
                }
            }
            pkt.pointee.pts = Int64(written)
            pkt.pointee.dts = Int64(written)
            pkt.pointee.duration = Int64(framesPerPacket)
            drain(try bridge.feed(packet: pkt))
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            written += framesPerPacket
        }
        drain(bridge.flush())

        // Skip the first 0.25 s (codec priming, attack), measure the rest.
        let start = Int(rate) / 4
        var rmsPerChannel: [Float] = []
        var peak: Float = 0
        for c in 0..<Int(channels) {
            let tail = decoded[c].dropFirst(start).prefix(Int(rate) / 2)
            let sum = tail.reduce(0.0) { $0 + Double($1) * Double($1) }
            rmsPerChannel.append(Float((sum / Double(max(tail.count, 1))).squareRoot()))
            peak = max(peak, decoded[c].map { abs($0) }.max() ?? 0)
        }
        return (rmsPerChannel, peak, outPar.pointee.codec_id)
    }

    @Test("a +9 dB boost reaches the FLAC the bridge encodes, and only with the option on")
    func boostInFLAC() throws {
        let plain = try Self.roundTrip(channels: 2, amplitudes: [0.1, 0.1], effects: .off, mode: .lossless)
        let boosted = try Self.roundTrip(channels: 2, amplitudes: [0.1, 0.1],
                                         effects: AudioEffects(gainDecibels: 9), mode: .lossless)
        #expect(plain.codec == AV_CODEC_ID_FLAC)
        let ratio = boosted.channelRMS[0] / plain.channelRMS[0]
        #expect(abs(20 * log10(ratio) - 9) < 0.1)
        #expect(boosted.peak <= 1.0)
    }

    @Test("a full-scale source boosted 9 dB stays under full scale in the bridge's FLAC")
    func boostLimitedInFLAC() throws {
        let loud = try Self.roundTrip(channels: 2, amplitudes: [1.0, 1.0],
                                      effects: AudioEffects(gainDecibels: 9), mode: .lossless)
        #expect(loud.peak <= PeakLimiter.threshold + 0.001)
    }

    @Test("dialogue boost lifts the centre of a 5.1 source through the E-AC-3 bridge")
    func centreThroughEAC3() throws {
        let result = try Self.roundTrip(channels: 6, amplitudes: [0.1, 0.1, 0.1, 0, 0.1, 0.1],
                                        effects: AudioEffects(dialogueBoost: true), mode: .surroundCompat)
        #expect(result.codec == AV_CODEC_ID_EAC3)
        let lift = 20 * log10(result.channelRMS[2] / result.channelRMS[0])
        #expect(abs(lift - 6) < 1)
        let plain = try Self.roundTrip(channels: 6, amplitudes: [0.1, 0.1, 0.1, 0, 0.1, 0.1],
                                       effects: .off, mode: .surroundCompat)
        #expect(abs(20 * log10(plain.channelRMS[2] / plain.channelRMS[0])) < 0.5)
    }
}
