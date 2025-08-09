# peertube-importer
Import videos from Youtube to Peertube using yt-dlp and peertube-cli.

## Usage

```
./peertube-importer.sh [--download-only|--upload-only] <channel_url>
```

Use `--download-only` to fetch videos and metadata without uploading them to
PeerTube. Use `--upload-only` to upload videos whose IDs are listed in
`yt-dlp-archive.txt` (lines like `youtube <video_id>`) and whose files and
metadata reside in `yt_downloads`. If a video has a custom thumbnail, the
script downloads it and sets it on the PeerTube upload.

Uploaded video IDs are tracked in `uploaded.txt`. Videos listed in this file
are skipped on subsequent runs to avoid re-uploading.

Each successful upload is also recorded in `uploaded-map.txt` as a mapping
between the YouTube video ID and the corresponding PeerTube video ID. When a
video already appears in this mapping, the script skips re-uploading and
instead compares the stored title, description, and thumbnail with the current
PeerTube metadata. Any differences are synchronized so existing uploads stay
up to date.

## Configuration
Copy `sample.env` to `.env` and set `BASE_DIR`, `PEERTUBE_URL`, `PEERTUBE_USER`
and `PEERTUBE_PASS` before running the script. Set
`USE_FIREFOX_COOKIES=true` if yt-dlp should use Firefox browser cookies for
authenticated downloads. The PeerTube variables are only required when uploading.
