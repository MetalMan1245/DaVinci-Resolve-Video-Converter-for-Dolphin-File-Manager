#!/usr/bin/env bash

DEBUG=0 # change value to 1 to enable debugging or 0 to disable it
DEBUG_LOG="/tmp/video_convert_debug.log"

debug() {
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "[DEBUG] $*" | tee -a "$DEBUG_LOG"
  fi
}

MODE="auto"

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
      -iname "*.avi" \
    \))
  else
    files+=("$input")
  fi
done

########################################
# RUN WITH PROGRESS (FIFO VERSION)
########################################

run_with_progress() {
  local title="$1"
  local output_file="$2"
  shift 2

  local cmd=("$@")

  ########################################
  # FIFO SETUP (CRITICAL FIX)
  ########################################

  FIFO=$(mktemp -u)
  mkfifo "$FIFO"

  zenity --progress \
    --title="$title" \
    --auto-close \
    --cancel-label="Cancel" \
    --text="Converting..." \
    < "$FIFO" &

  ZENITY_PID=$!
  exec 3> "$FIFO"
  rm -f "$FIFO"

  debug "Zenity PID=$ZENITY_PID"

  ########################################
  # RUN FFMPEG
  ########################################

  # run ffmpeg and capture REAL pid
  "${cmd[@]}" > >(tee -a "$DEBUG_LOG") 2>&1 &
  ffmpeg_pid=$!

  debug "ffmpeg PID=$ffmpeg_pid"

  ########################################
  # MONITOR LOOP
  ########################################

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do

    # CANCEL DETECTED
    if ! kill -0 "$ZENITY_PID" 2>/dev/null; then
      debug "Cancel detected"

      kill -TERM "$ffmpeg_pid" 2>/dev/null
      sleep 0.2
      kill -KILL "$ffmpeg_pid" 2>/dev/null
      wait "$ffmpeg_pid" 2>/dev/null

      [[ -f "$output_file" ]] && rm -f "$output_file"

      exec 3>&-

      zenity --warning \
        --title="Conversion Cancelled" \
        --text="The conversion was cancelled and partial output was removed."

      return 1
    fi

    echo "# Converting..." >&3
    sleep 0.5
  done

  wait "$ffmpeg_pid"
  local exit_code=$?

  exec 3>&-
  wait "$ZENITY_PID" 2>/dev/null

  if [[ "$exit_code" -eq 0 ]]; then
    zenity --info --title="Complete" --text="Conversion Complete!"
    return 0
  else
    [[ -f "$output_file" ]] && rm -f "$output_file"

    zenity --error --title="Error" --text="Conversion failed or was interrupted."
    return 1
  fi
}

########################################
# PROCESS FILE
########################################

process_file() {
  local input="$1"
  local ext="${input##*.}"
  local base="${input%.*}"
  local output="${base}_${ext}_resolve.mkv"

  debug "Input=$input"
  debug "Output=$output"

  local video_codec
  video_codec=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=nokey=1:noprint_wrappers=1 "$input")

  mapfile -t audio_codecs < <(
    ffprobe -v error -select_streams a \
      -show_entries stream=codec_name \
      -of default=nokey=1:noprint_wrappers=1 "$input"
  )

  ffmpeg_args=(-i "$input")

  # map only valid streams
  ffmpeg_args+=(-map 0:v?)
  ffmpeg_args+=(-map 0:a?)
  ffmpeg_args+=(-map 0:s?)

  ########################################
  # VIDEO ENCODE LOGIC
  ########################################

  if [[ "$video_codec" == "av1" ]]; then
    ffmpeg_args+=(-c:v copy)

  else
    if [[ "$MODE" == "cpu" ]]; then
      ffmpeg_args+=(-c:v libsvtav1 -preset 8 -crf 30)

    elif [[ "$MODE" == "vaapi" ]]; then
      ffmpeg_args+=(
        -vaapi_device /dev/dri/renderD128
        -vf format=nv12,hwupload
        -c:v av1_vaapi
        -rc_mode VBR
        -qp 20
      )

    else
      if [[ "$VAAPI_AV1_AVAILABLE" -eq 1 ]]; then
        ffmpeg_args+=(
          -vaapi_device /dev/dri/renderD128
          -vf format=nv12,hwupload
          -c:v av1_vaapi
          -rc_mode VBR
          -qp 20
        )
      else
        ffmpeg_args+=(-c:v libsvtav1 -preset 6 -crf 24)
      fi
    fi
  fi

  ########################################
  # AUDIO HANDLING
  ########################################

  audio_index=0
  for codec in "${audio_codecs[@]}"; do
    stream="a:${audio_index}"

    case "$codec" in
      flac|pcm*|alac)
        ffmpeg_args+=(-c:$stream copy)
        ;;
      *)
        ffmpeg_args+=(-c:$stream flac -compression_level 5)
        ;;
    esac

    ((audio_index++))
  done

  ########################################
  # RUN
  ########################################

  debug "FFMPEG CMD: ffmpeg -y ${ffmpeg_args[*]} \"$output\""

  if [[ ${#ffmpeg_args[@]} -lt 3 ]]; then
    debug "ERROR: ffmpeg_args too small"
    return 1
  fi

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

  ########################################
  # BUILD COMMAND (reuse your logic)
  ########################################

  output="${file%.*}_${file##*.}_resolve.mkv"

  process_file_build_only() {
    local input="$1"

    local video_codec
    video_codec=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name \
      -of default=nokey=1:noprint_wrappers=1 "$input")

    mapfile -t audio_codecs < <(
      ffprobe -v error -select_streams a \
        -show_entries stream=codec_name \
        -of default=nokey=1:noprint_wrappers=1 "$input"
    )

    ffmpeg_args=(-i "$input")

    ffmpeg_args+=(-map 0:v?)
    ffmpeg_args+=(-map 0:a?)
    ffmpeg_args+=(-map 0:s?)

    ########################################
    # VIDEO
    ########################################

    if [[ "$video_codec" == "av1" ]]; then
      ffmpeg_args+=(-c:v copy)
    else
      if [[ "$VAAPI_AV1_AVAILABLE" -eq 1 ]]; then
        ffmpeg_args+=(
          -vaapi_device /dev/dri/renderD128
          -vf format=nv12,hwupload
          -c:v av1_vaapi
          -rc_mode VBR
          -qp 20
        )
      else
        ffmpeg_args+=(-c:v libsvtav1 -preset 6 -crf 24)
      fi
    fi

    ########################################
    # AUDIO
    ########################################

    audio_index=0
    for codec in "${audio_codecs[@]}"; do
      stream="a:${audio_index}"

      case "$codec" in
        flac|pcm*|alac)
          ffmpeg_args+=(-c:$stream copy)
          ;;
        *)
          ffmpeg_args+=(-c:$stream flac -compression_level 5)
          ;;
      esac

      ((audio_index++))
    done
  }

  process_file_build_only "$file"

  debug "FFMPEG CMD: ffmpeg -y ${ffmpeg_args[*]} \"$output\""

  ########################################
  # RUN FFMPEG (BATCH CONTROLLED)
  ########################################

  ffmpeg -y "${ffmpeg_args[@]}" "$output" > >(tee -a "$DEBUG_LOG") 2>&1 &
  FFMPEG_PID=$!

  while kill -0 "$FFMPEG_PID" 2>/dev/null; do

    # 🔥 GLOBAL CANCEL
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
  fi

  ########################################
  # UPDATE PROGRESS BAR
  ########################################

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
