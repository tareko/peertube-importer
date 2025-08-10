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
UPLOAD_MAP_FILE="./uploaded-map.txt"
mkdir -p "${DOWNLOAD_DIR}"
touch "${ARCHIVE_FILE}" "${UPLOAD_ARCHIVE_FILE}" "${UPLOAD_MAP_FILE}"

# Optional yt-dlp cookies flag
YTDLP_COOKIES=()
if [[ "${USE_FIREFOX_COOKIES:-false}" == true ]]; then
  YTDLP_COOKIES+=(--cookies-from-browser firefox)
fi

# 3) (Optional) authenticate once so future 'upload' calls omit creds
if [[ "$DOWNLOAD_ONLY" == false ]]; then
  peertube-cli auth add \
    -u "${PEERTUBE_URL}" \
    -U "${PEERTUBE_USER}" \
    --password "${PEERTUBE_PASS}"
  PEERTUBE_TOKEN=$(curl -fsSL "${PEERTUBE_URL}/api/v1/users/token" \
    --data-urlencode "client_id=peertube-cli" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=${PEERTUBE_USER}" \
    --data-urlencode "password=${PEERTUBE_PASS}" \
    | jq -r '.access_token // empty' || true)
fi


# 4) Grab every video URL from the channel
if [[ "$UPLOAD_ONLY" == false ]]; then
  # Read all video URLs into an array. Quoting each entry avoids the shell
  # treating characters like '&' as control operators during iteration.
  mapfile -t VIDEO_URLS < <(yt-dlp "${YTDLP_COOKIES[@]}" --dump-json --flat-playlist "${CHANNEL_URL}" \
    | jq -r '.url')
else
  VIDEO_URLS=()
fi

# 5) Loop through each video

# Upload a thumbnail to an existing PeerTube video via REST API
upload_thumbnail() {
  local peertube_id="$1" thumb_file="$2"
  [[ -z "${PEERTUBE_TOKEN:-}" ]] && return
  curl -fsSL -X POST "${PEERTUBE_URL}/api/v1/videos/${peertube_id}/thumbnail" \
    -H "Authorization: Bearer ${PEERTUBE_TOKEN}" \
    -F "thumbnailfile=@${thumb_file}" >/dev/null
}

# Update metadata/thumbnail of an already uploaded video if needed
sync_metadata() {
  local vid="$1" peertube_id="$2"
  local info_json title description thumb_path remote_json remote_title remote_description remote_thumb
  info_json="${DOWNLOAD_DIR}/${vid}.info.json"
  title=$(jq -r '.title' < "${info_json}")
  description=$(jq -r '.description' < "${info_json}")
  thumb_path=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \
    \( -iname "${vid}.jpg" -o -iname "${vid}.jpeg" -o -iname "${vid}.png" -o -iname "${vid}.webp" \) \
    | head -n 1 || true)
  if [[ -n "${thumb_path}" ]]; then
    thumb_path=$(realpath "${thumb_path}")
  fi
  remote_json=$(peertube-cli video-get --id "${peertube_id}" --url "${PEERTUBE_URL}" \
    --username "${PEERTUBE_USER}" --password "${PEERTUBE_PASS}" 2>/dev/null || true)
  if [[ -n "${remote_json}" ]]; then
    remote_title=$(jq -r '.name // .title // empty' <<<"${remote_json}" 2>/dev/null || true)
    remote_description=$(jq -r '.description // empty' <<<"${remote_json}" 2>/dev/null || true)
    remote_thumb=$(jq -r '.thumbnailPath // .thumbnailUrl // empty' <<<"${remote_json}" 2>/dev/null || true)
  else
    remote_title=""
    remote_description=""
    remote_thumb=""
  fi

  update_args=(
    peertube-cli video-update
    --id "${peertube_id}"
    --url "${PEERTUBE_URL}"
    --username "${PEERTUBE_USER}"
    --password "${PEERTUBE_PASS}"
  )
  local update=false
  if [[ "${title}" != "${remote_title}" ]]; then
    update_args+=(--video-name "${title}")
    update=true
  fi
  if [[ "${description}" != "${remote_description}" ]]; then
    update_args+=(--video-description "${description}")
    update=true
  fi
  local thumb_updated=false
  if [[ -n "${thumb_path}" ]]; then
    local local_hash remote_hash="" remote_thumb_url
    local_hash=$(sha256sum "${thumb_path}" | awk '{print $1}')
    if [[ -n "${remote_thumb}" ]]; then
      if [[ "${remote_thumb}" != http* ]]; then
        remote_thumb_url="${PEERTUBE_URL}${remote_thumb}"
      else
        remote_thumb_url="${remote_thumb}"
      fi
      remote_hash=$(curl -fsSL "${remote_thumb_url}" | sha256sum | awk '{print $1}' || true)
    fi
    if [[ -z "${remote_hash}" || "${local_hash}" != "${remote_hash}" ]]; then
      echo "Uploading thumbnail for ${vid} (${peertube_id})"
      upload_thumbnail "${peertube_id}" "${thumb_path}"
      thumb_updated=true
    fi
  fi
  if [[ "${update}" == true ]]; then
    echo "Updating metadata for ${vid} (${peertube_id})"
    "${update_args[@]}"
  elif [[ "${thumb_updated}" == true ]]; then
    echo "Thumbnail updated for ${vid} (${peertube_id})"
  else
    echo "Metadata up to date for ${vid} (${peertube_id})"
  fi
}

