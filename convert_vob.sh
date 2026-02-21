#!/bin/bash
# convert_vob.sh - Convert VOB files to compressed MP4 (H.264/AAC)
#
# Usage:
#   ./convert_vob.sh                        # Convert all VOB files in current directory
#   ./convert_vob.sh /path/to/vobs          # Convert all VOBs in a specific directory
#   ./convert_vob.sh movie.vob              # Convert a single VOB file
#   ./convert_vob.sh /input/dir /output/dir # Specify input and output directories
#
# Requirements: ffmpeg (install with: sudo apt install ffmpeg  OR  brew install ffmpeg)

# ── Configuration ──────────────────────────────────────────────────────────────
VIDEO_CODEC="libx264"       # H.264 — widely compatible; use libx265 for ~40% smaller (slower)
AUDIO_CODEC="aac"           # AAC audio
CRF=23                      # Quality: 18=near-lossless, 23=default, 28=smaller/lower quality
PRESET="medium"             # Encoding speed: ultrafast, fast, medium, slow, veryslow
AUDIO_BITRATE="128k"        # Audio bitrate
OUTPUT_EXT="mp4"            # Output container format
# ───────────────────────────────────────────────────────────────────────────────

# Colour output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

check_ffmpeg() {
    if ! command -v ffmpeg &>/dev/null; then
        echo -e "${RED}Error: ffmpeg is not installed.${NC}"
        echo "Install it with:"
        echo "  macOS:   brew install ffmpeg"
        echo "  Ubuntu:  sudo apt install ffmpeg"
        echo "  Windows: https://ffmpeg.org/download.html"
        exit 1
    fi
}

# Convert HH:MM:SS.xx timestamp to integer seconds
time_to_secs() {
    local t="${1%%.*}"   # strip sub-seconds
    local h m s
    IFS=: read -r h m s <<< "$t"
    h=$(( 10#$h )); m=$(( 10#$m )); s=$(( 10#$s ))
    echo $(( h * 3600 + m * 60 + s ))
}

# Format raw seconds as "1h 04m 32s" / "4m 32s" / "32s"
format_duration() {
    local total=$1
    local h=$(( total / 3600 ))
    local m=$(( (total % 3600) / 60 ))
    local s=$(( total % 60 ))
    if   [[ $h -gt 0 ]]; then printf "%dh %02dm %02ds" $h $m $s
    elif [[ $m -gt 0 ]]; then printf "%dm %02ds" $m $s
    else                       printf "%ds" $s
    fi
}

# Draw a block progress bar of a given width
draw_bar() {
    local pct=$1 width=${2:-40}
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf "%s" "$bar"
}

convert_file() {
    local input="$1"
    local output_dir="$2"
    local filename
    filename=$(basename "${input%.*}")
    local output="${output_dir}/${filename}.${OUTPUT_EXT}"

    # ── Skip tiny/stub VOBs ───────────────────────────────────────────────────
    local size
    if stat -f%z "$input" &>/dev/null; then
        size=$(stat -f%z "$input")
    else
        size=$(stat -c%s "$input" 2>/dev/null || echo 0)
    fi
    if [[ $size -lt 1048576 ]]; then
        echo -e "${YELLOW}  Skipping (too small, likely a menu stub): $(basename "$input")${NC}"
        return
    fi

    if [[ -f "$output" ]]; then
        echo -e "${YELLOW}  Skipping (output already exists): $(basename "$output")${NC}"
        return
    fi

    # ── Get total duration via ffprobe ────────────────────────────────────────
    local total_dur=0
    local dur_raw
    dur_raw=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null)
    if [[ -n "$dur_raw" && "$dur_raw" != "N/A" ]]; then
        total_dur=${dur_raw%%.*}
    fi

    # ── Print header ──────────────────────────────────────────────────────────
    echo -e "${CYAN}${BOLD}  File:    $(basename "$input")${NC}"
    echo -e "  Output:  $output"

    local wall_start wall_end
    wall_start=$(date +%s)
    echo -e "  Started: $(date '+%H:%M:%S')"
    echo ""

    # ── Launch ffmpeg; parse -progress pipe:1 for live bar ───────────────────
    local tmplog exit_file
    tmplog=$(mktemp /tmp/ffmpeg_log.XXXXXX)
    exit_file=$(mktemp /tmp/ffmpeg_exit.XXXXXX)

    {
        ffmpeg -i "$input" \
            -c:v "$VIDEO_CODEC" \
            -crf "$CRF" \
            -preset "$PRESET" \
            -c:a "$AUDIO_CODEC" \
            -b:a "$AUDIO_BITRATE" \
            -movflags +faststart \
            -progress pipe:1 \
            -nostats \
            -y \
            "$output" \
            2>"$tmplog"
        echo $? > "$exit_file"
    } | {
        local cur_secs=0 pct=0 fps="--" speed="?" bar_width=38

        while IFS= read -r line; do
            case "$line" in
                out_time=*)
                    local t="${line#out_time=}"
                    if [[ "$t" != "N/A" && "$t" != -* ]]; then
                        cur_secs=$(time_to_secs "$t")
                    fi
                    ;;
                fps=*)
                    fps="${line#fps=}"
                    [[ -z "$fps" || "$fps" == "0" ]] && fps="--"
                    ;;
                speed=*)
                    speed="${line#speed=}"
                    [[ -z "$speed" ]] && speed="?"
                    ;;
                progress=*)
                    if [[ $total_dur -gt 0 ]]; then
                        pct=$(( cur_secs * 100 / total_dur ))
                        [[ $pct -gt 100 ]] && pct=100
                    fi

                    local elapsed=$(( $(date +%s) - wall_start ))
                    local eta_str="--"
                    if [[ $pct -gt 0 && $pct -lt 100 && $elapsed -gt 0 ]]; then
                        local eta=$(( elapsed * (100 - pct) / pct ))
                        eta_str=$(format_duration "$eta")
                    fi

                    local bar
                    bar=$(draw_bar "$pct" "$bar_width")
                    printf "\r  [%s] %3d%%  fps:%-5s  speed:%-7s  ETA:%-9s" \
                        "$bar" "$pct" "$fps" "$speed" "$eta_str"
                    ;;
            esac
        done

        # Final complete bar
        local bar
        bar=$(draw_bar 100 "$bar_width")
        printf "\r  [%s] 100%%  %-40s\n" "$bar" ""
    }

    # ── Timing summary ────────────────────────────────────────────────────────
    wall_end=$(date +%s)
    local elapsed=$(( wall_end - wall_start ))

    echo -e "  Ended:   $(date '+%H:%M:%S')  |  Encode time: ${BOLD}$(format_duration "$elapsed")${NC}"

    # ── Result ────────────────────────────────────────────────────────────────
    local exit_code=1
    [[ -f "$exit_file" ]] && exit_code=$(cat "$exit_file")
    rm -f "$exit_file"

    if [[ "$exit_code" -eq 0 ]]; then
        local in_size out_size
        in_size=$(du -sh "$input" | cut -f1)
        out_size=$(du -sh "$output" | cut -f1)
        echo -e "${GREEN}  ✓ Done — Input: ${in_size}  →  Output: ${out_size}${NC}"
    else
        echo -e "${RED}  ✗ Failed: $(basename "$input")${NC}"
        echo -e "${RED}  Last ffmpeg output:${NC}"
        tail -5 "$tmplog" | sed 's/^/    /'
    fi
    rm -f "$tmplog"
    echo ""
}

