#!/usr/bin/env python3
"""Replace video source files on PeerTube with higher quality versions.

Uses PeerTube's resumable source replacement API (>= 6.0) to swap the video
file of an existing video while preserving its UUID, metadata, comments, etc.
Reads YouTube->PeerTube ID mappings from uploaded-map.txt.
"""

import json
import mimetypes
import os
import sys
import time
from pathlib import Path

import requests

DOWNLOAD_DIR = Path("./yt_downloads")
MAP_FILE = Path("./uploaded-map.txt")
VIDEO_EXTS = ["mkv", "webm", "mp4", "m4v"]
CHUNK_SIZE = 8 * 1024 * 1024  # 8 MB


def load_env(path: str = ".env") -> dict:
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    env[key.strip()] = val.strip().strip("'\"")
    except FileNotFoundError:
        pass
    return env


def get_token(base_url: str, user: str, password: str) -> str:
    creds = requests.get(f"{base_url}/api/v1/oauth-clients/local").json()
    resp = requests.post(
        f"{base_url}/api/v1/users/token",
        data={
            "client_id": creds["client_id"],
            "client_secret": creds["client_secret"],
            "grant_type": "password",
            "username": user,
            "password": password,
        },
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def read_map(path: Path) -> dict:
    mapping = {}
    if path.exists():
        with path.open() as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2:
                    mapping[parts[0]] = parts[1]
    return mapping


def find_video_file(yt_id: str) -> Path | None:
    for ext in VIDEO_EXTS:
        candidate = DOWNLOAD_DIR / f"{yt_id}.{ext}"
        if candidate.exists():
            return candidate
    return None


def replace_source(
    base_url: str, token: str, video_id: str, file_path: Path
) -> bool:
    file_size = file_path.stat().st_size
    mime, _ = mimetypes.guess_type(str(file_path))
    if mime is None:
        mime = "video/x-matroska"

    # 1) Initialize resumable upload
    resp = requests.post(
        f"{base_url}/api/v1/videos/{video_id}/source/replace-resumable",
        headers={
            "Authorization": f"Bearer {token}",
            "X-Upload-Content-Length": str(file_size),
            "X-Upload-Content-Type": mime,
        },
        json={"filename": file_path.name},
    )
    if resp.status_code == 413:
        body = resp.json()
        print(f"  REJECTED (too large): {body}")
        return False
    if resp.status_code == 415:
        print(f"  REJECTED (unsupported type {mime})")
        return False
    if resp.status_code not in (200, 201):
        print(f"  Init failed: {resp.status_code} {resp.text[:200]}")
        return False

    location = resp.headers.get("Location")
    if not location:
        print("  No Location header in response")
        return False

    # 2) Upload chunks
    uploaded = 0
    with file_path.open("rb") as f:
        while uploaded < file_size:
            chunk = f.read(CHUNK_SIZE)
            if not chunk:
                break
            chunk_len = len(chunk)
            content_range = f"bytes {uploaded}-{uploaded + chunk_len - 1}/{file_size}"

            put_resp = requests.put(
                location,
                data=chunk,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Range": content_range,
                    "Content-Length": str(chunk_len),
                    "Content-Type": "application/octet-stream",
                },
            )

            if put_resp.status_code in (204, 308):
                uploaded += chunk_len
                pct = uploaded / file_size * 100
                print(
                    f"\r  {pct:.0f}% ({uploaded // 1048576}/{file_size // 1048576} MB)",
                    end="",
                    flush=True,
                )
                if put_resp.status_code == 204:
                    break
            elif put_resp.status_code == 409:
                # Chunk doesn't match range — resync using Range header
                range_hdr = put_resp.headers.get("Range", "")
                if range_hdr.startswith("bytes="):
                    received = int(range_hdr.split("=")[1].split("-")[1]) + 1
                    f.seek(received)
                    uploaded = received
                else:
                    print(f"\n  Range conflict: {put_resp.text[:200]}")
                    return False
            else:
                print(
                    f"\n  Upload failed at byte {uploaded}: "
                    f"{put_resp.status_code} {put_resp.text[:200]}"
                )
                return False

    print()
    return True


def main() -> None:
    env = load_env()
    base_url = env["PEERTUBE_URL"].rstrip("/")
    token = get_token(base_url, env["PEERTUBE_USER"], env["PEERTUBE_PASS"])
    yt_map = read_map(MAP_FILE)

    # Determine which videos to process
    if len(sys.argv) > 1:
        target_vids = sys.argv[1:]
    else:
        target_vids = None  # all upgraded

    success = 0
    failed = 0
    skipped = 0

    for yt_id, pt_id in sorted(yt_map.items()):
        file_path = find_video_file(yt_id)
        if not file_path:
            continue
        if target_vids and yt_id not in target_vids:
            continue

        size_mb = file_path.stat().st_size // 1048576
        print(f"{yt_id} -> {pt_id}  ({file_path.name}, {size_mb} MB)")

        if replace_source(base_url, token, pt_id, file_path):
            print("  Done — transcoding will process in background")
            success += 1
        else:
            failed += 1

        time.sleep(1)

    print(f"\nReplaced {success}, failed {failed}, skipped {skipped}")


if __name__ == "__main__":
    main()
