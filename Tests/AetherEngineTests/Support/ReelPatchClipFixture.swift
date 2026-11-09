import Foundation
import AVFoundation
import CoreMedia

/// Reel patches P-006 / P-007: a short generated clip with a picture that changes every frame and a
/// steady tone, for tests that need a session on a real route.
///
/// 30 fps H.264 (`frames` frames, 128x72, each frame a flat grey two levels above the last) and stereo
/// AAC carrying a 440 Hz sine at `toneAmplitude`. Written the way `ItemSwapStillTests` writes its
/// fixture: one loop feeding whichever track is ready, never waiting on either.
enum ReelPatchClipFixture {

    static let frameRate: Int32 = 30
    static let toneAmplitude: Double = 0.1

    struct WriterFailed: Error {
        let status: Int
        let error: Error?
        let state: String
    }

    static func write(frames: Int = 150) async throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("reel-patch-clip-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 72,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 72,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            throw WriterFailed(status: writer.status.rawValue, error: writer.error, state: "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var formatOut: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &formatOut)
        guard let audioFormat = formatOut else {
            throw WriterFailed(status: writer.status.rawValue, error: nil, state: "audio format")
        }

        let chunk = 4800
        let totalChunks = (frames * 48_000 / Int(frameRate) + chunk - 1) / chunk
        var frame = 0
        var chunks = 0
        var videoDone = false
        var audioDone = false
        var lastProgress = ContinuousClock.now
        var idlePolls = 0
        while !(videoDone && audioDone), writer.status == .writing,
              ContinuousClock.now - lastProgress < .seconds(20) || idlePolls < 1_000 {
            var fed = false
            if !videoDone, video.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, nil, &buffer)
                if let pixels = buffer {
                    CVPixelBufferLockBaseAddress(pixels, [])
                    memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 2 % 256),
                           CVPixelBufferGetDataSize(pixels))
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    if adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                           timescale: frameRate)) {
                        frame += 1
                        fed = true
                    }
                }
                if frame >= frames {
                    video.markAsFinished()
                    videoDone = true
                }
            }
            if !audioDone, audio.isReadyForMoreMediaData {
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: chunk * 4, blockAllocator: nil,
                    customBlockSource: nil, offsetToData: 0, dataLength: chunk * 4,
                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                var sample: CMSampleBuffer?
                if let data = block {
                    var pcm = [Int16](repeating: 0, count: chunk * 2)
                    for i in 0..<chunk {
                        let t = Double(chunks * chunk + i) / 48_000
                        let v = Int16((toneAmplitude * sin(2 * Double.pi * 440 * t) * 32_767).rounded())
                        pcm[2 * i] = v
                        pcm[2 * i + 1] = v
                    }
                    pcm.withUnsafeBytes { raw in
                        _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: data,
                                                          offsetIntoDestination: 0, dataLength: chunk * 4)
                    }
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                        allocator: nil, dataBuffer: data, formatDescription: audioFormat,
                        sampleCount: chunk,
                        presentationTimeStamp: CMTime(value: CMTimeValue(chunks * chunk), timescale: 48_000),
                        packetDescriptions: nil, sampleBufferOut: &sample)
                }
                if let sample, audio.append(sample) {
                    chunks += 1
                    fed = true
                }
                if chunks >= totalChunks {
                    audio.markAsFinished()
                    audioDone = true
                }
            }
            if fed {
                lastProgress = .now
                idlePolls = 0
            } else {
                idlePolls += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        guard videoDone, audioDone else {
            let state = "video \(frame)/\(frames) ready=\(video.isReadyForMoreMediaData), "
                + "audio \(chunks)/\(totalChunks) ready=\(audio.isReadyForMoreMediaData)"
            writer.cancelWriting()
            throw WriterFailed(status: writer.status.rawValue, error: writer.error, state: state)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw WriterFailed(status: writer.status.rawValue, error: writer.error, state: "finishWriting")
        }
        return file
    }
}
