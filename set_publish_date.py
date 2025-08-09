#!/usr/bin/env python3
"""Set PeerTube publication dates directly via PostgreSQL.

Reads `uploaded-map.txt` for mappings between YouTube IDs and PeerTube video
IDs, looks up the original YouTube upload dates from
`yt_downloads/<youtube_id>.info.json`, and updates the `published_at` column in
the PeerTube `video` table accordingly. Connection parameters are taken from the
standard PostgreSQL environment variables (`PGHOST`, `PGPORT`, `PGDATABASE`,
`PGUSER`, `PGPASSWORD`). If present, variables defined in a local `.env` file
are loaded before falling back to the environment.
"""

from __future__ import annotations

import json
import os
import pathlib
from datetime import datetime, timezone

import psycopg2

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


def main() -> None:
    load_env()
    conn = psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "peertube"),
        user=os.getenv("PGUSER"),
        password=os.getenv("PGPASSWORD"),
    )
    with conn, conn.cursor() as cur:
        with MAP_FILE.open() as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) != 2:
                    continue
                yt_id, pt_id = parts
                dt = read_upload_date(yt_id)
                if not dt:
                    continue
                cur.execute(
                    "UPDATE video SET published_at = %s WHERE uuid::text = %s OR short_uuid = %s OR id::text = %s",
                    (dt, pt_id, pt_id, pt_id),
                )
    print("Publication dates updated.")


if __name__ == "__main__":
    main()
