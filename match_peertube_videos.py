#!/usr/bin/env python3
"""Match existing PeerTube videos to downloaded YouTube files.

The script reads video metadata from `yt_downloads/*.info.json` and fetches all
videos from the configured PeerTube instance. It then attempts to match
PeerTube titles to YouTube titles and appends any successful mappings to
`uploaded-map.txt` as `<youtube_id> <peertube_id>`.
"""

import difflib
import json
import pathlib
import urllib.parse
import urllib.request

DOWNLOAD_DIR = pathlib.Path("./yt_downloads")
MAP_FILE = pathlib.Path("./uploaded-map.txt")


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


def build_title_map(download_dir: pathlib.Path) -> dict:
    title_map = {}
    for info in download_dir.glob("*.info.json"):
        yt_id = info.stem
        try:
            with info.open() as f:
                data = json.load(f)
        except Exception:
            continue
        title = data.get("title")
        if not title:
            continue
        key = title.lower()
        title_map.setdefault(key, []).append(yt_id)
    return title_map


def get_token(url: str, user: str, password: str) -> str | None:
    if not user or not password:
        return None
    data = urllib.parse.urlencode({
        "client_id": "peertube-cli",
        "grant_type": "password",
        "username": user,
        "password": password,
    }).encode()
    req = urllib.request.Request(f"{url}/api/v1/users/token", data=data)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp).get("access_token")
    except Exception:
        return None


def fetch_peertube_videos(url: str, token: str | None = None) -> list:
    videos = []
    start = 0
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    while True:
        req = urllib.request.Request(
            f"{url}/api/v1/videos?start={start}&count=100", headers=headers
        )
        with urllib.request.urlopen(req) as resp:
            data = json.load(resp)
        items = data.get("data") or []
        if not items:
            break
        videos.extend(items)
        start += len(items)
    return videos


def read_existing_map(path: pathlib.Path) -> dict:
    existing = {}
    if path.exists():
        with path.open() as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2:
                    existing[parts[0]] = parts[1]
    return existing


def match_title(title: str, title_map: dict) -> str | None:
    key = title.lower()
    if key in title_map:
        return title_map[key][0]
    matches = difflib.get_close_matches(key, title_map.keys(), n=1, cutoff=0.9)
    if matches:
        return title_map[matches[0]][0]
    return None


def main() -> None:
    env = load_env()
    pt_url = env.get("PEERTUBE_URL", "")
    pt_user = env.get("PEERTUBE_USER", "")
    pt_pass = env.get("PEERTUBE_PASS", "")

    title_map = build_title_map(DOWNLOAD_DIR)
    existing_map = read_existing_map(MAP_FILE)
    token = get_token(pt_url, pt_user, pt_pass) if pt_url else None
    videos = fetch_peertube_videos(pt_url, token) if pt_url else []

    with MAP_FILE.open("a") as out:
        for vid in videos:
            pt_id = vid.get("uuid") or vid.get("shortUUID") or str(vid.get("id"))
            yt_id = match_title(vid.get("name", ""), title_map)
            if not pt_id or not yt_id or yt_id in existing_map:
                continue
            out.write(f"{yt_id} {pt_id}\n")
            existing_map[yt_id] = pt_id
            print(f"Mapped {yt_id} -> {pt_id}")


if __name__ == "__main__":
    main()
