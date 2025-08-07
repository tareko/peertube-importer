#!/usr/bin/env bash
set -euo pipefail

# 1) Inputs
CHANNEL_URL=${1:-""}      # e.g. https://www.youtube.com/c/MyChannel/videos
BASE_DIR="" # Absolute path for directory where video files and metadata are stored
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
              | jq -r '.url')  # list of URLs :contentReference[oaicite:2]{index=2}

# 5) Loop through each video
for VIDEO_URL in ${VIDEO_URLS}; do
  echo
  echo "=== Processing ${VIDEO_URL} ==="

  # 5a) Download (skip if seen before)
  yt-dlp -ciw \
    --download-archive "${ARCHIVE_FILE}" \
    -o "${DOWNLOAD_DIR}/%(id)s.%(ext)s" \
    "${VIDEO_URL}"

echo "step 5b"

  # 5b) Identify local file & metadata JSON
  VIDEO_ID=$(echo "${VIDEO_URL}" | sed -n 's/.*v=\([^&]*\).*/\1/p')
  FILE_PATH="${BASE_DIR}/${VIDEO_ID}.webm"
  INFO_JSON="${DOWNLOAD_DIR}/${VIDEO_ID}.info.json"

  # 5c) Extract title & description
  yt-dlp --skip-download --write-info-json \
         -o "${DOWNLOAD_DIR}/${VIDEO_ID}.%(ext)s" \
         "${VIDEO_URL}"
  TITLE=$(jq -r '.title' < "${INFO_JSON}")
  DESCRIPTION=$(jq -r '.description' < "${INFO_JSON}")

  # 5d) Upload to PeerTube
  peertube-cli upload \
    --file "${FILE_PATH}" \
    --url "${PEERTUBE_URL}" \
    --username "${PEERTUBE_USER}" \
    --password "${PEERTUBE_PASS}" \
    --video-name "${TITLE}" \
    --video-description "${DESCRIPTION}"  # :contentReference[oaicite:3]{index=3}
done
