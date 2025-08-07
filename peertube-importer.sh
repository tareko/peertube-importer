#!/usr/bin/env bash
set -euo pipefail

# 1) Inputs
CHANNEL_URL=${1:-""}      # e.g. https://www.youtube.com/c/MyChannel/videos

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
: "${PEERTUBE_URL:?PEERTUBE_URL is not set}"
: "${PEERTUBE_USER:?PEERTUBE_USER is not set}"
: "${PEERTUBE_PASS:?PEERTUBE_PASS is not set}"

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
  FILE_PATH=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -name "${VIDEO_ID}.*" ! -name "*.info.json" | head -n 1)
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