main() {
    check_ffmpeg

    local input_path="${1:-.}"
    local output_dir="${2:-}"

    # Single file mode
    if [[ -f "$input_path" ]]; then
        local dir
        dir=$(dirname "$input_path")
        output_dir="${output_dir:-$dir}"
        mkdir -p "$output_dir"
        echo -e "${CYAN}Converting single file...${NC}\n"
        convert_file "$input_path" "$output_dir"
        return
    fi

    # Directory mode
    if [[ ! -d "$input_path" ]]; then
        echo -e "${RED}Error: '$input_path' is not a valid file or directory.${NC}"
        exit 1
    fi

    output_dir="${output_dir:-${input_path}/converted}"
    mkdir -p "$output_dir"

    # Find all VOB files (case-insensitive) — bash 3.2 compatible
    vob_files=()
    while IFS= read -r -d '' f; do
        vob_files+=("$f")
    done < <(find "$input_path" -maxdepth 1 -iname "*.vob" -print0 | sort -z)

    if [[ ${#vob_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No VOB files found in: $input_path${NC}"
        exit 0
    fi

    echo -e "${CYAN}${BOLD}Found ${#vob_files[@]} VOB file(s) in: $input_path${NC}"
    echo -e "Output directory: $output_dir"
    echo -e "Settings: codec=${VIDEO_CODEC}, crf=${CRF}, preset=${PRESET}, audio=${AUDIO_BITRATE}"
    echo "────────────────────────────────────────────────────"

    local count=0
    for vob in "${vob_files[@]}"; do
        (( count++ ))
        echo -e "\n${BOLD}[${count}/${#vob_files[@]}]${NC}"
        convert_file "$vob" "$output_dir"
    done

    echo -e "${GREEN}${BOLD}All done! Converted files are in: $output_dir${NC}"
}

main "$@"
