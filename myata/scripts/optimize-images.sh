#!/usr/bin/env bash
set -euo pipefail

MAX_SIDE=1000
JPEG_QUALITY=82
WEBP_QUALITY=82
IMAGE_DIR="content/images"

usage() {
  cat <<'EOF'
Usage: optimize-images.sh [--dir DIR] [--max PX] [--jpeg-quality Q] [--webp-quality Q]

Defaults:
  --dir content/images
  --max 1000
  --jpeg-quality 82
  --webp-quality 82
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      IMAGE_DIR="$2"
      shift 2
      ;;
    --max)
      MAX_SIDE="$2"
      shift 2
      ;;
    --jpeg-quality)
      JPEG_QUALITY="$2"
      shift 2
      ;;
    --webp-quality)
      WEBP_QUALITY="$2"
      shift 2
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

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/$IMAGE_DIR"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Директория не найдена: $TARGET_DIR" >&2
  exit 1
fi

HAS_MAGICK=0
MAGICK_LEGACY=0
if command -v magick >/dev/null 2>&1; then
  HAS_MAGICK=1
elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
  MAGICK_LEGACY=1
fi

HAS_SIPS=0
if command -v sips >/dev/null 2>&1; then
  HAS_SIPS=1
fi

if [[ $HAS_MAGICK -eq 0 && $MAGICK_LEGACY -eq 0 && $HAS_SIPS -eq 0 ]]; then
  echo "Нужен ImageMagick (magick или convert/identify) либо sips (macOS)." >&2
  echo "Для Ubuntu/Debian: apt-get update && apt-get install -y imagemagick" >&2
  exit 1
fi

size_bytes() {
  if stat -c%s "$1" >/dev/null 2>&1; then
    stat -c%s "$1"
  else
    stat -f%z "$1"
  fi
}

get_dims() {
  local file="$1"
  local out w h

  if [[ $HAS_MAGICK -eq 1 ]]; then
    magick identify -ping -format "%w %h" "$file" 2>/dev/null || true
    return
  fi

  if [[ $MAGICK_LEGACY -eq 1 ]]; then
    identify -ping -format "%w %h" "$file" 2>/dev/null || true
    return
  fi

  out=$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null || true)
  w=$(echo "$out" | awk '/pixelWidth/ {print $2}')
  h=$(echo "$out" | awk '/pixelHeight/ {print $2}')
  echo "$w $h"
}

process_file() {
  local file="$1"
  local ext tmp
  ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
  tmp="${file%.*}.opt.$$.${ext}"

  local dims w h needs_resize=0
  dims=$(get_dims "$file")
  w=$(echo "$dims" | awk '{print $1}')
  h=$(echo "$dims" | awk '{print $2}')

  if [[ -n "$w" && -n "$h" ]]; then
    if [[ "$w" -gt "$MAX_SIDE" || "$h" -gt "$MAX_SIDE" ]]; then
      needs_resize=1
    fi
  fi

  if [[ $HAS_MAGICK -eq 1 || $MAGICK_LEGACY -eq 1 ]]; then
    local magick_bin
    if [[ $HAS_MAGICK -eq 1 ]]; then
      magick_bin=(magick)
    else
      magick_bin=(convert)
    fi

    case "$ext" in
      jpg|jpeg)
        "${magick_bin[@]}" "$file" -auto-orient -resize "${MAX_SIDE}x${MAX_SIDE}>" -strip -quality "$JPEG_QUALITY" "$tmp"
        ;;
      png)
        "${magick_bin[@]}" "$file" -auto-orient -resize "${MAX_SIDE}x${MAX_SIDE}>" -strip -define png:compression-level=9 "$tmp"
        ;;
      webp)
        "${magick_bin[@]}" "$file" -auto-orient -resize "${MAX_SIDE}x${MAX_SIDE}>" -strip -quality "$WEBP_QUALITY" "$tmp"
        ;;
      *)
        echo "Пропуск (формат не поддержан): $file"
        return 0
        ;;
    esac
  else
    case "$ext" in
      jpg|jpeg)
        sips -s formatOptions "$JPEG_QUALITY" -Z "$MAX_SIDE" "$file" --out "$tmp" >/dev/null
        ;;
      png)
        sips -Z "$MAX_SIDE" "$file" --out "$tmp" >/dev/null
        ;;
      webp)
        echo "Пропуск (webp требует ImageMagick): $file"
        return 0
        ;;
      *)
        echo "Пропуск (формат не поддержан): $file"
        return 0
        ;;
    esac
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "Ошибка обработки: $file" >&2
    return 1
  fi

  local old_size new_size
  old_size=$(size_bytes "$file")
  new_size=$(size_bytes "$tmp")

  if [[ $needs_resize -eq 1 || $new_size -lt $old_size ]]; then
    mv -f "$tmp" "$file"
    echo "OK: $file (${old_size} -> ${new_size} байт)"
  else
    rm -f "$tmp"
    echo "SKIP (больше): $file (${old_size} -> ${new_size} байт)"
  fi
}

export LC_ALL=C

find "$TARGET_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 |
  while IFS= read -r -d '' file; do
    process_file "$file"
  done
