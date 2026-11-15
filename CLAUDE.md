# Looper

A macOS app that takes a short, seamless video loop (for example a 30-second ambient clip) and turns it into a long video of an exact length (1 h, 3 h, 8 h, custom), optionally with ambient sound and music added. Output is used for long-form ambient YouTube videos (sleep and study versions).

## Input clips

- Produced separately as seamless loops: H.264 MP4, 1920x1080, 30 fps, no audio track.
- The clip already loops perfectly: the frame after its last frame is its first frame. So repeating it end to end must add nothing between copies: no fades, no duplicated or dropped frames.

## Core behaviour

1. User picks a loop clip and a target duration (presets plus custom hh:mm:ss).
2. App repeats the clip back to back until the target, trimming the final copy so the output is exactly the target duration.
3. Video is not re-encoded unless a video effect is turned on. Long exports must be fast (minutes, not hours) and the same quality as the source.
4. Optional audio:
   - One or more tracks (for example an ambient bed and a music playlist), each looped or chained to fill the duration.
   - Per-track volume, fade in at the start, fade out at the end.
   - Audio crossfade where a looped audio track wraps, so the seam is inaudible.
   - Output audio: AAC, 48 kHz, stereo.
5. Show progress with a time remaining estimate, and let the user cancel an export.

## Technical approach

