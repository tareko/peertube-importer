# peertube-importer
Import videos from Youtube to Peertube using yt-dlp and peertube-cli.

## Usage

```
./peertube-importer.sh [--download-only|--upload-only] <channel_url>
```

Use `--download-only` to fetch videos and metadata without uploading them to
PeerTube. Use `--upload-only` to upload previously downloaded videos located in
`yt_downloads`.

Uploaded video IDs are tracked in `uploaded.txt`. Videos listed in this file
are skipped on subsequent runs to avoid re-uploading.

## Configuration
Copy `sample.env` to `.env` and set `BASE_DIR`, `PEERTUBE_URL`, `PEERTUBE_USER`
and `PEERTUBE_PASS` before running the script. The PeerTube variables are only
required when uploading.
