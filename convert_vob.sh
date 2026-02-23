#!/bin/bash
# convert_vob.sh - Convert VOB files to compressed MP4 (H.264/AAC)
#
# Automatically groups multi-part VOBs (VTS_02_1.vob, VTS_02_2.vob, ...) into
# a single encode per title, so each video becomes one MP4 file.
#
# Usage:
#   ./convert_vob.sh                        # Convert all VOBs in current directory
#   ./convert_vob.sh /path/to/vobs          # Convert all VOBs in a specific directory
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

# ── Helpers ────────────────────────────────────────────────────────────────────

time_to_secs() {
    local t="${1%%.*}"
    local h m s
    IFS=: read -r h m s <<< "$t"
    h=$(( 10#$h )); m=$(( 10#$m )); s=$(( 10#$s ))
    echo $(( h * 3600 + m * 60 + s ))
}

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

draw_bar() {
    local pct=$1 width=${2:-40}
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf "%s" "$bar"
}

file_size() {
    if stat -f%z "$1" &>/dev/null; then stat -f%z "$1"
    else stat -c%s "$1" 2>/dev/null || echo 0
    fi
}

# Return total duration in seconds for one or more files
total_duration() {
    local secs=0
    local f dur
    for f in "$@"; do
        dur=$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
        if [[ -n "$dur" && "$dur" != "N/A" ]]; then
            secs=$(( secs + ${dur%%.*} ))
        fi
    done
    echo "$secs"
}

# ── Core encode function ───────────────────────────────────────────────────────
# encode_title <output_path> <total_dur_secs> <part1.vob> [part2.vob ...]
encode_title() {
    local output="$1"
    local total_dur="$2"
    shift 2
    local parts=("$@")

    local wall_start wall_end
    wall_start=$(date +%s)
    echo -e "  Started:  $(date '+%H:%M:%S')"
    echo ""

    # Temp files live next to the output so native Windows ffmpeg can find them
    local tmp_base="${output%.*}"
    local tmplog="${tmp_base}._log.txt"
    local exit_file="${tmp_base}._exit.txt"

    # Build the input: single file or concat demuxer for multiple parts
    local input_args=()
    local concat_file=""
    if [[ ${#parts[@]} -eq 1 ]]; then
        input_args=( -i "${parts[0]}" )
    else
        concat_file="${tmp_base}._concat.txt"
        # On Git Bash/Windows, ffmpeg is a native binary and needs Windows-style
        # paths. cygpath -w converts /c/foo/bar to C:\foo\bar when available.
        local p ffmpeg_path
        for p in "${parts[@]}"; do
            if command -v cygpath &>/dev/null; then
                ffmpeg_path=$(cygpath -w "$p")
            else
                ffmpeg_path="$p"
            fi
            printf "file '%s'\n" "${ffmpeg_path//\'/\'\\\'\'}" >> "$concat_file"
        done
        # Also convert the concat file path itself for ffmpeg
        local concat_arg="$concat_file"
        if command -v cygpath &>/dev/null; then
            concat_arg=$(cygpath -w "$concat_file")
        fi
        input_args=( -f concat -safe 0 -i "$concat_arg" )
    fi

    {
        ffmpeg "${input_args[@]}" \
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
        [[ -n "$concat_file" ]] && rm -f "$concat_file"
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

        local bar
        bar=$(draw_bar 100 "$bar_width")
        printf "\r  [%s] 100%%  %-40s\n" "$bar" ""
    }

    wall_end=$(date +%s)
    local elapsed=$(( wall_end - wall_start ))
    echo -e "  Ended:    $(date '+%H:%M:%S')  |  Encode time: ${BOLD}$(format_duration "$elapsed")${NC}"

    local exit_code=1
    [[ -f "$exit_file" ]] && exit_code=$(cat "$exit_file")
    rm -f "$exit_file"

    if [[ "$exit_code" -eq 0 ]]; then
        # Total input size across all parts
        local total_in=0 p
        for p in "${parts[@]}"; do
            total_in=$(( total_in + $(file_size "$p") ))
        done
        local in_human out_size
        in_human=$(du -sh "${parts[0]}" | cut -f1) # fallback for single
        if [[ ${#parts[@]} -gt 1 ]]; then
            in_human=$(( total_in / 1048576 ))MB   # rough MB sum
        fi
        out_size=$(du -sh "$output" | cut -f1)
        echo -e "${GREEN}  ✓ Done — Input: ${in_human}  →  Output: ${out_size}${NC}"
    else
        echo -e "${RED}  ✗ Failed: $(basename "$output")${NC}"
        echo -e "${RED}  Last ffmpeg output:${NC}"
        tail -5 "$tmplog" | sed 's/^/    /'
    fi
    rm -f "$tmplog"
    echo ""
}

# ── Grouping logic ─────────────────────────────────────────────────────────────
# Groups VOB files by title number (the XX in VTS_XX_Y.vob).
# Returns a sorted, newline-separated list of unique title IDs found.
get_title_ids() {
    local dir="$1"
    find "$dir" -maxdepth 1 -iname "vts_*_*.vob" | \
        sed -E 's/.*[Vv][Tt][Ss]_([0-9]+)_[0-9]+\.[Vv][Oo][Bb]/\1/' | \
        sort -un
}

# Get all parts for a given title ID, sorted by part number
get_parts_for_title() {
    local dir="$1"
    local title_id="$2"
    find "$dir" -maxdepth 1 -iname "vts_${title_id}_*.vob" | \
        sort -t_ -k3 -n
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    check_ffmpeg

    local input_path="${1:-.}"
    local output_dir="${2:-}"

    if [[ ! -d "$input_path" ]]; then
        echo -e "${RED}Error: '$input_path' is not a valid directory.${NC}"
        echo "Usage: $0 [input_dir] [output_dir]"
        exit 1
    fi

    output_dir="${output_dir:-${input_path}/converted}"
    mkdir -p "$output_dir"

    # ── Discover titles ────────────────────────────────────────────────────────
    local title_ids=()
    while IFS= read -r id; do
        [[ -n "$id" ]] && title_ids+=("$id")
    done < <(get_title_ids "$input_path")

    if [[ ${#title_ids[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No VTS_XX_Y.vob files found in: $input_path${NC}"
        exit 0
    fi

    # ── Print discovery summary ────────────────────────────────────────────────
    echo -e "${CYAN}${BOLD}Found ${#title_ids[@]} video title(s) in: $input_path${NC}"
    echo -e "Output directory: $output_dir"
    echo -e "Settings: codec=${VIDEO_CODEC}, crf=${CRF}, preset=${PRESET}, audio=${AUDIO_BITRATE}"
    echo "────────────────────────────────────────────────────"

    local tid
    for tid in "${title_ids[@]}"; do
        local parts=()
        while IFS= read -r f; do
            # Skip stub files under 1 MB (menu VOBs)
            local sz
            sz=$(file_size "$f")
            [[ $sz -lt 1048576 ]] && continue
            parts+=("$f")
        done < <(get_parts_for_title "$input_path" "$tid")

        [[ ${#parts[@]} -eq 0 ]] && continue

        local output="${output_dir}/video_${tid}.${OUTPUT_EXT}"

        echo ""
        echo -e "${CYAN}${BOLD}Title ${tid}${NC} — ${#parts[@]} part(s):"
        local p
        for p in "${parts[@]}"; do
            local sz
            sz=$(file_size "$p")
            printf "    %s  (%s MB)\n" "$(basename "$p")" "$(( sz / 1048576 ))"
        done
        echo -e "  Output:   $output"

        if [[ -f "$output" ]]; then
            echo -e "${YELLOW}  Skipping (output already exists)${NC}"
            echo ""
            continue
        fi

        local total_dur
        total_dur=$(total_duration "${parts[@]}")
        echo -e "  Duration: $(format_duration "$total_dur")"

        encode_title "$output" "$total_dur" "${parts[@]}"
    done

    echo -e "${GREEN}${BOLD}All done! Files are in: $output_dir${NC}"
}

main "$@"