- Swift + SwiftUI, macOS app. Use AVFoundation; do not bundle ffmpeg (its licensing makes distribution harder).
- Build the long timeline with `AVMutableComposition`, inserting the clip's full time range repeatedly. Use the video track's own time range and timescale so seams are frame exact over hundreds of inserts (3 h of 30 s loops = 360 inserts; 8 h = 960).
- For video-only output, try `AVAssetExportSession` with the passthrough preset (tried in M1: not suitable for loops, see below).
- Check early whether passthrough export honours an `AVAudioMix` (volume ramps). If not, write the output with `AVAssetReader` / `AVAssetWriter`: video samples passed through unchanged, audio rendered from the composition and encoded to AAC.
- **Result (M1 spike, #13, Xcode 16.4 / macOS 15):** passthrough does **not** honour `AVAudioMix` (levels unchanged, ramps ignored), copies audio in its source format (even LPCM into `.mp4`, not AAC), and writes each composition audio track as a separate output track instead of mixing. **Decision:** keep `PassthroughExporter` (`AVAssetExportSession`) for video-only output; for any output with audio (M3, #36) use an `AVAssetReader`/`AVAssetWriter` exporter behind the same `CompositionExporter` protocol: video samples copied (`outputSettings: nil`), audio read through `AVAssetReaderAudioMixOutput` (applies the mix and mixes tracks) and encoded once to AAC 48 kHz stereo. The spike test (`AudioMixSpikeTests`) stays as a record and prints `SPIKE` lines in CI.
- **Loops are written with `LoopWriter` (`AVAssetWriter`), not export-session passthrough.** Passthrough of the looped composition writes one edit-list entry per copy; with B-frame clips, ffmpeg (close to YouTube's ingest) then holds frame N-2 for two extra frames at the first seam and shifts everything after it (found in M1 CI; `passthroughCompositionTripsUpFFmpeg` records it as a known issue). `LoopWriter` copies the clip's compressed samples byte for byte into one continuous track, shifting each copy's timestamps by the clip duration, and ends the session at the exact target, so the file is shaped like the source (at most one edit). M3 adds audio inputs to this writer. `LoopComposer` remains for building timelines (drift test, M3 audio).
- **Audio (M3):** `LoopAudioBuilder` lays the bed (one file repeated) and the playlist (folder in name order, cycling) with `AudioChain` on alternating track pairs so neighbours overlap by a crossfade, and lays clip audio at each video insert time (10 ms edge fades hide the few-ms AAC gaps). `GainEnvelope` turns track volume, start/end fades and equal-power crossfades into `AVAudioMix` volume ramps. `LoopWriter` reads the result through `AVAssetReaderAudioMixOutput` (48 kHz stereo float) into an AAC 48 kHz stereo 256 kbps writer input, shifted by the video's media start so audio begins with the first shown frame; video and audio inputs are fed concurrently by `requestMediaDataWhenReady` pumps. Default crossfades (bed wrap 3 s, songs 3 s) and levels are provisional until the listening tests (#38).
- **Volume ramps are quadratic:** `setVolumeRamp` checks each new ramp against every ramp already on the track, so set-up time grows with the square of the ramp count (a 10 s bed chained over 8 h took ~11 min before playing or exporting). So a bed up to 5 min is rendered once by `BedLoop` with its wrap crossfade baked in (one pass over the source, so repeats join seamlessly) and repeated on one track with only the track fade ramps; its `AudioTrackMix.placements` still hold the chain layout for the preview's lanes and jumps, and `gainPlacements` is one whole-length piece. Longer beds and the playlist stay chains. Fades of 50 ms or less (clip audio's edge fades) are one linear ramp instead of eight.
- **Bed from a video:** the bed can be any file with sound, including a video (e.g. a screen recording of noises.online); only its audio track is read. `SilenceTrim` finds silence at the start and end (peaks under -50 dBFS in 10 ms windows) and the bed loops only `BedSettings.trim`, so a recording's silent lead-in doesn't play at every wrap. On by default in the app (toggle under the bed) and the CLI (`--keep-bed-silence` turns it off).
- **Jobs and versions (M4, #40):** `Version` (name, `TargetDuration`, `LoopAudioSettings`, `VideoFade`, `PublishTemplates`) and `Job` (clip URL, versions, thumbnail time) are Codable; decoding fills defaults for missing optional parts and validates the duration. `JobRunner` loads the clip once and exports versions in order into `<Clip name>/<Version name>/video.mp4` through `LoopExporting`; a failed version is recorded and the rest still run, a cancel marks the current version cancelled and the rest skipped. Overall progress weights versions by length. Fade to black and the publish kit are stored but not yet written (#44–#46).
- **Channels (#70):** `Channel` (in `LooperCore/Channel/`) is a channel's brand kit: `ModePools` of title patterns, hooks, "hear" and "Perfect for" lines and mode tags (a shared pool plus per-mode pools), footer, hashtags, core tags, `ChannelBrand` (layout, colours, font), default versions, optional default playlist, `noAds`. Hand-edited JSON, one folder per channel (`channel.json`, optional `logo.png`), read by `ChannelLibrary`, which lists broken channels instead of failing. `Channel.problems` checks placeholders (`Placeholder`, parsed by `TemplateText`), colours, pools for each default version's mode, tags and hashtags. `Version` has `mode` (from the name when missing) and `noAds`; `Job` has `channelID` and `SceneDetails` (scene pre-filled from the clip name). Starter channels live in `channels/` and are tested.
- **Text factory (#71):** `KitFactory` turns a channel, job and version into a `PublishKit` (title, description, tags, notes). Its rules:
  - Values come from `PlaceholderValues`. Title Case is applied in titles, and a pattern with an empty placeholder is skipped, falling back to the shared pool.
  - Choices are seeded by `Job.kitSeed` plus the version id through `KitRandom` (SplitMix64/FNV-1a, not `Hasher`, so text is stable across runs). `Job.shuffleKit()` reseeds.
  - `ChannelHistory` (`history.json` in the channel folder) avoids the last 5 uploads' title patterns and hooks. It ignores a version's own entry and later ones, so regenerating repeats the same text.
  - `PublishTemplates` are per-version overrides: the title pattern, the hook and extra tags.
  - `JobRunner.run(branding:)` makes every kit before exporting and writes the text files plus history after each finished version. `Branding.regenerate` rewrites them without exporting.
  - The CLI takes `--channel` with `--scene/--mood/--elements/--mode/--seed/--record-history`.
- **Preview window:** `LoopPreview` builds the export's layout as one playable composition (`LoopComposer` video plus `LoopAudioBuilder` audio added into the same composition) and `PreviewModel` plays it in an `AVPlayer`, nothing written to disk. Layout changes (clip, length, files, crossfade lengths; see `PreviewModel.LayoutKey`) rebuild it and keep the playhead; level and fade changes swap the `AVAudioMix` on the playing item (`AudioTrackMix` keeps each track's role and placements). `PreviewTimeline` holds the lanes and the jump targets (seams, bed wraps, song changes, final fade). Mute and solo are preview only; the window's volume and fade controls edit the main window's settings.
- A trimmed last copy carries decode-only samples (frames past the cut that B-frames reference), hidden by the edit list, so tests count and time **decoded** frames, and cross-check every frame with ffmpeg/ffprobe.
- Keep the processing core in a separate module with no UI code, so it can be tested and later reused (for example a batch mode).

## Milestones

1. **Core extend:** loop clip to exact duration, passthrough, no audio. Verified by the tests below.
2. **Basic UI:** drop or pick a clip, choose duration, choose output location, progress, cancel.
3. **Audio:** add tracks, loop them, volume, fades, wrap crossfade.
4. **Presets:** saved settings such as "Sleep" (quieter mix, long audio fade out, optional slow video fade to black at the end) and "Study" (steady mix, no fade).
5. **Batch queue:** several clips and presets exported in one run.

## Testing

- Make a test loop with a visible frame counter (`ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=30 -t 30 ...`) and check the output around each seam: frame numbers must run ...898, 899, 0, 1... with no repeats or gaps.
- Check output duration and frame count with `ffprobe` (ffmpeg is fine as a developer tool on this Mac, just not bundled in the app). For example, 3 h at 30 fps = 324,000 frames exactly.
- Test a target that isn't a whole multiple of the clip length (for example 1 h 0 m 10 s) to confirm the last copy is trimmed correctly.
- No 8 h export tests: the user doesn't produce 8 h videos (decided 2026-11-14; revisit if that changes). The 8 h drift and plan checks stay because they need no export and run in milliseconds.
- The user's standard manual test on their Mac (real clip, run after each engine change; ask them to run it and paste the output):
  `cd ~/code/macOS/looper/LooperCore && swift run -c release looper ~/Desktop/cabin_rain_loop_30s_v2.MP4 15m ~/Desktop/test-15m.mp4`
  For milestone sign-offs, the same with `3h` and `~/Desktop/test-3h.mp4`. The CLI also takes `--bed <file>` (audio or video), `--keep-bed-silence`, `--playlist <folder>`, `--clip-audio` and `--channel <folder>` (publish kit text; see README).

## Conventions

- Keep the code readable, with small types and clear names. Explain non-obvious AVFoundation choices in short comments.
- Before calling a milestone done, run its tests and report results, not just a successful build.
- Git workflow: always merge after a pull request. Work on a branch, open a PR, and once CI is green merge it into `main` rather than leaving it open. Close the issues the work resolves once CI is green.
- **Visual changes need a mockup before merge.** If a PR changes anything the user sees (layout, controls, text, colours, icons, thumbnails or other rendered images), show the user a mockup of the change (for example an HTML artifact or an image) and get their OK before merging, even when CI is green. Cloud sessions can't run the macOS app, so a mockup is how the change gets seen before it lands. PRs with no visual change merge on green CI as above.

## Project layout and fixtures

- `LooperCore/` is a Swift package (macOS 14+, Swift 6 language mode) with the engine and its tests (Swift Testing). It must not import SwiftUI or AppKit.
- `Looper/` + `Looper.xcodeproj` is the app. The project uses an Xcode 16 synchronized folder, so files added under `Looper/` need no project edits. Release builds are universal (arm64 + x86_64).
- `scripts/make-test-clip.sh` writes fixtures to `fixtures/` (or `$LOOPER_FIXTURES`): 30 s loops at 1080p30, tiny 320x180 30 fps (for long and quick export tests), 360p at 24 fps and 29.97 fps, 360p30 with a stereo AAC track, plus a 10 s pink-noise bed WAV, a 10 s "screen recording" MP4 (video + AAC: 1 s silence, 8.5 s pink noise, 0.5 s silence) and a playlist folder of three 6 s tones (WAV, AIFF, FLAC). All 48 kHz stereo.
- Every fixture frame carries its index in binary: 16 black/white square blocks along the top-left edge (block 0 = least significant bit). Tests read it with `FrameID.decode` (`LooperCoreTests/Support/MediaInspection.swift`) to check seams frame by frame without OCR. Block sizes and frame counts live in both the script and `Support/Fixtures.swift`; keep them in sync. Changing the script changes the CI cache key, so fixtures regenerate automatically.
- Environment variables for tests: `LOOPER_FIXTURES` (fixture folder), `LOOPER_REQUIRE_FIXTURES=1` (missing fixtures fail instead of skip; set in CI), `LOOPER_REQUIRE_FFMPEG=1` (ffmpeg cross-checks fail instead of skip when ffmpeg is missing; set in CI), `LOOPER_LONG_TESTS=1` (run the 1 h audio export tests; set in CI on `main` and manual runs).
- Cloud Claude sessions run on Linux without Swift or AVFoundation: Swift changes there are verified by CI, not locally. ffmpeg is available there for checking fixtures.

## Product spec

Product decisions (scope, publish kit, job/version model, audio sourcing, targets) and their reasons live in `docs/plans/looper-spec.md`. Read it before starting a milestone; where it and this file differ, the spec is newer.
