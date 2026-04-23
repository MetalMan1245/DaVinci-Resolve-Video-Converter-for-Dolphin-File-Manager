#!/usr/bin/env bash

DEBUG=0   # set to 1 to enable debug output
DEBUG_LOG="/tmp/video_convert_debug.log"

debug() {
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "[DEBUG] $*" | tee -a "$DEBUG_LOG"
  fi
}

MODE=$(kdialog --menu "Select encoding mode:" \
  "auto" "Auto (VAAPI if available)" \
  "vaapi" "Force VAAPI (fast)" \
  "cpu" "Force CPU (SVT-AV1 quality)")

# User cancelled
if [[ $? -ne 0 ]]; then
  exit 0
fi

debug "Selected mode: $MODE"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <file-or-directory> [more files/dirs...]"
  exit 1
fi

VAAPI_AVAILABLE=0

if command -v vainfo >/dev/null 2>&1; then
  if vainfo 2>/dev/null | grep -q "VAEntrypointEncSlice"; then
    VAAPI_AVAILABLE=1
  fi
fi

debug "VAAPI available: $VAAPI_AVAILABLE"

VAAPI_AV1_AVAILABLE=0

if [[ "$VAAPI_AVAILABLE" -eq 1 ]]; then
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "av1_vaapi"; then
    VAAPI_AV1_AVAILABLE=1
  fi
fi

debug "VAAPI AV1 encoder available: $VAAPI_AV1_AVAILABLE"

files=()

for input in "$@"; do
  if [[ -d "$input" ]]; then
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "$input" -type f \( \
      -iname "*.mp4" -o \
      -iname "*.mkv" -o \
      -iname "*.mov" -o \
      -iname "*.avi" \
    \))
  else
    files+=("$input")
  fi
done

process_file() {
  local input="$1"
  local ext="${input##*.}"
  local base="${input%.*}"
  local output="${base}_${ext}_converted.mkv"

  local -a ffmpeg_args
  local -a audio_codecs
  local audio_map_index=0
  local stream

  debug "Input file: $input"
  debug "Output file: $output"

  local video_codec

  video_codec=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=nokey=1:noprint_wrappers=1 "$input")

  mapfile -t audio_codecs < <(
    ffprobe -v error -select_streams a \
      -show_entries stream=codec_name \
      -of default=nokey=1:noprint_wrappers=1 "$input"
  )

  ffmpeg_args=(-i "$input" -map 0 -c copy)

  if [[ "$video_codec" != "av1" ]]; then
    if [[ "$MODE" == "cpu" ]]; then
      debug "Forcing CPU encode"
      ffmpeg_args+=(-c:v libsvtav1 -preset 6 -crf 24)

    elif [[ "$MODE" == "vaapi" ]]; then
      debug "Forcing VAAPI encode"

      ffmpeg_args=(
        -vaapi_device /dev/dri/renderD128
        -i "$input"
        -map 0
        -vf "format=nv12,hwupload"
        -c:v av1_vaapi
        -rc_mode VBR
        -b:v 0
        -qp 20
      )

    else
      # AUTO MODE
      if [[ "$VAAPI_AV1_AVAILABLE" -eq 1 ]]; then
        debug "Auto: using VAAPI"

        ffmpeg_args=(
          -vaapi_device /dev/dri/renderD128
          -i "$input"
          -map 0
          -vf "format=nv12,hwupload"
          -c:v av1_vaapi
          -rc_mode VBR
          -b:v 0
          -qp 20
        )
      else
        debug "Auto: falling back to CPU"

        ffmpeg_args+=(-c:v libsvtav1 -preset 6 -crf 24)
      fi
    fi
  fi

  for codec in "${audio_codecs[@]}"; do
    stream="a:${audio_map_index}"

    if [[ "$codec" == "flac" ]]; then
      ffmpeg_args+=(-c:$stream copy)
    else
      ffmpeg_args+=(-c:$stream flac)
    fi

    ((audio_map_index++))
  done

  run_with_progress "Converting: $(basename "$input")" \
  ffmpeg "${ffmpeg_args[@]}" "$output"

  if [[ $? -ne 0 ]]; then
    debug "Conversion cancelled for $input"
    return
  fi
}

run_with_progress() {
  local title="$1"
  shift

  # Start ffmpeg in its own process group
  setsid "$@" &
  local ffmpeg_pid=$!

  # Get process group ID
  local pgid
  pgid=$(ps -o pgid= "$ffmpeg_pid" | tr -d ' ')

  debug "Started ffmpeg PID=$ffmpeg_pid PGID=$pgid"

  # Start progress dialog and get DBus ref
  local qdbus_ref
  qdbus_ref=$(kdialog --progressbar "$title" 0)

  # Main loop
  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep 0.2

    # Check cancel explicitly
    if qdbus "$qdbus_ref" wasCancelled | grep -q "true"; then
      debug "User pressed cancel — killing PGID $pgid"

      kill -TERM "-$pgid" 2>/dev/null
      sleep 0.3
      kill -KILL "-$pgid" 2>/dev/null

      qdbus "$qdbus_ref" close
      return 1
    fi
  done

  # Wait for ffmpeg to fully exit
  wait "$ffmpeg_pid"
  local exit_code=$?

  debug "ffmpeg exited with code $exit_code"

  # Close progress dialog
  qdbus "$qdbus_ref" close

  if [[ "$exit_code" -eq 0 ]]; then
    kdialog --title "Complete" --msgbox "Conversion Complete!"
    return 0
  else
    kdialog --title "Error" --msgbox "Conversion failed or was interrupted."
    return 1
  fi
}

for file in "${files[@]}"; do
  echo "[INFO] Processing: $file"
  process_file "$file"
done
