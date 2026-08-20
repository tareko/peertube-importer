#!/usr/bin/env python3
"""Upload all unmapped downloaded videos to PeerTube using the fast legacy API."""
import json, os, subprocess, sys, time

def load_env():
    env = {}
    for line in open('.env'):
        line = line.strip()
        if not line or line.startswith('#'): continue
        if '=' in line:
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip("'\"")
    return env

def main():
    env = load_env()
    base_url = env['PEERTUBE_URL'].rstrip('/')

    # Get token
    import urllib.request, urllib.parse
    creds = json.load(urllib.request.urlopen(f"{base_url}/api/v1/oauth-clients/local"))
    data = urllib.parse.urlencode({
        'client_id': creds['client_id'], 'client_secret': creds['client_secret'],
        'grant_type': 'password', 'username': env['PEERTUBE_USER'],
        'password': env['PEERTUBE_PASS'],
    }).encode()
    req = urllib.request.Request(f"{base_url}/api/v1/users/token", data=data)
    token = json.load(urllib.request.urlopen(req))['access_token']

    # Get channel ID from an existing video
    first_map_line = open('uploaded-map.txt').readline().strip().split()
    existing_id = first_map_line[1] if len(first_map_line) > 1 else None
    req2 = urllib.request.Request(
        f"{base_url}/api/v1/videos/{existing_id}",
        headers={'Authorization': f'Bearer {token}'})
    channel_id = json.load(urllib.request.urlopen(req2))['channel']['id']
    print(f"Channel ID: {channel_id}")

    # Find unmapped videos
    archived = set()
    for line in open('yt-dlp-archive.txt'):
        parts = line.strip().split()
        if len(parts) == 2 and parts[0] == 'youtube':
            archived.add(parts[1])
    mapped = set()
    for line in open('uploaded-map.txt'):
        parts = line.strip().split()
        if len(parts) == 2:
            mapped.add(parts[0])
    unmapped = sorted(archived - mapped)
    print(f"Uploading {len(unmapped)} new videos...\n")

    success = failed = 0
    for yt_id in unmapped:
        vfile = None
        for ext in ('mkv', 'webm', 'mp4'):
            f = f'yt_downloads/{yt_id}.{ext}'
            if os.path.exists(f):
                vfile = f; break
        if not vfile:
            print(f"  {yt_id}: NO FILE, skipping"); failed += 1; continue

        info = json.load(open(f'yt_downloads/{yt_id}.info.json'))
        title = info.get('title', yt_id)
        size_mb = os.path.getsize(vfile) // 1048576
        print(f"[{success+failed+1}/{len(unmapped)}] {yt_id}: '{title[:50]}' ({size_mb} MB)")

        result = subprocess.run([
            'curl', '-s', '--max-time', '600',
            f'{base_url}/api/v1/videos/upload',
            '-H', f'Authorization: Bearer {token}',
            '--form', f'videofile=@{os.path.abspath(vfile)}',
            '--form', f'channelId={channel_id}',
            '--form', f'name={title}',
            '--form', 'privacy=1',
            '--form', f'filename={os.path.basename(vfile)}',
        ], capture_output=True, text=True, timeout=600)

        try:
            resp = json.loads(result.stdout)
            pt_id = resp.get('video', {}).get('uuid')
            if pt_id:
                print(f"  -> {pt_id}")
                with open('uploaded-map.txt', 'a') as f:
                    f.write(f'{yt_id} {pt_id}\n')
                with open('uploaded.txt', 'a') as f:
                    f.write(f'{yt_id}\n')
                # Thumbnail (best-effort)
                for t_ext in ('png', 'jpg', 'jpeg'):
                    thumb = f'yt_downloads/{yt_id}.{t_ext}'
                    if os.path.exists(thumb):
                        subprocess.run([
                            'curl', '-s', '-o', '/dev/null', '--max-time', '30',
                            '-X', 'PUT', f'{base_url}/api/v1/videos/{pt_id}',
                            '-H', f'Authorization: Bearer {token}',
                            '-F', f'thumbnailfile=@{thumb};type=image/png',
                            '-F', f'previewfile=@{thumb};type=image/png',
                        ], timeout=60)
                        break
                success += 1
            else:
                print(f"  FAILED: {result.stdout[:200]}"); failed += 1
        except json.JSONDecodeError:
            print(f"  FAILED: {result.stdout[:200]}"); failed += 1
        time.sleep(1)

    print(f"\n=== {success} uploaded, {failed} failed ===")

if __name__ == '__main__':
    main()
