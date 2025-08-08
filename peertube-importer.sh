#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# 1) Inputs
CHANNEL_URL=""
DOWNLOAD_ONLY=false
UPLOAD_ONLY=false

usage() {
  echo "Usage: $0 [--download-only|--upload-only] <channel_url>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-only)
      DOWNLOAD_ONLY=true
      shift
      ;;
    --upload-only)
      UPLOAD_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$CHANNEL_URL" ]]; then
        CHANNEL_URL="$1"
      else
        echo "Unknown argument: $1"
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ "$DOWNLOAD_ONLY" == true && "$UPLOAD_ONLY" == true ]]; then
  echo "Error: --download-only and --upload-only cannot be used together."
  exit 1
fi

if [[ "$UPLOAD_ONLY" == false && -z "$CHANNEL_URL" ]]; then
  usage
  exit 1
fi

# Load environment variables
if [ -f ".env" ]; then
  # shellcheck disable=SC1091
  source ".env"
else
  echo "Error: .env file not found. Create one based on sample.env."
  exit 1
fi

# Ensure required variables are set
: "${BASE_DIR:?BASE_DIR is not set}"

if [[ "$DOWNLOAD_ONLY" == false ]]; then
  : "${PEERTUBE_URL:?PEERTUBE_URL is not set}"
  : "${PEERTUBE_USER:?PEERTUBE_USER is not set}"
  : "${PEERTUBE_PASS:?PEERTUBE_PASS is not set}"
fi

# 2) Local dirs & archive
DOWNLOAD_DIR="./yt_downloads"
ARCHIVE_FILE="./yt-dlp-archive.txt"
UPLOAD_ARCHIVE_FILE="./uploaded.txt"
mkdir -p "${DOWNLOAD_DIR}"
touch "${ARCHIVE_FILE}" "${UPLOAD_ARCHIVE_FILE}"

# 3) (Optional) authenticate once so future 'upload' calls omit creds
if [[ "$DOWNLOAD_ONLY" == false ]]; then
  peertube-cli auth add \
    -u "${PEERTUBE_URL}" \
    -U "${PEERTUBE_USER}" \
    --password "${PEERTUBE_PASS}"
fi

# 4) Grab every video URL from the channel
if [[ "$UPLOAD_ONLY" == false ]]; then
  # Read all video URLs into an array. Quoting each entry avoids the shell
  # treating characters like '&' as control operators during iteration.
  mapfile -t VIDEO_URLS < <(yt-dlp --dump-json --flat-playlist "${CHANNEL_URL}" \
    | jq -r '.url')
else
  VIDEO_URLS=()
fi

# 5) Loop through each video
upload_video() {
  local vid="$1"
  if grep -Fxq "$vid" "${UPLOAD_ARCHIVE_FILE}"; then
    echo "Skipping already uploaded video ${vid}"
    return
  fi
  local file_path info_json title description
  file_path=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -name "${vid}.*" ! -name "*.info.json" | head -n 1)
  file_path=$(realpath "${file_path}")
  info_json="${DOWNLOAD_DIR}/${vid}.info.json"
  title=$(jq -r '.title' < "${info_json}")
  description=$(jq -r '.description' < "${info_json}")
  peertube-cli upload \
    --file "${file_path}" \
    --url "${PEERTUBE_URL}" \
    --username "${PEERTUBE_USER}" \
    --password "${PEERTUBE_PASS}" \
    --video-name "${title}" \
    --video-description "${description}"  # :contentReference[oaicite:3]{index=3}
  echo "${vid}" >> "${UPLOAD_ARCHIVE_FILE}"
}

if [[ "$UPLOAD_ONLY" == true ]]; then
  if [[ ! -f "${ARCHIVE_FILE}" ]]; then
    echo "Error: archive file ${ARCHIVE_FILE} not found."
    exit 1
  fi
  # Extract video IDs from lines like "youtube <id>" in the archive
  mapfile -t ARCHIVE_VIDS < <(awk '$1 == "youtube" {print $2}' "${ARCHIVE_FILE}")
  for vid in "${ARCHIVE_VIDS[@]}"; do
    upload_video "${vid}"
  done
else
  for VIDEO_URL in "${VIDEO_URLS[@]}"; do
    echo
    echo "=== Processing ${VIDEO_URL} ==="

    VIDEO_ID=$(echo "${VIDEO_URL}" | sed -n 's/.*v=\([^&]*\).*/\1/p')

    # 5a) Download (skip if seen before)
    yt-dlp -ciw \
      --download-archive "${ARCHIVE_FILE}" \
      -o "${DOWNLOAD_DIR}/%(id)s.%(ext)s" \
      "${VIDEO_URL}"

    # 5b) Save metadata JSON
    yt-dlp --skip-download --write-info-json \
           -o "${DOWNLOAD_DIR}/${VIDEO_ID}.%(ext)s" \
           "${VIDEO_URL}"

    if [[ "$DOWNLOAD_ONLY" == false ]]; then
      upload_video "${VIDEO_ID}"
    fi
  done
fi
