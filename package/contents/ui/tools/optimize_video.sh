#!/usr/bin/env bash
# Generates lighter copies of the wallpaper videos, downscaled to the screen
# resolution and with a limited frame rate, so decoding and compositing them
# is cheaper. Original files are never modified.
#
# Usage:
#   optimize_video.sh resolve   <file> <target_width> <target_height> <max_fps> [crop]
#   optimize_video.sh transcode <file> <target_width> <target_height> <max_fps> [crop]
#   optimize_video.sh clear
#
# A target width/height of 0 disables downscaling, a max_fps of 0 disables the
# frame rate limit. With "crop" (the video fills the screen and the overflow is
# cut, e.g. landscape videos in portrait screens) only the visible area is kept.
#
# resolve prints a single line:
#   CACHED <path>  an optimized copy is ready to be used
#   NEEDED         an optimized copy should be generated with transcode
#   ORIGINAL       the original file is already within the limits
# transcode prints the path of the optimized copy and exits with 0 on success.

set -u

CACHE_VERSION=1
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/luisbocanegra.smart.video.wallpaper.reborn/optimized"
MAX_CACHE_AGE_DAYS=30
# don't bother downscaling unless the video is at least this much bigger than needed
DOWNSCALE_THRESHOLD=0.9

mode="${1:-}"

if [ "$mode" = "clear" ]; then
    rm -rf "$CACHE_DIR"
    exit 0
fi

input="${2:-}"
target_width="${3:-0}"
target_height="${4:-0}"
max_fps="${5:-0}"
fill_mode="${6:-}"

if [ -z "$input" ] || [ ! -f "$input" ]; then
    echo "ORIGINAL"
    echo "file not found: $input" >&2
    exit 0
fi

if ! command -v ffprobe >/dev/null || ! command -v ffmpeg >/dev/null; then
    echo "ORIGINAL"
    echo "ffmpeg/ffprobe not found" >&2
    exit 0
fi

probe() {
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,avg_frame_rate,r_frame_rate:stream_side_data=rotation \
        -of default=noprint_wrappers=1 "$input" 2>/dev/null
}

width=0 height=0 rotation=0 avg_rate="" r_rate=""
while IFS='=' read -r key value; do
    case "$key" in
    width) width="$value" ;;
    height) height="$value" ;;
    rotation) rotation="${value%%.*}" ;;
    avg_frame_rate) avg_rate="$value" ;;
    r_frame_rate) r_rate="$value" ;;
    esac
done < <(probe)

if [ "${width:-0}" -le 0 ] 2>/dev/null || [ "${height:-0}" -le 0 ] 2>/dev/null; then
    echo "ORIGINAL"
    echo "could not read video stream from $input" >&2
    exit 0
fi

# ffmpeg applies the rotation when transcoding, use the displayed size
case "${rotation#-}" in
90 | 270) read -r width height <<<"$height $width" ;;
esac

# "30000/1001" -> 29.970
rate_to_fps() {
    awk -F/ '{ if (NF == 2 && $2 > 0) printf "%.3f", $1 / $2; else if ($1 > 0) printf "%.3f", $1; else print "0" }' <<<"$1"
}
fps=$(rate_to_fps "$avg_rate")
if awk -v f="$fps" 'BEGIN { exit !(f <= 0 || f > 1000) }'; then
    fps=$(rate_to_fps "$r_rate")
fi

# Scale to cover the target size keeping the aspect ratio (never upscaling).
# When cropping, first cut the centered area that is visible on the screen.
read -r new_width new_height downscale crop crop_width crop_height < <(
    awk -v w="$width" -v h="$height" -v tw="$target_width" -v th="$target_height" \
        -v t="$DOWNSCALE_THRESHOLD" -v fill="$fill_mode" '
    function even_up(x) { x = int(x + 0.999); return x + (x % 2) }
    function even_down(x) { x = int(x); return x - (x % 2) }
    BEGIN {
        if (tw <= 0 || th <= 0) { print w, h, 0, 0, w, h; exit }
        s = tw / w; if (th / h > s) s = th / h
        cw = w; ch = h; crop = 0
        if (fill == "crop") {
            vw = even_down(tw / s); vh = even_down(th / s)
            if (vw < w) cw = vw
            if (vh < h) ch = vh
            # ignore tiny differences in the aspect ratio
            if (cw * ch < 0.95 * w * h) crop = 1
            else { cw = w; ch = h }
        }
        if (s < t) print even_up(cw * s), even_up(ch * s), 1, crop, cw, ch
        else print cw, ch, 0, crop, cw, ch
    }'
)

