# Looper: spec

Companion to `CLAUDE.md` (which holds the engine-level technical approach and test rules). This records the product decisions from a grilling session on 2026-11-14.

## Goal

A personal macOS app that turns a short seamless video loop plus audio into finished long-form ambient YouTube uploads (sleep / study versions): the long MP4, a thumbnail and filled-in metadata, ready to upload by hand.

## Decisions

- **Scope: Looper + publish kit, no uploading.** The app produces the video plus a thumbnail and metadata text per version. Uploading stays manual in YouTube Studio, because YouTube API work (OAuth, quota, resumable 10–100 GB uploads) is a project of its own and uploading by hand is quick.
- **Build and test: CI plus the user's Mac.** The processing core is a Swift package. A GitHub Actions macOS workflow generates a frame-counter test clip with ffmpeg and runs the seam, duration and trim tests on every push. SwiftUI work and the full-size 8 h export run on the user's Mac, because the cloud session is Linux (no AVFoundation) and CI runners have limited disk and time.
- **8 h testing is layered so it stays cheap:**
  - Seam drift: build a 960-insert composition and check every insert time exactly, with no export (CI, milliseconds).
  - Long-run memory and duration: export 8 h from a tiny low-bitrate clip, a few hundred MB (CI).
  - Full-size 8 h export: once per milestone on the Mac, checking speed, memory, file size and the time-remaining estimate. The **Intel Mac is the speed benchmark**: if exports take minutes there, they take minutes everywhere. CI runners are Apple Silicon, so the Intel Mac is also where Intel behaviour gets tested.
  - Why 8 h at all: it is the longest real output, and drift, leaks and large-file MP4 handling only show up at that scale.
- **v1 = milestones 1–3** (core extend, basic UI, audio), because ambient videos need sound. The check "does passthrough export honour `AVAudioMix`?" is done as a quick test inside milestone 1 so the export path (passthrough vs reader/writer) is decided once.
- **Audio model: ambient bed + music playlist.** Track 1 is a looped bed with a wrap crossfade. Track 2 is a folder of tracks chained in order, cycling to fill the duration. Lossless inputs (WAV/AIFF/FLAC) are preferred so AAC encoding happens once.
- **Music is made outside Looper, pluggable later.** Looper reads folders of audio files and works offline. The core defines an `AudioSource` protocol so a generator could be added later. Reason: tracks are reusable across many videos, so generation is occasional while exporting is constant, and a paid network API doesn't belong in the export path. Generation for now: Claude via the Higgsfield connector (Suno instrumental music, 15–360 s per track; Mirelo SFX for ambience).
- **Clip audio: optional track, off by default.** If a clip has audio (for example Seedance 2.5 ambient sound), it shows up as a "Clip audio" track with a switch, volume and fades. It's off by default because a 30 s audio loop repeats audibly, and generated audio rarely loops seamlessly even when the picture does. Long beds (5–10 min) are recommended instead.
- **Video format: any resolution and frame rate, passthrough.** Looper only checks that the clip has a single consistent video track. Tests calculate expected frame counts from the clip's real frame rate. Upscaling to 4K, which earns a better YouTube codec, happens before Looper on the 30 s clip, never in Looper, to keep exports to minutes. Warn when free disk space is low (8 h of 4K may be 50–100 GB; YouTube's limit is 256 GB / 12 h).
- **Job model: one clip → several versions.** A *version* bundles duration, audio mix (per-track volume and fades), optional video fade to black at the end, and publish-kit templates. A *job* is a clip plus a list of versions. Batch is a queue of jobs, which also covers "many clips, same recipe". Reason: two or three uploads from one clip is where the time savings are.
- **Output layout per job:**
  ```
  <Clip name>/
    8h Sleep/  video.mp4  thumbnail.jpg  metadata.txt
    3h Study/  video.mp4  thumbnail.jpg  metadata.txt
  ```
- **Publish kit, phased:**
  - First: `metadata.txt` (title, description, tags) from templates with placeholders such as `{hours}`, `{scene}`, `{mode}`, plus `thumbnail.jpg`, a frame the user picks by scrubbing, 1280×720, under 2 MB.
  - Follow-up: text drawn on the thumbnail using **one fixed layout** (big hours number plus mode label, one font, colour per preset), not a configurable design tool.
- **Distribution: personal only, across the user's own Macs.** No App Store, sandbox or notarisation.

## Assumptions

- **macOS 14+ minimum.** The user's main Mac runs macOS 15.4.1. 14+ allows the async AVFoundation loading APIs and SwiftUI's Observation framework.
- **Moving the app between the user's Macs:** `scripts/package.sh` builds a Release **universal binary (arm64 + x86_64)**, because the main Mac is Intel and the others are Apple Silicon. It signs the app ad hoc (Apple Silicon refuses unsigned code; ad hoc is enough) and zips it. On the receiving Mac, clear quarantine once (`xattr -dr com.apple.quarantine Looper.app`). Building from the repo on each Mac also works.
- **Presets portable between Macs:** stored as JSON files in a user-chosen folder (for example iCloud Drive), with music folders referenced relative to that folder.
- **Volume is a handful of videos per week**, which doesn't change the design (the user didn't give a number).

## Risks accepted

- **AI music licensing and monetisation.** Whether Suno-via-Higgsfield output can be monetised depends on those services' terms for the user's plan. Not yet checked.
- **YouTube "inauthentic / repetitive content" monetisation policy.** Mass-produced loops are at risk. A varied playlist and a distinct look per video reduce this.
- **The passthrough export path may not support audio mixing.** If `AVAudioMix` is ignored, export uses `AVAssetReader`/`AVAssetWriter` (video passed through, audio rendered). That adds work but was already planned for in `CLAUDE.md`.

## Open questions

- **Playlist behaviour:** gap or crossfade between songs, shuffle vs fixed order, and whether a cycle may repeat within one video. Settle in milestone 3.
- **Song-to-song crossfade length** and the bed's wrap crossfade length (likely 2–5 s). Settle by listening tests.
- **Metadata template contents** (description boilerplate, tag lists per mode). The user supplies these when the publish kit is built.
- **Video fade to black without re-encoding 8 h.** Only the last stretch needs re-encoding. Plan: pass every copy through except the faded tail, re-encode just that tail with matching encoder settings, and join them. Check in milestone 4 that the join plays cleanly. Hardware encoding through VideoToolbox is available on both Intel and Apple Silicon Macs.

## Next steps

1. Create the Xcode project plus a `LooperCore` Swift package (no UI imports), with a `scripts/make-test-clip.sh` that generates the ffmpeg frame-counter loop.
2. Milestone 1: `LoopComposer` builds the composition (exact inserts using the clip's timescale, trimmed last copy). Passthrough export. Tests for seams, frame count, a non-multiple target (1:00:10) and the 960-insert drift check.
3. In milestone 1, a quick test of whether passthrough honours `AVAudioMix`. Record the result in `CLAUDE.md`.
4. GitHub Actions macOS workflow running the `LooperCore` tests.
5. Milestone 2 UI, then milestone 3 audio (bed + playlist + optional clip audio).
