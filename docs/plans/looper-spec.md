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
- **Publish kit:** per version, `title.txt`, `description.txt`, `tags.txt` and `thumbnail.jpg` (a frame the user picks by scrubbing, 1280×720, under 2 MB), produced by the branding factory below from the job's channel. This replaces the earlier single `metadata.txt` and "one fixed thumbnail layout".
- **Distribution: personal only, across the user's own Macs.** No App Store, sandbox or notarisation.

## Channels and branding factory

Decided in a grilling session on 2026-11-14. The user runs several YouTube channels on different kinds of ambient sound (one with soft piano music), and wants a factory that turns a job into a thumbnail, title, description and keywords in each channel's brand.

- **`Channel` is the brand kit, a top-level setting.** Stored as JSON in the presets folder (with an optional logo PNG beside it). It holds: name; colours; a font (installed font by name, falling back to the system font); optional logo; one of the built-in thumbnail layouts; title patterns, hook lines and "Perfect for…" lines (each a pool, with per-mode variants and a shared fallback); a fixed description footer (subscribe line, links, music/AI credit); 3 hashtags; core tags; default versions (built from `Version`); an optional default playlist folder; and the No-Ads setting. A job picks one channel and its versions start from the channel's defaults; `PublishTemplates` becomes optional per-version overrides. Reason: branding is set once per channel, never typed per video.
- **`Version` gets a `mode` string** (e.g. "Sleep", "Study", "Relax"; filled from the name when older files lack it), so pools can branch on mode. It also gets a per-version switch to turn No-Ads off.
- **Scene details are typed per job:** scene (pre-filled from the clip's filename), mood, elements. Not detected automatically: Vision labels are too generic to sell a video.
- **Text comes from templates with variant pools, offline.** No LLM writer is planned. Placeholders: `{scene}`, `{mood}`, `{elements}`, `{hours}`, `{duration}`, `{mode}`, `{channel}`, `{music}` (empty when there's no playlist). An unknown placeholder is an error when the channel is loaded, never text in a title.
- **Variant choice is seeded per job**, so regenerating gives the same text unless the user shuffles. A per-channel history file makes the next upload avoid the title patterns and hook lines of recent uploads. Reason: consecutive uploads must not look mass-produced (YouTube's repetitive content policy).
- **Title:** a pattern plus ` (No-Ads)` appended by the factory when No-Ads is on. The 100-character limit includes the suffix; patterns that would exceed it are skipped.
- **Description sections, in order:** `(No-Ads)` + hook line → what you hear (`{elements}`, `{music}`) → "Perfect for…" by mode → channel footer → 3 hashtags. ≤ 5000 characters. "(No-Ads)" leads the first line so it shows in the ~150-character snippet.
- **Tags in priority order:** scene-specific (scene, elements) → mode → duration → channel core; duplicates removed, cut at YouTube's 500-character total so the most specific tags survive.
- **No-Ads is a factory rule, not template text,** on by default for every channel, with a per-version off switch. When on, the kit's notes remind the user to turn off ads for that video in YouTube Studio, because the label is only true if ads are disabled there.
- **Thumbnails: 2–3 fixed layouts** (e.g. big number in a corner, centered title band, minimal logo only), drawn with Core Graphics / Core Text in LooperCore on the picked frame and styled by the channel. Each layout puts a dark gradient behind its text; no colour grading. No "No Ads" badge on thumbnails. Still not a design tool.
- **Where it runs:** core in LooperCore (no UI). The kit is written at export; "Regenerate kit" rewrites only the text and thumbnail without re-exporting the video. The CLI gets `--channel <file>`.
- **Editing channels:** by hand in JSON for now; an in-app channel editor comes later (and needs a mockup). The app gets a channel picker, scene fields, Regenerate kit and copy buttons.
- **English only.** No localisation fields.
- **Starter channels** (working names, the user renames them): "Rainfall Hours" (rain and storms, sleep-focused, dark and moody, no music), "Hearth & Study" (cafés, cabins, libraries, study-focused, warm, ambience only) and "Quiet Keys" (soft piano over a quiet bed, sleep and study, elegant and minimal). Claude drafts their pools; the user edits them.
- **Build order:** (1) `Channel` model, mode and No-Ads fields, JSON loading with validation, starter channels; (2) text factory, three text files, seeded variants and shuffle, channel history, CLI flag; (3) thumbnail layouts (mockup before merge); (4) app channel picker, scene fields, Regenerate kit, copy buttons (mockup before merge). 1 and 2 have no visual change.

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
- **Video fade to black without re-encoding 8 h.** Only the last stretch needs re-encoding. Plan: pass every copy through except the faded tail, re-encode just that tail with matching encoder settings, and join them. Check in milestone 4 that the join plays cleanly. Hardware encoding through VideoToolbox is available on both Intel and Apple Silicon Macs.

## Next steps

1. Create the Xcode project plus a `LooperCore` Swift package (no UI imports), with a `scripts/make-test-clip.sh` that generates the ffmpeg frame-counter loop.
2. Milestone 1: `LoopComposer` builds the composition (exact inserts using the clip's timescale, trimmed last copy). Passthrough export. Tests for seams, frame count, a non-multiple target (1:00:10) and the 960-insert drift check.
3. In milestone 1, a quick test of whether passthrough honours `AVAudioMix`. Record the result in `CLAUDE.md`.
4. GitHub Actions macOS workflow running the `LooperCore` tests.
5. Milestone 2 UI, then milestone 3 audio (bed + playlist + optional clip audio).
