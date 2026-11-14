#!/usr/bin/env bash
# Generates the test fixtures used by LooperCore's tests.
#
# ffmpeg is a developer tool only: it is never bundled with the app.
# Output goes to $LOOPER_FIXTURES (default: <repo>/fixtures), which is git-ignored.
#
# Usage: scripts/make-test-clip.sh [--force]
#   --force   regenerate files that already exist
#
# Every video fixture is a sequence of uniquely identifiable frames:
#   - a visible frame number (drawtext, when a font is available), for humans;
#   - a strip of 16 black/white blocks in the top-left corner holding the frame
#     index in binary (block 0 = least significant bit), for tests. Blocks are
#     large and pure black/white so they survive H.264 compression.
# Tests decode the strip to check that seams run ...N-2, N-1, 0, 1... with no
# repeats or gaps. Block size per fixture is listed below and in
# LooperCore/Tests/LooperCoreTests/Support/Fixtures.swift; keep them in sync.
#
# The clips are not visually seamless (testsrc moves), which doesn't matter:
# tests check frame identity, not appearance.

set -euo pipefail

FORCE=0
if [[ "${1:-}" == "--force" ]]; then FORCE=1; fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${LOOPER_FIXTURES:-$REPO_ROOT/fixtures}"
mkdir -p "$OUT/audio/playlist"

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

FFMPEG=(ffmpeg -hide_banner -loglevel error -y)
BITS=16

# Pick a font for the visible frame number; skip the text if none is found.
FONT=""
for candidate in \
    /System/Library/Fonts/Supplemental/Arial.ttf \
    /System/Library/Fonts/Helvetica.ttc \
    /Library/Fonts/Arial.ttf \
    /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
    /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf; do
    if [[ -f "$candidate" ]]; then FONT="$candidate"; break; fi
done
HAS_DRAWTEXT=0
# Capture first: `ffmpeg | grep -q` fails under pipefail when grep exits early.
FILTERS="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
if [[ -n "$FONT" && "$FILTERS" == *" drawtext "* ]]; then
    HAS_DRAWTEXT=1
fi

needs() { [[ $FORCE == 1 || ! -s "$1" ]]; }

# make_clip <file> <width> <height> <rate> <frames> <block> <crf> [with_audio]
# rate is an ffmpeg rate expression (30, 24, 30000/1001).
make_clip() {
    local file="$1" w="$2" h="$3" rate="$4" frames="$5" block="$6" crf="$7" audio="${8:-}"
    local path="$OUT/$file"
    if ! needs "$path"; then echo "exists  $file"; return; fi

    local stripw=$((block * BITS))
    # Luma of each block: 255 if bit floor(X/block) of the frame index N is set.
    local lum="255*mod(floor(N/pow(2\,floor(X/$block)))\,2)"
    local text=""
    if [[ $HAS_DRAWTEXT == 1 ]]; then
        local size=$((h / 6))
        text=",drawtext=fontfile='$FONT':text='%{frame_num}':start_number=0:fontsize=$size:fontcolor=white:box=1:boxcolor=black@0.6:x=(w-tw)/2:y=(h-th)/2"
    fi
    local graph="testsrc=size=${w}x${h}:rate=${rate}${text}[base];"
    graph+="color=c=black:size=${stripw}x${block}:rate=${rate},format=yuv420p,geq=lum='${lum}':cb=128:cr=128[bits];"
    graph+="[base][bits]overlay=0:0:shortest=1,format=yuv420p[v]"

    local maps=(-map "[v]")
    local audio_codec=(-an)
    if [[ -n "$audio" ]]; then
        # Stereo 48 kHz: 440 Hz left, 660 Hz right, so channel swaps are detectable.
        graph+=";sine=frequency=440:sample_rate=48000[l];sine=frequency=660:sample_rate=48000[r];"
        graph+="[l][r]join=inputs=2:channel_layout=stereo[a]"
        maps+=(-map "[a]")
        audio_codec=(-c:a aac -b:a 192k -ar 48000 -shortest)
    fi

    "${FFMPEG[@]}" -filter_complex "$graph" "${maps[@]}" \
        -frames:v "$frames" \
        -c:v libx264 -preset medium -crf "$crf" -pix_fmt yuv420p \
        -g "$frames" -keyint_min 1 \
        "${audio_codec[@]}" \
        -movflags +faststart "$path"
    echo "made    $file"
}

# make_tone <file> <codec args...>: 6 s stereo tone; frequency taken from the name.
make_tone() {
    local file="$1" freq="$2"; shift 2
    local path="$OUT/audio/playlist/$file"
    if ! needs "$path"; then echo "exists  audio/playlist/$file"; return; fi
    "${FFMPEG[@]}" -f lavfi -i "sine=frequency=${freq}:sample_rate=48000:duration=6" \
        -ac 2 -ar 48000 "$@" "$path"
    echo "made    audio/playlist/$file"
}

#            file                    w    h    rate        frames block crf  audio
make_clip    loop-1080p30.mp4        1920 1080 30          900    48    20
make_clip    loop-tiny30.mp4         320  180  30          900    16    35
make_clip    loop-360p24.mp4         640  360  24          720    16    28
make_clip    loop-360p2997.mp4       640  360  30000/1001  900    16    28
make_clip    loop-360p30-audio.mp4   640  360  30          900    16    28   audio

# Ambient bed: 10 s of stereo pink noise, 48 kHz, 16-bit WAV.
if needs "$OUT/audio/bed.wav"; then
    "${FFMPEG[@]}" -f lavfi -i "anoisesrc=color=pink:sample_rate=48000:duration=10:amplitude=0.3" \
        -ac 2 -c:a pcm_s16le "$OUT/audio/bed.wav"
    echo "made    audio/bed.wav"
else
    echo "exists  audio/bed.wav"
fi

# A screen recording of a sound website, used as a bed: 10 s video (picture ignored)
# with stereo AAC audio of 1 s silence, 8.5 s pink noise, 0.5 s silence.
if needs "$OUT/audio/recording.mp4"; then
    "${FFMPEG[@]}" -f lavfi -i "color=c=gray:size=320x180:rate=30:duration=10" \
        -f lavfi -i "anoisesrc=color=pink:sample_rate=48000:duration=8.5:amplitude=0.3,adelay=1000:all=1,apad=whole_dur=10" \
        -map 0:v -map 1:a -c:v libx264 -preset medium -crf 35 -pix_fmt yuv420p \
        -ac 2 -c:a aac -b:a 192k -ar 48000 -t 10 -movflags +faststart "$OUT/audio/recording.mp4"
    echo "made    audio/recording.mp4"
else
    echo "exists  audio/recording.mp4"
fi

# Playlist: three short "songs" with distinct tones, one per lossless format.
make_tone 01-tone-220.wav  220 -c:a pcm_s16le
make_tone 02-tone-330.aiff 330 -c:a pcm_s16be
make_tone 03-tone-440.flac 440 -c:a flac

echo "fixtures in $OUT"
