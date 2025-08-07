#!/usr/bin/env bash
set -euo pipefail

# 1) Inputs
# Parse command line arguments. The first non-flag argument is treated as the
# channel URL. Two optional flags are supported:
#   --download-only  Only download videos, skip the upload phase
#   --upload-only    Only upload existing videos, skip downloading

DOWNLOAD_ONLY=false
UPLOAD_ONLY=false
CHANNEL_URL=""

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
    *)
      CHANNEL_URL="$1"      # e.g. https://www.youtube.com/c/MyChannel/videos
      shift
      ;;
  esac
done

if [[ -z "${CHANNEL_URL}" ]]; then
  echo "Usage: $0 [--download-only|--upload-only] <channel_url>" >&2
  exit 1
fi

if [[ "${DOWNLOAD_ONLY}" == true && "${UPLOAD_ONLY}" == true ]]; then
  echo "Cannot combine --download-only and --upload-only" >&2
  exit 1
fi

PEERTUBE_URL="" #URL of peertube instance
PEERTUBE_USER=""      # your PeerTube login
PEERTUBE_PASS=""  # your PeerTube password

# 2) Local dirs & archive
DOWNLOAD_DIR="./yt_downloads"
ARCHIVE_FILE="./yt-dlp-archive.txt"
mkdir -p "${DOWNLOAD_DIR}"

# 3) (Optional) authenticate once so future 'upload' calls omit creds
peertube-cli auth add \
  -u "${PEERTUBE_URL}" \
  -U "${PEERTUBE_USER}" \
  --password "${PEERTUBE_PASS}"

# 4) Grab every video URL from the channel
VIDEO_URLS=$(yt-dlp --dump-json --flat-playlist "${CHANNEL_URL}" \
              | jq -r '.url')  # list of URLs

# 5) Loop through each video
for VIDEO_URL in ${VIDEO_URLS}; do
  echo
  echo "=== Processing ${VIDEO_URL} ==="

  # 5a) Identify metadata JSON
  VIDEO_ID=$(echo "${VIDEO_URL}" | sed -n 's/.*v=\([^&]*\).*/\1/p')
  INFO_JSON="${DOWNLOAD_DIR}/${VIDEO_ID}.info.json"

  # 5b) Download (skip if seen before)
  if [[ "${UPLOAD_ONLY}" == false ]]; then
    yt-dlp -ciw \
      --download-archive "${ARCHIVE_FILE}" \
      -o "${DOWNLOAD_DIR}/%(id)s.%(ext)s" \
      "${VIDEO_URL}"
  fi

  # 5c) Extract title & description and upload
  if [[ "${DOWNLOAD_ONLY}" == false ]]; then
    yt-dlp --skip-download --write-info-json \
           -o "${DOWNLOAD_DIR}/${VIDEO_ID}.%(ext)s" \
           "${VIDEO_URL}"
    TITLE=$(jq -r '.title' < "${INFO_JSON}")
    DESCRIPTION=$(jq -r '.description' < "${INFO_JSON}")
    EXT=$(jq -r '.ext' < "${INFO_JSON}")
    FILE_PATH="${DOWNLOAD_DIR}/${VIDEO_ID}.${EXT}"

    # 5d) Upload to PeerTube
    peertube-cli upload \
      --file "${FILE_PATH}" \
      --url "${PEERTUBE_URL}" \
      --username "${PEERTUBE_USER}" \
      --password "${PEERTUBE_PASS}" \
      --video-name "${TITLE}" \
      --video-description "${DESCRIPTION}"
  fi
done
