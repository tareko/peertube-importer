# peertube-importer
Import videos from Youtube to Peertube using yt-dlp and peertube-cli.

## Usage

```
./peertube-importer.sh [--download-only|--upload-only] [<channel_url>]
```

* `--download-only` – Fetch videos but skip uploading.
* `--upload-only` – Upload previously downloaded videos without fetching new ones (channel URL optional).

If no option is provided, the script downloads and uploads each video sequentially. The channel URL is required unless `--upload-only` is specified.
