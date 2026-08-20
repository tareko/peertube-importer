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
PEERTUBE_CLIENT_ID=""
PEERTUBE_CLIENT_SECRET=""
PEERTUBE_TOKEN=""

fetch_client_credentials() {
  if [[ -z "${PEERTUBE_CLIENT_ID:-}" || -z "${PEERTUBE_CLIENT_SECRET:-}" ]]; then
    local creds
    creds=$(curl -fsSL "${PEERTUBE_URL}/api/v1/oauth-clients/local" 2>/dev/null || true)
    PEERTUBE_CLIENT_ID=$(jq -r '.client_id // empty' <<<"${creds}")
    PEERTUBE_CLIENT_SECRET=$(jq -r '.client_secret // empty' <<<"${creds}")
  fi
}

fetch_peertube_token() {
  if [[ -z "${PEERTUBE_TOKEN:-}" ]]; then
    PEERTUBE_TOKEN=$(curl -fsSL "${PEERTUBE_URL}/api/v1/users/token" \
      --data-urlencode "client_id=${PEERTUBE_CLIENT_ID}" \
      --data-urlencode "client_secret=${PEERTUBE_CLIENT_SECRET}" \
      --data-urlencode "grant_type=password" \
      --data-urlencode "username=${PEERTUBE_USER}" \
      --data-urlencode "password=${PEERTUBE_PASS}" \
      | jq -r '.access_token // empty' || true)
  fi
}

if [[ "$DOWNLOAD_ONLY" == false ]]; then
  peertube-cli auth add \
    -u "${PEERTUBE_URL}" \
    -U "${PEERTUBE_USER}" \
    --password "${PEERTUBE_PASS}"
  fetch_client_credentials
  fetch_peertube_token
fi


# 4) Grab every video URL from the channel
if [[ "$UPLOAD_ONLY" == false ]]; then
  # Read all video URLs into an array. Quoting each entry avoids the shell
  # treating characters like '&' as control operators during iteration.
  mapfile -t VIDEO_URLS < <(yt-dlp --js-runtimes node "${YTDLP_COOKIES[@]}" --dump-json --flat-playlist "${CHANNEL_URL}" \
    | jq -r '.url')
else
  VIDEO_URLS=()
fi

# 5) Loop through each video

# Ensure thumbnails are PNG; convert WebP inputs when needed
ensure_png_thumbnail() {
  local in_file="$1" lower output
  lower="${in_file,,}"
  if [[ "$lower" == *.webp ]]; then
    output="${in_file%.*}.png"
    if [[ ! -f "$output" ]]; then
      if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -loglevel error -y -i "$in_file" "$output" || return 1
      else
        echo "ffmpeg is required to convert WebP thumbnails" >&2
        return 1
      fi
    fi
    echo "$output"
  else
    echo "$in_file"
  fi
}

# Upload thumbnail and preview images to an existing PeerTube video via REST API
upload_thumbnail() {
  local peertube_id="$1" thumb_file="$2" mime
  thumb_file=$(ensure_png_thumbnail "$thumb_file") || return
  fetch_peertube_token
  [[ -z "${PEERTUBE_TOKEN:-}" ]] && return
  mime=$(file -b --mime-type "${thumb_file}" 2>/dev/null || echo image/png)
  curl -fsSL -X PUT "${PEERTUBE_URL}/api/v1/videos/${peertube_id}" \
    -H "Authorization: Bearer ${PEERTUBE_TOKEN}" \
    -F "thumbnailfile=@${thumb_file};type=${mime}" \
    -F "previewfile=@${thumb_file};type=${mime}" >/dev/null
}

