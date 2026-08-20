#!/usr/bin/env python3
"""Re-upload upgraded videos to PeerTube, replacing old low-quality versions.

Uses the legacy upload endpoint (single request) for speed. For each video:
upload the new file, delete the old video, update uploaded-map.txt.
Safe to re-run: a progress file tracks completed uploads.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import requests

DOWNLOAD_DIR = Path("./yt_downloads")
MAP_FILE = Path("./uploaded-map.txt")
VIDEO_EXTS = ["mkv", "webm", "mp4", "m4v"]
DONE_FILE = Path("/tmp/opencode/reupload_done.txt")
THUMB_FAIL_FILE = Path("/tmp/opencode/reupload_thumb_fail.txt")


def load_env(path: str = ".env") -> dict:
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                env[key.strip()] = val.strip().strip("'\"")
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
    with path.open() as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) == 2:
                mapping[parts[0]] = parts[1]
    return mapping


def write_map(path: Path, mapping: dict) -> None:
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as f:
        for yt_id, pt_id in sorted(mapping.items()):
            f.write(f"{yt_id} {pt_id}\n")
    tmp.replace(path)


def find_video_file(yt_id: str) -> Path | None:
    for ext in VIDEO_EXTS:
        candidate = DOWNLOAD_DIR / f"{yt_id}.{ext}"
        if candidate.exists():
            return candidate
    return None


def read_done() -> set:
    if DONE_FILE.exists():
        return {l.strip() for l in DONE_FILE.open() if l.strip()}
    return set()


def mark_done(yt_id: str) -> None:
    with DONE_FILE.open("a") as f:
        f.write(f"{yt_id}\n")


def mark_thumb_fail(yt_id: str) -> None:
    with THUMB_FAIL_FILE.open("a") as f:
        f.write(f"{yt_id}\n")


def get_video_info(base_url: str, token: str, video_id: str) -> dict | None:
    resp = requests.get(
        f"{base_url}/api/v1/videos/{video_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return resp.json()


def delete_video(base_url: str, token: str, video_id: str) -> bool:
    resp = requests.delete(
        f"{base_url}/api/v1/videos/{video_id}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    return resp.status_code in (204, 404)


def upload_via_curl(
    base_url: str, token: str, file_path: Path,
    name: str, channel_id: int, privacy: int,
) -> str | None:
    desc_path = DOWNLOAD_DIR / f".{file_path.stem}.desc.tmp"
    result = subprocess.run(
        [
            "curl", "-s", "--max-time", "1800",
            f"{base_url}/api/v1/videos/upload",
            "-H", f"Authorization: Bearer {token}",
            "--form", f"videofile=@{file_path.resolve()}",
            "--form", f"channelId={channel_id}",
            "--form", f"name={name}",
            "--form", f"filename={file_path.name}",
            "--form", f"privacy={privacy}",
        ],
        capture_output=True,
        text=True,
        timeout=1800,
    )
    try:
        data = json.loads(result.stdout)
        return data.get("video", {}).get("uuid")
    except (json.JSONDecodeError, KeyError):
        print(f"  Upload response: {result.stdout[:300]}")
        if result.stderr:
            print(f"  Stderr: {result.stderr[:300]}")
        return None


def upload_thumbnail(base_url: str, token: str, video_id: str, yt_id: str) -> bool:
    thumb = None
    for ext in ("png", "jpg", "jpeg"):
        t = DOWNLOAD_DIR / f"{yt_id}.{ext}"
        if t.exists():
            thumb = t
            break
    if thumb is None:
        # Try webp -> convert
        webp = DOWNLOAD_DIR / f"{yt_id}.webp"
        if webp.exists():
            png = DOWNLOAD_DIR / f"{yt_id}.png"
            if not png.exists():
                subprocess.run(
                    ["ffmpeg", "-loglevel", "error", "-y", "-i", str(webp), str(png)],
                    check=False,
                )
            if png.exists():
                thumb = png
    if thumb is None:
        return True  # no thumbnail available, not a failure

    try:
        resp = requests.put(
            f"{base_url}/api/v1/videos/{video_id}",
            headers={"Authorization": f"Bearer {token}"},
            files={
                "thumbnailfile": (thumb.name, thumb.open("rb"), "image/png"),
                "previewfile": (thumb.name, thumb.open("rb"), "image/png"),
            },
            timeout=60,
        )
        return resp.status_code in (200, 204)
    except Exception:
        return False


def main() -> None:
    env = load_env()
    base_url = env["PEERTUBE_URL"].rstrip("/")
    token = get_token(base_url, env["PEERTUBE_USER"], env["PEERTUBE_PASS"])

    data = json.load(open("/tmp/opencode/quality_check.json"))
    upgradable = {vid: h for vid, h in data.items() if h > 400}
    yt_map = read_map(MAP_FILE)
    done = read_done()

    # Backup original mapping once
    backup = MAP_FILE.with_name("uploaded-map.txt.orig")
    if not backup.exists():
        import shutil
        shutil.copy2(MAP_FILE, backup)

    target_vids = set(sys.argv[1:]) if len(sys.argv) > 1 else None
    success = 0
    failed = 0
    skipped = 0

    for yt_id in sorted(upgradable):
        if yt_id in done:
            skipped += 1
            continue
        if target_vids and yt_id not in target_vids:
            continue

        file_path = find_video_file(yt_id)
        if not file_path:
            continue

        old_pt_id = yt_map.get(yt_id)
        if not old_pt_id:
            print(f"{yt_id}: no mapping, skipping")
            continue

        old_info = get_video_info(base_url, token, old_pt_id)
        if old_info is None:
            print(f"{yt_id}: old video already gone, marking done")
            mark_done(yt_id)
            skipped += 1
            continue

        info = json.load(open(DOWNLOAD_DIR / f"{yt_id}.info.json"))
        title = info.get("title", yt_id)
        channel_id = old_info.get("channel", {}).get("id", 2)
        privacy = old_info.get("privacy", {}).get("id", 1)
        size_mb = file_path.stat().st_size // 1048576

        print(f"[{success + failed + skipped + 1}/{len(upgradable)}] "
              f"{yt_id}: '{title[:50]}' ({size_mb} MB)")

        # 1) Upload new video
        new_id = upload_via_curl(base_url, token, file_path, title, channel_id, privacy)
        if not new_id:
            print("  UPLOAD FAILED — old video preserved")
            failed += 1
            time.sleep(2)
            continue

        print(f"  Uploaded: {new_id}")

        # 2) Delete old video
        if delete_video(base_url, token, old_pt_id):
            print(f"  Deleted old: {old_pt_id}")
        else:
            print(f"  WARNING: could not delete old {old_pt_id}")

        # 3) Update mapping
        yt_map[yt_id] = new_id
        write_map(MAP_FILE, yt_map)

        # 4) Thumbnail (best-effort, non-fatal)
        if not upload_thumbnail(base_url, token, new_id, yt_id):
            print("  Thumbnail upload deferred (video still processing)")
            mark_thumb_fail(yt_id)

        mark_done(yt_id)
        success += 1
        print(f"  OK ({success} done)")
        time.sleep(1)

    print(f"\n=== {success} replaced, {failed} failed, {skipped} skipped ===")
    if THUMB_FAIL_FILE.exists():
        pending = [l.strip() for l in THUMB_FAIL_FILE.open() if l.strip()]
        if pending:
            print(f"\n{len(pending)} videos need thumbnail sync — "
                  "run: ./peertube-importer.sh --upload-only")


if __name__ == "__main__":
    main()
