# Looper

[![CI](https://github.com/jsonify/looper/actions/workflows/ci.yml/badge.svg)](https://github.com/jsonify/looper/actions/workflows/ci.yml)

A personal macOS app that turns a short seamless video loop plus audio into finished long-form ambient YouTube uploads (for example 8 h sleep and 3 h study versions): the long MP4, a thumbnail and filled-in metadata, ready to upload by hand. Video is passed through without re-encoding, so long exports take minutes.

- Product decisions and reasons: [`docs/plans/looper-spec.md`](docs/plans/looper-spec.md)
- Engine approach, milestones and test rules: [`CLAUDE.md`](CLAUDE.md)
- Roadmap: [issue #1](https://github.com/jsonify/looper/issues/1)

## Requirements

macOS 14 or later, Intel or Apple Silicon. Building needs Xcode 16.

## Repository layout

| Path | What |
|---|---|
| `LooperCore/` | Swift package with the processing engine. AVFoundation only, no UI code. |
| `Looper/`, `Looper.xcodeproj` | The SwiftUI app. Uses `LooperCore` as a local package. New files in `Looper/` are picked up automatically. |
| `channels/` | Starter channel brand kits (`channel.json` per channel). See [Channels](#channels). |
| `scripts/make-test-clip.sh` | Generates the test clips and audio (needs ffmpeg). |
| `.github/workflows/ci.yml` | macOS CI: core tests and a universal Release build of the app. |

## Channels

Each YouTube channel has a brand kit that the publish kit is written from: title patterns, description lines, tags, hashtags, thumbnail layout, colours and font, plus the versions a new job on that channel starts with. Every channel lives in its own folder:

```
<Channels folder>/
  rainfall-hours/  channel.json  logo.png (optional)
  quiet-keys/      channel.json
```

Copy the starters from `channels/` (Rainfall Hours, Hearth & Study, Quiet Keys) into your channels folder and edit the JSON. Text pools may use `{scene}`, `{mood}`, `{elements}`, `{hours}`, `{duration}`, `{mode}`, `{channel}` and `{music}`; anything else in braces is reported when the channel loads, along with bad colours, missing pools and tag mistakes. A pool is either a list or `{"shared": [...], "byMode": {"Sleep": [...]}}`. Durations can be written as `"3h"` or `"1:30:00"`. `noAds` (on by default) adds "(No-Ads)" to titles and descriptions; a version can turn it off. The factory that writes titles, descriptions, tags and thumbnails from these is in progress (#71, #72, #73).

## Installing on another Mac

```bash
make package
```

This builds a universal app (Intel and Apple Silicon), signs it ad hoc and zips it into `dist/`. Each CI run also uploads the zip as the `Looper-app` artifact. On the other Mac, unzip it, move `Looper.app` to Applications, and clear the download quarantine once:

```bash
xattr -dr com.apple.quarantine /Applications/Looper.app
```

## Development

```bash
brew install ffmpeg
```

```bash
scripts/make-test-clip.sh
```

```bash
swift test --package-path LooperCore
```

Open `Looper.xcodeproj` in Xcode to run the app, or use the Makefile: `make install` (build and copy to /Applications), `make run`, `make test`, `make cli`. Run `make` to list targets.

Test fixtures go to `fixtures/` (git-ignored), or to `$LOOPER_FIXTURES` if set. Tests that need fixtures are skipped when they're missing; CI sets `LOOPER_REQUIRE_FIXTURES=1` so missing fixtures fail there instead. Long tests (1 h audio exports) run only when `LOOPER_LONG_TESTS=1`, which CI sets on `main` and on manual runs.
