#!/usr/bin/env bash

DEBUG=0 # change value to 1 to enable debugging or 0 to disable it
DEBUG_LOG="/tmp/video_convert_debug.log"

debug() {
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "[DEBUG] $*" | tee -a "$DEBUG_LOG"
  fi
}

if [[ $# -lt 1 ]]; then
  zenity --error --text="Usage: $0 <file-or-directory> [more files/dirs...]"
  exit 1
fi

########################################
# CHECK VAAPI
########################################

VAAPI_AVAILABLE=0
if command -v vainfo >/dev/null 2>&1; then
  if vainfo 2>/dev/null | grep -q "VAEntrypointEncSlice"; then
    VAAPI_AVAILABLE=1
  fi
fi

VAAPI_AV1_AVAILABLE=0
if [[ "$VAAPI_AVAILABLE" -eq 1 ]]; then
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_vaapi"; then
    VAAPI_AV1_AVAILABLE=1
  fi
fi

debug "VAAPI=$VAAPI_AVAILABLE AV1_VAAPI=$VAAPI_AV1_AVAILABLE"

########################################
# FILE COLLECTION
########################################

files=()

for input in "$@"; do
  if [[ -d "$input" ]]; then
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "$input" -type f \( \
      -iname "*.mp4" -o \
      -iname "*.mkv" -o \
      -iname "*.mov" -o \
      -iname "*.avi" -o \
      -iname "*.mts" -o \
      -iname "*.m2ts" \
    \) ! -iname "*_resolve.mkv")
  else
    files+=("$input")
  fi
done

########################################
# PROCESS FILE (BUILD FFMPEG ARGS)
########################################

process_file_build_only() {
  local input="$1"

  local -A st_type=() st_name=()
  local -a idx_list=()

  # One authoritative dump, filtered to top-level streams only
  local line key val idx
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"   # strip flat-format quotes
    case "$key" in
      streams.stream.*.codec_type)
        idx="${key#streams.stream.}"
        idx="${idx%.codec_type}"
        st_type[$idx]="$val"
        idx_list+=("$idx")
        ;;
      streams.stream.*.codec_name)
        idx="${key#streams.stream.}"
        idx="${idx%.codec_name}"
        st_name[$idx]="$val"
        ;;
      *) ;;   # skips programs.program.* and stream_groups.* entirely
    esac
  done < <(ffprobe -v error -of flat -show_entries stream=index,codec_type,codec_name "$input")

  # Walk streams in ascending index order
  local video_indices=() video_codecs=()
  local audio_indices=() audio_codecs=()
  local idx sorted
  while IFS= read -r idx; do
    [[ -z "$idx" ]] && continue
    case "${st_type[$idx]}" in
      video)
        [[ -z "${st_name[$idx]}" ]] && continue   # tmcd / data pseudo-streams
        video_indices+=("$idx")
        video_codecs+=("${st_name[$idx]}")
        ;;
      audio)
        audio_indices+=("$idx")
        audio_codecs+=("${st_name[$idx]}")
        ;;
    esac
  done < <(printf '%s\n' "${idx_list[@]}" | sort -n)

  debug "video: ${video_codecs[*]:-none} @ ${video_indices[*]:-none}"
  debug "audio: ${audio_codecs[*]:-none} @ ${audio_indices[*]:-none}"

  ffmpeg_args=(-i "$input")

  for idx in "${video_indices[@]}"; do
    ffmpeg_args+=(-map "0:$idx")
  done
  ffmpeg_args+=(-map 0:a? -map 0:s? -c:s copy)

  local o=0 codec
  for codec in "${video_codecs[@]}"; do
    if [[ "$codec" == "mjpeg" || "$codec" == "png" || "$codec" == "av1" ]]; then
      debug "Output v:$o ($codec) - passthrough"
      ffmpeg_args+=(-c:v:$o copy)
    elif [[ "$VAAPI_AV1_AVAILABLE" -eq 1 && $o -eq 0 ]]; then
      ffmpeg_args+=(
        -vaapi_device /dev/dri/renderD128
        -filter:v:0 format=nv12,hwupload
        -c:v:$o av1_vaapi
        -rc_mode VBR
        -qp 20
      )
    else
      ffmpeg_args+=(-c:v:$o libsvtav1 -preset 6 -crf 24)
    fi
    ((o++))
  done

  o=0
  for codec in "${audio_codecs[@]}"; do
    case "$codec" in
      flac|pcm*|alac) ffmpeg_args+=(-c:a:$o copy) ;;
      *)              ffmpeg_args+=(-c:a:$o flac -compression_level 5) ;;
    esac
    ((o++))
  done
}

########################################
# ZENITY SETUP (BATCH MODE)
########################################

total_files=${#files[@]}
current=0
any_failed=0

FIFO=$(mktemp -u)
mkfifo "$FIFO"

zenity --progress \
  --title="Video Conversion" \
  --percentage=0 \
  --auto-close < "$FIFO" &

ZENITY_PID=$!
exec 3> "$FIFO"
rm "$FIFO"

debug "Zenity PID=$ZENITY_PID batch size=$total_files"

########################################
# MAIN LOOP
########################################

for file in "${files[@]}"; do
  current=$((current + 1))

  filename=$(basename "$file")
  echo "# Converting ($current/$total_files)\n$filename" >&3

  output="${file%.*}_${file##*.}_resolve.mkv"

  if [[ -e "$output" ]]; then
    debug "Skipping (exists): $output"
    percent=$((current * 100 / total_files))
    echo "$percent" >&3
    continue
  fi

  process_file_build_only "$file"

  debug "FFMPEG CMD: ffmpeg -y ${ffmpeg_args[*]} \"$output\""

  ERRLOG=$(mktemp)
  if [[ "$DEBUG" -eq 1 ]]; then
    ffmpeg -y "${ffmpeg_args[@]}" "$output" > >(tee -a "$DEBUG_LOG") 2>&1 &
  else
    ffmpeg -y "${ffmpeg_args[@]}" "$output" > "$ERRLOG" 2>&1 &
  fi
  FFMPEG_PID=$!

  while kill -0 "$FFMPEG_PID" 2>/dev/null; do

    # GLOBAL CANCEL
    if ! kill -0 "$ZENITY_PID" 2>/dev/null; then
      debug "Batch cancel detected"

      kill -TERM "$FFMPEG_PID" 2>/dev/null

      # give ffmpeg time to exit cleanly
      for i in {1..10}; do
        if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
          break
        fi
        sleep 0.1
      done

      # fallback ONLY if still alive
      kill -KILL "$FFMPEG_PID" 2>/dev/null
      wait "$FFMPEG_PID" 2>/dev/null
      rm -f "$output"
      rm -f "$ERRLOG"

      exec 3>&-
      zenity --warning --text="Conversion cancelled."
      exit 1
    fi

    sleep 0.2
  done

  wait "$FFMPEG_PID"
  status=$?

  if [[ $status -ne 0 ]]; then
    any_failed=1
    debug "Failed: $file"
    {
      echo "===== FAILED: $file ====="
      cat "$ERRLOG"
    } >> "$DEBUG_LOG"
  fi
  rm -f "$ERRLOG"

  # UPDATE PROGRESS BAR
  percent=$((current * 100 / total_files))
  echo "$percent" >&3
done

########################################
# CLEANUP
########################################

exec 3>&-
wait "$ZENITY_PID" 2>/dev/null

if [[ $any_failed -eq 1 ]]; then
  zenity --warning --text="Some conversions failed."
else
  zenity --info --text="Conversion complete."
fi
