#!/usr/bin/env bash
set -euo pipefail

VIDEO_DIR="content/videos"
INPUT_FILE=""
MAX_SIDE=1280
CRF=24
PRESET="medium"
AUDIO_BITRATE="128k"
DELETE_SOURCE=0
MIN_GAIN="32k"
MIN_GAIN_BYTES=32768

usage() {
  cat <<'EOF'
Usage: optimize-videos.sh [--dir DIR] [--file FILE] [--max-side PX] [--crf N] [--preset NAME] [--audio-bitrate RATE] [--min-gain SIZE] [--delete-source]

Defaults:
  --dir content/videos
  --file (off)
  --max-side 1280
  --crf 24
  --preset medium
  --audio-bitrate 128k
  --min-gain 32k
  --delete-source (off)

SIZE format examples for --min-gain:
  4096, 4k, 512K, 2m, 1M
EOF
}

parse_size_to_bytes() {
  local raw="$1"
  local value unit

  if [[ "$raw" =~ ^([0-9]+)([kKmM]?)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    echo "Некорректный размер: $raw" >&2
    return 1
  fi

  case "$unit" in
    "" ) echo "$value" ;;
    k|K) echo $((value * 1024)) ;;
    m|M) echo $((value * 1024 * 1024)) ;;
    *)
      echo "Некорректная единица размера: $raw" >&2
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      VIDEO_DIR="$2"
      shift 2
      ;;
    --file)
      INPUT_FILE="$2"
      shift 2
      ;;
    --max-side)
      MAX_SIDE="$2"
      shift 2
      ;;
    --crf)
      CRF="$2"
      shift 2
      ;;
    --preset)
      PRESET="$2"
      shift 2
      ;;
    --audio-bitrate)
      AUDIO_BITRATE="$2"
      shift 2
      ;;
    --min-gain)
      MIN_GAIN="$2"
      shift 2
      ;;
    --delete-source)
      DELETE_SOURCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown аргумент: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! MIN_GAIN_BYTES=$(parse_size_to_bytes "$MIN_GAIN"); then
  usage >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/$VIDEO_DIR"

if [[ -n "$INPUT_FILE" ]]; then
  if [[ "$INPUT_FILE" = /* ]]; then
    INPUT_FILE="$INPUT_FILE"
  else
    INPUT_FILE="$ROOT_DIR/$INPUT_FILE"
  fi
  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Файл не найден: $INPUT_FILE" >&2
    exit 1
  fi
fi

if [[ -z "$INPUT_FILE" && ! -d "$TARGET_DIR" ]]; then
  echo "Директория не найдена: $TARGET_DIR" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Нужен ffmpeg." >&2
  echo "Для Ubuntu/Debian: apt-get update && apt-get install -y ffmpeg" >&2
  exit 1
fi

size_bytes() {
  if stat -c%s "$1" >/dev/null 2>&1; then
    stat -c%s "$1"
  else
    stat -f%z "$1"
  fi
}

optimize_file() {
  local src="$1"
  local ext base dst tmp new_size old_size old_dst_size gain
  ext=$(echo "${src##*.}" | tr '[:upper:]' '[:lower:]')
  base="${src%.*}"
  dst="${base}.mp4"
  tmp="${base}.opt.$$.mp4"

  local vf
  vf="scale='trunc(if(gte(iw,ih),min(iw,${MAX_SIDE}),-2)/2)*2':'trunc(if(gte(ih,iw),min(ih,${MAX_SIDE}),-2)/2)*2':flags=lanczos"

  if ! ffmpeg -nostdin -y -hide_banner -loglevel error \
    -i "$src" \
    -map 0:v:0 -map 0:a? \
    -c:v libx264 -preset "$PRESET" -crf "$CRF" \
    -pix_fmt yuv420p \
    -movflags +faststart \
    -vf "$vf" \
    -c:a aac -b:a "$AUDIO_BITRATE" -ac 2 \
    "$tmp"; then
    rm -f "$tmp"
    echo "Ошибка обработки: $src" >&2
    return 1
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "Пустой результат: $src" >&2
    return 1
  fi

  new_size=$(size_bytes "$tmp")

  if [[ "$ext" == "mp4" ]]; then
    old_size=$(size_bytes "$src")
    gain=$((old_size - new_size))
    if [[ $gain -ge $MIN_GAIN_BYTES ]]; then
      mv -f "$tmp" "$src"
      echo "OK: $src (${old_size} -> ${new_size} байт, -${gain})"
    else
      rm -f "$tmp"
      if [[ $new_size -ge $old_size ]]; then
        echo "SKIP (больше): $src (${old_size} -> ${new_size} байт)"
      else
        echo "SKIP (выигрыш < ${MIN_GAIN_BYTES} байт): $src (${old_size} -> ${new_size} байт, -${gain})"
      fi
    fi
    return 0
  fi

  if [[ -f "$dst" ]]; then
    old_dst_size=$(size_bytes "$dst")
    gain=$((old_dst_size - new_size))
    if [[ $gain -ge $MIN_GAIN_BYTES ]]; then
      mv -f "$tmp" "$dst"
      echo "OK: $dst (${old_dst_size} -> ${new_size} байт, -${gain})"
      if [[ $DELETE_SOURCE -eq 1 ]]; then
        rm -f "$src"
        echo "Удалён исходник: $src"
      fi
    else
      rm -f "$tmp"
      if [[ $new_size -ge $old_dst_size ]]; then
        echo "SKIP (не лучше текущего mp4): $src"
      else
        echo "SKIP (выигрыш < ${MIN_GAIN_BYTES} байт): $src"
      fi
    fi
  else
    mv -f "$tmp" "$dst"
    echo "OK: $src -> $dst (${new_size} байт)"
    if [[ $DELETE_SOURCE -eq 1 ]]; then
      rm -f "$src"
      echo "Удалён исходник: $src"
    fi
  fi
}

export LC_ALL=C

if [[ -n "$INPUT_FILE" ]]; then
  optimize_file "$INPUT_FILE"
else
  find "$TARGET_DIR" -type f \( \
    -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.webm' \
  \) -print0 |
    while IFS= read -r -d '' file; do
      optimize_file "$file"
    done
fi