# Update metadata and thumbnail of an already uploaded video if needed
sync_metadata() {
  local vid="$1" peertube_id="$2"
  fetch_peertube_token
  local thumb_path info_json remote_json remote_title remote_desc
  thumb_path=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \
    \( -iname "${vid}.jpg" -o -iname "${vid}.jpeg" -o -iname "${vid}.png" -o -iname "${vid}.webp" \) \
    | head -n 1 || true)
  if [[ -n "${thumb_path}" ]]; then
    thumb_path=$(realpath "${thumb_path}")
    thumb_path=$(ensure_png_thumbnail "${thumb_path}" || true)
  fi
  info_json="${DOWNLOAD_DIR}/${vid}.info.json"
  remote_json=$(curl -fsSL "${PEERTUBE_URL}/api/v1/videos/${peertube_id}" \
    -H "Authorization: Bearer ${PEERTUBE_TOKEN}" 2>/dev/null || true)
  if [[ -n "${remote_json}" ]]; then
    remote_title=$(jq -r '.name // empty' <<<"${remote_json}" 2>/dev/null || true)
    remote_desc=$(jq -r '.description // empty' <<<"${remote_json}" 2>/dev/null || true)
  else
    remote_title=""
    remote_desc=""
  fi

  local thumb_updated=false meta_updated=false
  if [[ -n "${thumb_path}" ]]; then
    echo "Uploading thumbnail for ${vid} (${peertube_id})"
    upload_thumbnail "${peertube_id}" "${thumb_path}" \
      || echo "Warning: thumbnail upload failed for ${vid}, continuing" >&2
    thumb_updated=true
  fi

  local local_title local_desc
  local_title=$(jq -r '.title // empty' < "${info_json}" 2>/dev/null || true)
  local_desc=$(jq -r '.description // empty' < "${info_json}" 2>/dev/null || true)
  if [[ -n "${remote_json}" && ( ( -n "${local_title}" && "${local_title}" != "${remote_title}" ) || \
        "${local_desc}" != "${remote_desc}" ) ]]; then
    echo "Updating metadata for ${vid} (${peertube_id})"
    local channel_id privacy
    channel_id=$(jq -r '.channel.id' <<<"${remote_json}" 2>/dev/null || true)
    privacy=$(jq -r '.privacy' <<<"${remote_json}" 2>/dev/null || true)
    jq -n \
      --arg name "${local_title}" \
      --arg description "${local_desc}" \
      --arg channelId "${channel_id}" \
      --arg privacy "${privacy}" \
      '{name:$name, description:$description, channelId:($channelId|tonumber), privacy:($privacy|tonumber)}' \
      | curl -fsSL -X PUT "${PEERTUBE_URL}/api/v1/videos/${peertube_id}" \
        -H "Authorization: Bearer ${PEERTUBE_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary @- >/dev/null
    meta_updated=true
  fi

  # Self-heal the publish date for previously imported videos
  set_publish_date "${vid}" "${peertube_id}"

  if [[ "${thumb_updated}" == true || "${meta_updated}" == true ]]; then
    echo "Metadata synced for ${vid} (${peertube_id})"
  else
    echo "No updates needed for ${vid} (${peertube_id})"
  fi
}

# Set the PeerTube publish date for a video from its YouTube info.json
# timestamp. Tries a direct PostgreSQL update first (requires DB access from
# this host); falls back to running the update inside the Kubernetes cluster
# via kubectl. Failures are non-fatal: the import continues and the date can
# be fixed by a later full run of set_publish_date.py.
set_publish_date() {
  local vid="$1" peertube_id="$2" ts
  ts=$(jq -r '.timestamp // empty' "${DOWNLOAD_DIR}/${vid}.info.json" 2>/dev/null || true)
  if [[ -z "${ts}" ]]; then
    echo "No YouTube timestamp for ${vid}, leaving publish date as-is"
    return 0
  fi

  if python3 "$(dirname "$0")/set_publish_date.py" "${vid}" >/dev/null 2>&1; then
    echo "Publish date set for ${vid} (direct DB)"
    return 0
  fi
  echo "Direct DB update unavailable for ${vid}, trying cluster fallback..."

  # Fallback: update via the in-cluster PeerTube pod
  if command -v kubectl >/dev/null 2>&1; then
    local ns="${K8S_NAMESPACE:-peertube-podur}" selector="${K8S_POD_SELECTOR:-app=peertube}"
    local pod
    pod=$(kubectl get pods -n "${ns}" -l "${selector}" \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "${pod}" ]]; then
      if kubectl exec -i "${pod}" -n "${ns}" -- node -e "