# Try to find an existing PeerTube video ID by matching the title
find_existing_id() {
  local vid="$1" info_json title encoded_title search_json
  info_json="${DOWNLOAD_DIR}/${vid}.info.json"
  if [[ ! -f "${info_json}" ]]; then
    return
  fi
  title=$(jq -r '.title // empty' < "${info_json}" 2>/dev/null || true)
  if [[ -z "${title}" ]]; then
    return
  fi
  encoded_title=$(jq -rn --arg x "${title}" '$x|@uri')
  search_json=$(curl -s "${PEERTUBE_URL}/api/v1/search/videos?search=${encoded_title}" 2>/dev/null || true)
  jq -r --arg t "${title}" '.data[] | select(.name == $t) | (.uuid // .shortUUID // (.id|tostring))' <<<"${search_json}" 2>/dev/null | head -n 1
}

upload_video() {
  local vid="$1"
  local existing_id
  existing_id=$(awk -v v="$vid" '$1==v {print $2}' "${UPLOAD_MAP_FILE}" || true)
  if [[ -z "${existing_id}" ]]; then
    existing_id=$(find_existing_id "${vid}" || true)
    if [[ -n "${existing_id}" ]]; then
      echo "${vid} ${existing_id}" >> "${UPLOAD_MAP_FILE}"
    fi
  fi
  if [[ -n "${existing_id}" ]]; then
    echo "Video ${vid} already uploaded as ${existing_id}, syncing metadata"
    sync_metadata "${vid}" "${existing_id}"
    if ! grep -Fxq "${vid}" "${UPLOAD_ARCHIVE_FILE}"; then
      echo "${vid}" >> "${UPLOAD_ARCHIVE_FILE}"
    fi
    return
  fi
  if grep -Fxq "$vid" "${UPLOAD_ARCHIVE_FILE}"; then
    echo "Skipping already uploaded video ${vid} (no PeerTube id found)"
    return
  fi
  local file_path thumb_path info_json title description
  file_path=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -name "${vid}.*" \
    ! -name "*.info.json" ! -iname "*.jpg" ! -iname "*.jpeg" \
    ! -iname "*.png" ! -iname "*.webp" | head -n 1)
  file_path=$(realpath "${file_path}")
  thumb_path=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \
    \( -iname "${vid}.jpg" -o -iname "${vid}.jpeg" -o -iname "${vid}.png" \
       -o -iname "${vid}.webp" \) | head -n 1 || true)
  if [[ -n "${thumb_path}" ]]; then
    thumb_path=$(realpath "${thumb_path}")
  fi
  info_json="${DOWNLOAD_DIR}/${vid}.info.json"
  title=$(jq -r '.title' < "${info_json}")
  description=$(jq -r '.description' < "${info_json}")
  echo "Uploading ${title} (YouTube ID: ${vid})"
  upload_args=(
    peertube-cli upload
    --file "${file_path}"
    --url "${PEERTUBE_URL}"
    --username "${PEERTUBE_USER}"
    --password "${PEERTUBE_PASS}"
    --video-name "${title}"
    --video-description "${description}"
  )
  if [[ -n "${thumb_path}" ]]; then
    upload_args+=(--thumbnail "${thumb_path}")
  fi
  upload_json=$(${upload_args[@]})
  echo "${upload_json}"
  peertube_id=$(jq -r '.video.uuid // .video.shortUUID // .video.id // empty' <<<"${upload_json}" 2>/dev/null || true)
  if [[ -n "${peertube_id}" ]]; then
    echo "${vid} ${peertube_id}" >> "${UPLOAD_MAP_FILE}"
  fi
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
    yt-dlp "${YTDLP_COOKIES[@]}" -ciw \
      --download-archive "${ARCHIVE_FILE}" \
      --write-thumbnail \
      -o "${DOWNLOAD_DIR}/%(id)s.%(ext)s" \
      "${VIDEO_URL}"

    # 5b) Save metadata JSON
    yt-dlp "${YTDLP_COOKIES[@]}" --skip-download --write-info-json --write-thumbnail \
           -o "${DOWNLOAD_DIR}/${VIDEO_ID}.%(ext)s" \
           "${VIDEO_URL}"

    if [[ "$DOWNLOAD_ONLY" == false ]]; then
      upload_video "${VIDEO_ID}"
    fi
  done
fi