limit_fps=0
if [ "$max_fps" -gt 0 ] 2>/dev/null && awk -v f="$fps" -v m="$max_fps" 'BEGIN { exit !(f > m + 0.5) }'; then
    limit_fps=1
fi

if [ "$downscale" -eq 0 ] && [ "$crop" -eq 0 ] && [ "$limit_fps" -eq 0 ]; then
    echo "ORIGINAL"
    exit 0
fi

out_fps=$([ "$limit_fps" -eq 1 ] && echo "$max_fps" || printf '%.0f' "$fps")
file_stat=$(stat -c '%s:%Y' "$input")
key="$CACHE_VERSION|$input|$file_stat|${new_width}x${new_height}|$out_fps"
if [ "$crop" -eq 1 ]; then
    key="$key|crop=${crop_width}x${crop_height}"
fi
hash=$(printf '%s' "$key" | md5sum | cut -c1-12)
name=$(basename "$input")
name="${name%.*}"
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)
output="$CACHE_DIR/${name}.${new_width}x${new_height}.${out_fps}fps.${hash}.mp4"

if [ "$mode" = "resolve" ]; then
    if [ -s "$output" ]; then
        # keep recently used copies from being cleaned up
        touch -c "$output"
        echo "CACHED $output"
    else
        echo "NEEDED"
    fi
    exit 0
fi

if [ "$mode" != "transcode" ]; then
    echo "unknown mode: $mode" >&2
    exit 2
fi

mkdir -p "$CACHE_DIR" || exit 1

# several screens (or the lock screen) may request the same video at once
exec 9>"$output.lock"
flock 9

if [ -s "$output" ]; then
    echo "$output"
    exit 0
fi

tmp="$output.part.$$.mp4"
trap 'rm -f "$tmp"' EXIT

low_priority=(nice -n 19)
if command -v ionice >/dev/null; then
    low_priority+=(ionice -c 3)
fi

fps_filter=""
if [ "$limit_fps" -eq 1 ]; then
    fps_filter="fps=$max_fps,"
fi

crop_filter=""
if [ "$crop" -eq 1 ]; then
    crop_filter="crop=$crop_width:$crop_height,"
fi

common_output=(
    -map 0:v:0 -map '0:a:0?'
    -c:a aac -b:a 160k
    -movflags +faststart
    -f mp4 "$tmp"
)

# Prefer hardware encoding with VA-API, skipping NVIDIA devices so their
# (power hungry) GPU can stay idle
transcode_vaapi() {
    local device driver
    # the size must be explicit, otherwise the hardware crop is ignored
    local scale="scale_vaapi=w=$new_width:h=$new_height:format=nv12"
    for device in /dev/dri/renderD*; do
        [ -e "$device" ] || continue
        driver=$(basename "$(readlink -f "/sys/class/drm/$(basename "$device")/device/driver")")
        [ "$driver" = "nvidia" ] && continue
        echo "trying VA-API on $device ($driver)" >&2
        if "${low_priority[@]}" ffmpeg -nostdin -hide_banner -loglevel error -y \
            -init_hw_device "vaapi=va:$device" -filter_hw_device va \
            -hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi \
            -i "$input" \
            -vf "${fps_filter}format=nv12|vaapi,hwupload,${crop_filter}$scale" \
            -c:v h264_vaapi -qp 23 \
            "${common_output[@]}"; then
            return 0
        fi
    done
    return 1
}

transcode_software() {
    local scale=""
    if [ "$downscale" -eq 1 ]; then
        scale="scale=$new_width:$new_height:flags=lanczos,"
    fi
    echo "falling back to software encoding" >&2
    "${low_priority[@]}" ffmpeg -nostdin -hide_banner -loglevel error -y \
        -i "$input" \
        -vf "${fps_filter}${crop_filter}${scale}format=yuv420p" \
        -c:v libx264 -preset medium -crf 22 \
        "${common_output[@]}"
}

if transcode_vaapi || transcode_software; then
    mv -f "$tmp" "$output"
    rm -f "$output.lock"
    find "$CACHE_DIR" -type f -mtime +"$MAX_CACHE_AGE_DAYS" -delete 2>/dev/null
    echo "$output"
    exit 0
fi

echo "failed to optimize $input" >&2
exit 1
