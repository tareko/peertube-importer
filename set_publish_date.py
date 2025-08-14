#!/usr/bin/env python3
"""Set PeerTube publication dates through the HTTP API.

Reads ``uploaded-map.txt`` for mappings between YouTube IDs and PeerTube video
IDs, looks up the original YouTube upload dates from
``yt_downloads/<youtube_id>.info.json`` and updates the ``originallyPublishedAt`` field
of each video via the PeerTube REST API. If present, variables defined in a
local ``.env`` file are loaded before falling back to the environment.
"""

from __future__ import annotations

import json
import os
import pathlib
from datetime import datetime, timezone

import urllib.parse
import urllib.request

DOWNLOAD_DIR = pathlib.Path("./yt_downloads")
MAP_FILE = pathlib.Path("./uploaded-map.txt")


def load_env(path: str = ".env") -> None:
    """Load simple KEY=VALUE lines from a .env file into os.environ."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    os.environ.setdefault(key.strip(), val.strip().strip("'\""))
    except FileNotFoundError:
        pass


def read_upload_date(yt_id: str) -> datetime | None:
    """Return the upload date from the video's info JSON, if available."""
    info_path = DOWNLOAD_DIR / f"{yt_id}.info.json"
    if not info_path.exists():
        return None
    try:
        with info_path.open() as f:
            data = json.load(f)
    except Exception:
        return None
    date_str = data.get("upload_date")
    if not date_str:
        return None
    try:
        dt = datetime.strptime(date_str, "%Y%m%d").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return dt


def get_token(url: str, user: str, password: str) -> str | None:
    """Return an access token for the PeerTube API."""
    if not user or not password:
        return None

    try:
        with urllib.request.urlopen(f"{url}/api/v1/oauth-clients/local") as resp:
            client = json.load(resp)
        client_id = client.get("client_id")
        client_secret = client.get("client_secret")
    except Exception:
        return None

    data = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "password",
            "response_type": "code",
            "username": user,
            "password": password,
        }
    ).encode()
    req = urllib.request.Request(f"{url}/api/v1/users/token", data=data)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp).get("access_token")
    except Exception:
        return None


def get_video_info(url: str, vid: str, token: str | None) -> dict | None:
    """Fetch video information from the PeerTube API."""
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{url}/api/v1/videos/{vid}", headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except Exception:
        return None


def update_publish_date(
    url: str, vid: str, token: str | None, dt: datetime
) -> tuple[bool, str | None]:
    """Update the video's publication date via the API.

    Returns ``(success, error_message)``; ``error_message`` is ``None`` on
    success and otherwise contains details about the failure.
    """
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    payload = json.dumps(
        {"originallyPublishedAt": dt.isoformat().replace("+00:00", "Z")}
    ).encode()
    req = urllib.request.Request(
        f"{url}/api/v1/videos/{vid}", data=payload, headers=headers, method="PUT"
    )
    try:
        with urllib.request.urlopen(req):
            return True, None
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", errors="ignore")
        except Exception:
            pass
        detail = f"HTTP {e.code} {e.reason}"
        if body:
            detail += f": {body.strip()}"
        return False, detail
    except Exception as e:
        return False, str(e)

def main() -> None:
    load_env()
    pt_url = os.getenv("PEERTUBE_URL", "")
    pt_user = os.getenv("PEERTUBE_USER", "")
    pt_pass = os.getenv("PEERTUBE_PASS", "")
    token = get_token(pt_url, pt_user, pt_pass) if pt_url else None

    with MAP_FILE.open() as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) != 2:
                continue
            yt_id, pt_id = parts
            dt = read_upload_date(yt_id)
            if not dt:
                continue

            info = get_video_info(pt_url, pt_id, token)
            if not info:
                print(f"No video matched ID {pt_id}")
                continue
            current = info.get("originallyPublishedAt") or info.get("originally_published_at")
            if current:
                try:
                    current_dt = datetime.fromisoformat(current.replace("Z", "+00:00"))
                except ValueError:
                    current_dt = None
                if current_dt and current_dt == dt:
                    print(f"Video {pt_id} already set to {dt.isoformat()}, skipping")
                    continue

            print(f"Updating video {pt_id} to {dt.isoformat()}")
            success, error = update_publish_date(pt_url, pt_id, token, dt)
            if not success:
                print(f"Failed to update video {pt_id}: {error}")

    print("Publication dates updated.")


if __name__ == "__main__":
    main()