import('/app/node_modules/pg/lib/index.js').then(async ({ default: pg }) => {
  const c = new pg.Client({
    host: process.env.PEERTUBE_DB_HOSTNAME,
    port: process.env.PEERTUBE_DB_PORT || '25060',
    user: process.env.PEERTUBE_DB_USERNAME,
    password: process.env.PEERTUBE_DB_PASSWORD,
    database: process.env.PEERTUBE_DB_NAME,
    ssl: { rejectUnauthorized: false }
  });
  await c.connect();
  const r = await c.query('UPDATE video SET \"publishedAt\" = to_timestamp(\$1) WHERE uuid = \$2', ['${ts}', '${peertube_id}']);
  await c.end();
  console.log('publish date updated: ' + r.rowCount + ' row(s)');
}).catch(e => { console.error(e.message); process.exit(1); });
" 2>/dev/null | grep -v '^Defaulted container'; then
        echo "Publish date set for ${vid} (${peertube_id}) via cluster"
        return 0
      fi
    fi
  fi

  echo "Warning: could not set publish date for ${vid}, continuing" >&2
  return 0
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
    ! -iname "*.png" ! -iname "*.webp" \
    ! -iname "*.vtt" ! -iname "*.srt" ! -iname "*.ass" | head -n 1)
  if [[ -z "${file_path}" ]]; then
    echo "No downloaded video file found for ${vid}, skipping"
    return 1
  fi
  file_path=$(realpath "${file_path}")
  thumb_path=$(find "${DOWNLOAD_DIR}" -maxdepth 1 -type f \
    \( -iname "${vid}.jpg" -o -iname "${vid}.jpeg" -o -iname "${vid}.png" \
       -o -iname "${vid}.webp" \) | head -n 1 || true)
  if [[ -n "${thumb_path}" ]]; then
    thumb_path=$(realpath "${thumb_path}")
    thumb_path=$(ensure_png_thumbnail "${thumb_path}" || true)
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
  upload_json=$("${upload_args[@]}")
  echo "${upload_json}"
  peertube_id=$(jq -r '.video.uuid // .video.shortUUID // .video.id // empty' <<<"${upload_json}" 2>/dev/null || true)
  if [[ -n "${peertube_id}" ]]; then
    # Record the mapping immediately so a failure in the thumbnail/date steps
    # below never causes a duplicate re-upload on the next run.
    echo "${vid} ${peertube_id}" >> "${UPLOAD_MAP_FILE}"
    if [[ -n "${thumb_path}" ]]; then
      upload_thumbnail "${peertube_id}" "${thumb_path}" \
        || echo "Warning: thumbnail upload failed for ${vid}, continuing" >&2
    fi
    set_publish_date "${vid}" "${peertube_id}"
  fi
  echo "${vid}" >> "${UPLOAD_ARCHIVE_FILE}"
}

# Download a single video at best quality along with its metadata, thumbnail,
# and subtitles. Uses the YouTube ID (%(id)s) as the filename stem so the
# output is consistent regardless of the URL form.
download_video() {
  local video_url="$1"
  yt-dlp --js-runtimes node "${YTDLP_COOKIES[@]}" -ciw \
    --download-archive "${ARCHIVE_FILE}" \
    -f "bv*+ba/b" \
    --merge-output-format mkv \
    --write-info-json \
    --write-thumbnail \
    --write-subs --write-auto-subs --sub-langs "en,en-orig" \
    -o "${DOWNLOAD_DIR}/%(id)s.%(ext)s" \
    "${video_url}"
}

process_video() {
  local video_url="$1" video_id
  echo
  echo "=== Processing ${video_url} ==="
  video_id=$(echo "${video_url}" | sed -n 's/.*v=\([^&]*\).*/\1/p')
  download_video "${video_url}"
  if [[ "$DOWNLOAD_ONLY" == false ]]; then
    upload_video "${video_id}"
  fi
}

if [[ "$UPLOAD_ONLY" == true ]]; then
  if [[ ! -f "${ARCHIVE_FILE}" ]]; then
    echo "Error: archive file ${ARCHIVE_FILE} not found."
    exit 1
  fi
  # Extract video IDs from lines like "youtube <id>" in the archive
  mapfile -t ARCHIVE_VIDS < <(awk '$1 == "youtube" {print $2}' "${ARCHIVE_FILE}")
  for vid in "${ARCHIVE_VIDS[@]}"; do
    upload_video "${vid}" || echo "Failed to upload ${vid}, continuing..." >&2
  done
else
  for VIDEO_URL in "${VIDEO_URLS[@]}"; do
    process_video "${VIDEO_URL}" || echo "Failed to process ${VIDEO_URL}, continuing..." >&2
  done
fi
