# Reel's patches to AetherEngine

This directory is AetherEngine **7.44.0** (commit `e5ea8dac56a6962d7f6793fc80b7c84caa61b7af`,
https://github.com/superuser404notfound/AetherEngine), vendored on 2026-10-23 so Reel can fix
playback-quality issues that only the engine can. Apart from the patches below, the tree is
the release byte for byte (minus `.git`, `.github`, `.spi.yml`, `.swiftpm`), so a diff against a
clean checkout of the tag is exactly this list.

## Licence

AetherEngine is LGPL-3.0 with an App Store / DRM exception (see `LICENSE`). The exception
covers distribution through app stores **on the condition that the complete corresponding
source, including modifications, stays public**. Before any TestFlight or App Store build:
push this tree to a public fork (e.g. `github.com/<owner>/AetherEngine`, branch
`reel/7.44.0`, tag `7.44.0-reel.N`) and link that exact tag from Reel's Acknowledgements.

The traits Reel enables bring in LibTrueHD (MIT, with the truehdd crates under Apache-2.0 and
their NOTICE) and FFmpeg's DTS:X height decoding. These formats may be subject to patent
licensing; review before public distribution.

## Patches

| ID | Purpose | Files | Tests | Upstream |
| --- | --- | --- | --- | --- |
| P-001 | Enable `TrueHDObjectAudio`, `DTSXObjectAudio` and `DualLayerDolbyVision` by default: XcodeGen cannot pass package traits, so the vendored package turns them on itself | `Package.swift` | n/a | Reel-only |
| P-002 | A true 24.000 fps source asks the display for 24 Hz instead of 23.976, which repeated a frame about every 42 s on Apple TV with Match Content | `Sources/AetherEngine/Display/FrameRateSnap.swift` | `FrameRateSnapTests` | Upstreamable |
| P-004 | `LoadOptions.subtitleForwardPrefetch` (default true) lets a host turn off the #151 subtitle forward prefetch, a second full read of a Matroska source 75 s ahead that halved throughput from a hard-disk server; Reel turns it off when its producer window covers the lead | `PlayerState.swift`, `AetherEngine+Subtitles.swift`, `Subtitles/SubtitleDrainStopReason.swift`; the field is listed in `AetherEngine+ReloadWithOptions.swift` (`knownFields`) and `docs/api.md` (added with P-006) | n/a (option default keeps upstream behaviour); `Issue460ReloadWithOptionsTests` field inventory and `PublicAPIDocumentationTests` cover the listing | Upstreamable |
| P-005 | `LoadOptions.vodSegmentTargetSeconds` (default nil = 4 s) sets the keyframe-aligned VOD cut target (2–6 s). AVPlayer waits for about 1.5 segments before playing, so shorter segments halve the data a seek or start waits for on short-GOP remuxes | `PlayerState.swift`, `AetherEngine+Loading.swift`, `Video/HLSVideoEngine.swift`, `Video/HLSVideoEngine+SegmentPlanning.swift`; listed in `knownFields` and `docs/api.md` like P-004 | segment planning suites pass (default unchanged); field inventory and doc coverage as P-004 | Upstreamable |
| P-006 | Audio effects: `LoadOptions.audioEffects` / `AetherEngine.setAudioEffects(_:)` take an `AudioEffects` (night mode: −24 dBFS 3:1 soft-knee compressor, 10 ms / 200 ms, +8 dB make-up; dialogue boost: 5.1 / 7.1 centre +6 dB against the rest, stereo and mono a 2 kHz speech-band lift on the mid with the side 3 dB down; volume boost 0–12 dB), all followed by a brick-wall limiter (`PeakLimiter`), in an allocation-free processor over Float32 PCM. Software and FFmpeg audio-only sessions run it in `AudioDecoder` and take a change live (re-anchored by a seek to the playhead). Loopback runs it in `AudioBridge` / `SpatialAudioBridge`; while it is active codecs that would stream-copy (AAC, AC-3, E-AC-3, FLAC, ALAC) are bridged instead, so E-AC-3 JOC Atmos plays as its 5.1 bed, and a change is a session-preserving reload. Audio-only sessions leave AVPlayer for FFmpeg while active; `.remoteBypass` cannot apply it. `.off` (default) is a bit-exact passthrough and changes no routing | new `Audio/AudioEffects.swift`, `Audio/AudioEffectsProcessor.swift`, `AetherEngine+AudioEffects.swift`; `Audio/Spatial/PeakLimiter.swift` (`gain(forFramePeak:)`, additive), `Audio/AudioDecoder.swift`, `Audio/AudioBridge.swift`, `Audio/Spatial/SpatialAudioBridge.swift`, `Audio/AudioPlaybackHost.swift`, `Native/SoftwarePlaybackHost.swift`, `Video/HLSVideoEngine.swift`, `Video/HLSVideoEngine+AudioRoute.swift`, `Video/HLSVideoEngine+SpatialAudio.swift`, `AetherEngine.swift`, `AetherEngine+Loading.swift`, `AetherEngine+ReloadWithOptions.swift` (`knownFields`), `PlayerState.swift`, `docs/api.md` | `ReelP006AudioEffectsDSPTests`, `ReelP006AudioEffectsOptionsTests`, `ReelP006AudioBridgeEffectsTests` (FLAC and E-AC-3 round trips), `ReelPatchSessionTests` (software live change, loopback bridge forcing; fixture `Support/ReelPatchClipFixture.swift`) | Upstreamable |
| P-007 | Frame stepping: `AetherEngine.stepFrame(by:)` (async, pauses first) and `canStepFrames` (VOD with a picture). Software: a forward step parks the stopped synchronizer on the next frame the display layer already holds (`SampleBufferRenderer` records the frame times it hands over); anything else (backward, or past what the layer holds, which stops taking frames under a stopped clock) is an accurate seek to half a frame before the frame wanted, then the loops decode under the pause until that frame is in and the clock is parked on it. Native: `AVPlayerItem.step(byCount:)` when the item can step, else a zero-tolerance seek by the declared frame duration (`sourceVideoFrameRate`); loopback items report they cannot step, so that is the seek. The engine clock publishes the landed frame | new `FrameStep.swift`, `AetherEngine+FrameStep.swift`; `Native/SoftwarePlaybackHost.swift`, `Native/NativeAVPlayerHost.swift`, `Renderer/SampleBufferRenderer.swift`, `docs/api.md` | `ReelP007FrameStepMathTests`, `ReelPatchSessionTests` (exact frames on the software route forward and back, about one frame each way on loopback) | Upstreamable |
| P-008 | Module-local `Date` `<=` / `>=`: Xcode 27.2 back-deploys Foundation's, calling the system's copy on an OS that reports 27.2, which early 27.2 betas lack (a crash in `AVIOReader.isPastReadDeadline` on visionOS 24N5093f) | new `DateComparison.swift` | n/a | Reel-only (temporary) |

## Rebasing onto a new release

1. Clone the new tag next to a clone of the old one.
2. `diff -ruN <old-tag> Packages/AetherEngine -x .git` gives this patch set; check it matches the table.
3. Copy the new tag over this directory (keeping `PATCHES.md`), re-apply each patch, and update the base version above.
4. `swift test --package-path Packages/AetherEngine --filter "<patched suites>"`, then the full suite once.
5. Rebuild Reel for all four platforms and rerun the playback matrix smoke rows (`Scripts/playback_matrix.sh`).
