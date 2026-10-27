#!/usr/bin/env bash
# ==============================================================================
# Turnkey Installer: Android Clipboard & Screenshot Sync for AVF Debian
# ==============================================================================
# This script sets up automatic syncing of Android screenshots and dropped media
# into Debian's Wayland and X11 clipboards (wl-clipboard & xclip) via VirtioFS,
# enabling immediate Ctrl+V media pasting inside Antigravity (agy).
#
# Survives VM resets if run from /mnt/shared/Download/install-android-clip.sh.
# Usage:
#   bash install-android-clip.sh           # Full turnkey install
#   bash install-android-clip.sh --check   # Check status / dry-run
#   bash install-android-clip.sh --uninstall # Cleanly remove
# ==============================================================================

set -euo pipefail

DEST_BIN="$HOME/.local/bin/android-clip-sync"
DEST_SERVICE="$HOME/.config/systemd/user/android-clip-sync.service"
BASHRC="$HOME/.bashrc"

# Check mode
if [[ "${1:-}" == "--check" || "${1:-}" == "--dry-run" ]]; then
    echo "=== Android Clip Sync Status Check ==="
    echo -n "VirtioFS (/mnt/shared): "
    if [ -d "/mnt/shared/Pictures/Screenshots" ]; then
        echo "OK (found /mnt/shared/Pictures/Screenshots)"
    else
        echo "MISSING or not mounted"
    fi

    for pkg in xclip wl-copy inotifywait python3; do
        echo -n "Binary $pkg: "
        if command -v "$pkg" >/dev/null 2>&1; then
            echo "OK ($(command -v "$pkg"))"
        else
            echo "MISSING"
        fi
    done

    echo -n "Systemd User Service: "
    if systemctl --user is-active android-clip-sync.service >/dev/null 2>&1; then
        echo "ACTIVE & RUNNING"
    else
        echo "INACTIVE or NOT INSTALLED"
    fi
    exit 0
fi

# Uninstall mode
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "==> Uninstalling Android Clip Sync..."
    systemctl --user stop android-clip-sync.service 2>/dev/null || true
    systemctl --user disable android-clip-sync.service 2>/dev/null || true
    rm -f "$DEST_SERVICE"
    systemctl --user daemon-reload 2>/dev/null || true
    rm -f "$DEST_BIN" "$HOME/.local/bin/clip-media" "$HOME/.local/bin/clip-sync" "$HOME/.local/bin/clip-latest"
    echo "==> Successfully uninstalled."
    exit 0
fi

echo "=========================================================="
echo " Installing Android Clipboard Sync for AVF Debian         "
echo "=========================================================="

# 1. Install dependencies
echo "==> [1/5] Checking Debian package dependencies..."
MISSING_PKGS=()
for bin in xclip wl-copy inotifywait python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        case "$bin" in
            xclip) MISSING_PKGS+=("xclip") ;;
            wl-copy) MISSING_PKGS+=("wl-clipboard") ;;
            inotifywait) MISSING_PKGS+=("inotify-tools") ;;
            python3) MISSING_PKGS+=("python3") ;;
        esac
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${MISSING_PKGS[@]}"
else
    echo "All dependencies (xclip, wl-clipboard, inotify-tools, python3) are installed."
fi

# 2. Check VirtioFS
echo "==> [2/5] Checking VirtioFS mount (/mnt/shared)..."
if [ ! -d "/mnt/shared" ]; then
    echo "[-] Warning: /mnt/shared is not yet mounted."
    echo "    Make sure shared storage is enabled in your Android Virtual Machine settings."
else
    mkdir -p /mnt/shared/Pictures/Screenshots /mnt/shared/Download /mnt/shared/.clipboard_drop 2>/dev/null || true
    echo "VirtioFS shared storage confirmed."
fi

# 3. Deploy Python Daemon
echo "==> [3/5] Installing daemon to $DEST_BIN..."
mkdir -p "$HOME/.local/bin"

cat << 'PYTHON_EOF' > "$DEST_BIN"
#!/usr/bin/env python3
"""
Android Screenshot & Media Clipboard Sync for AVF Debian
=========================================================
Automatically syncs Android screenshots and dropped media into wl-clipboard
and xclip via VirtioFS (/mnt/shared), enabling Ctrl+V media pasting in Antigravity (agy).

How it works:
-------------
1. VirtioFS (/mnt/shared):
   Android host storage (/sdcard) is mounted at /mnt/shared. When a screenshot is taken
   on Android, it is instantly written to /mnt/shared/Pictures/Screenshots/.

2. Why -loops 0 -i for xclip?
   In AVF ttyd/terminal sessions, agy runs under DISPLAY=:0 (Xwayland) without WAYLAND_DISPLAY.
   When Ctrl+V is pressed, agy executes two requests sequentially:
     - xclip -selection clipboard -t TARGETS -o   (inspect formats)
     - xclip -selection clipboard -t image/png -o  (fetch payload)
   Default xclip exits after 1 request (-loops 1), killing the daemon before agy reads the image,
   causing "Paste failed: exit status 1". Using `-loops 0 -i` keeps xclip alive to serve
   both requests and repeated pastes.
"""

import os
import sys
import time
import mimetypes
import subprocess
from pathlib import Path

WATCH_DIRS = [
    Path("/mnt/shared/Pictures/Screenshots"),
    Path("/mnt/shared/.clipboard_drop"),
    Path("/mnt/shared/Download"),
]

MEDIA_EXTS = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".txt": "text/plain",
}

ENV = os.environ.copy()
ENV["WAYLAND_DISPLAY"] = ENV.get("WAYLAND_DISPLAY", "wayland-0")
ENV["XDG_RUNTIME_DIR"] = ENV.get("XDG_RUNTIME_DIR", "/run/user/1000")
ENV["DISPLAY"] = ENV.get("DISPLAY", ":0")

CACHE_FILE = Path("/home/droid/.cache/last_clip_media")


def get_mime(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in MEDIA_EXTS:
        return MEDIA_EXTS[ext]
    guess, _ = mimetypes.guess_type(path.name)
    return guess or "application/octet-stream"


def copy_file_to_clipboard(path: Path, use_xclip: bool = True) -> bool:
    if not path.is_file():
        return False

    mime = get_mime(path)

    # Wait until file finishes writing (size stable and > 0)
    prev_size = -1
    for _ in range(12):
        try:
            curr_size = path.stat().st_size
            if curr_size > 0 and curr_size == prev_size:
                break
            prev_size = curr_size
            time.sleep(0.04)
        except OSError:
            time.sleep(0.04)

    try:
        with open(path, "rb") as f:
            data = f.read()

        # 1. Wayland wl-copy (if Wayland is available)
        try:
            p = subprocess.Popen(
                ["wl-copy", "-t", mime],
                stdin=subprocess.PIPE,
                env=ENV,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            p.communicate(input=data)
        except Exception:
            pass

        # 2. X11 xclip with -loops 0 daemon (for Xwayland / X11 apps like agy in ttyd)
        try:
            subprocess.run(["pkill", "-f", "xclip.*clipboard"], stderr=subprocess.DEVNULL)
            p2 = subprocess.Popen(
                ["xclip", "-selection", "clipboard", "-t", mime, "-loops", "0", "-i"],
                stdin=subprocess.PIPE,
                env=ENV,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            p2.stdin.write(data)
            p2.stdin.close()
        except Exception as e:
            print(f"[!] xclip error: {e}", file=sys.stderr)

        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(str(path))

        size_kb = len(data) / 1024
        print(f"[✓] Synced to clipboard: {path.name} ({mime}, {size_kb:.1f} KB)", flush=True)
        return True
    except Exception as e:
        print(f"[!] Error copying {path}: {e}", file=sys.stderr, flush=True)
        return False


def find_latest_media():
    candidates = []
    for d in WATCH_DIRS:
        if not d.exists():
            continue
        try:
            for entry in os.scandir(d):
                if entry.is_file():
                    ext = Path(entry.name).suffix.lower()
                    if ext in MEDIA_EXTS:
                        try:
                            candidates.append((entry.stat().st_mtime, Path(entry.path)))
                        except OSError:
                            pass
        except OSError:
            pass
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


def run_daemon(use_xclip: bool = True):
    print(f"[android-clip-sync] Started low-latency watcher (polling interval: 100ms)", flush=True)
    for d in WATCH_DIRS:
        print(f"  Watching: {d}", flush=True)

    dir_mtimes = {}
    known_latest_files = {}

    for d in WATCH_DIRS:
        if d.exists():
            try:
                dir_mtimes[d] = d.stat().st_mtime
            except OSError:
                dir_mtimes[d] = 0

    latest = find_latest_media()
    if latest:
        print(f"[android-clip-sync] Initial baseline: {latest.name}", flush=True)
        try:
            known_latest_files[latest.parent] = (latest.name, latest.stat().st_mtime)
        except OSError:
            pass

    POLL_INTERVAL = 0.10  # 100ms for sub-second reaction

    while True:
        try:
            for d in WATCH_DIRS:
                if not d.exists():
                    continue
                try:
                    curr_mtime = d.stat().st_mtime
                except OSError:
                    continue

                if curr_mtime != dir_mtimes.get(d):
                    dir_mtimes[d] = curr_mtime

                    newest_file = None
                    newest_mtime = -1

                    try:
                        for e in os.scandir(d):
                            if e.is_file():
                                ext = Path(e.name).suffix.lower()
                                if ext in MEDIA_EXTS:
                                    try:
                                        m = e.stat().st_mtime
                                        if m > newest_mtime:
                                            newest_mtime = m
                                            newest_file = Path(e.path)
                                    except OSError:
                                        pass
                    except OSError:
                        pass

                    if newest_file:
                        last_known = known_latest_files.get(d)
                        if not last_known or (newest_file.name != last_known[0] or newest_mtime > last_known[1]):
                            known_latest_files[d] = (newest_file.name, newest_mtime)
                            copy_file_to_clipboard(newest_file, use_xclip=use_xclip)

            time.sleep(POLL_INTERVAL)
        except KeyboardInterrupt:
            print("\n[android-clip-sync] Stopped.")
            break
        except Exception:
            time.sleep(1)


def main():
    use_xclip = "--no-xclip" not in sys.argv
    args = [a for a in sys.argv[1:] if a not in ("--xclip", "--no-xclip")]

    if args:
        cmd = args[0]
        if cmd in ("watch", "--daemon", "-d"):
            run_daemon(use_xclip=use_xclip)
            return
        elif cmd in ("--help", "-h"):
            print("Usage: android-clip-sync [watch | latest | /path/to/media] [--no-xclip]")
            return
        elif cmd not in ("latest", "--latest"):
            target = Path(cmd)
            if target.is_file():
                copy_file_to_clipboard(target, use_xclip=use_xclip)
                return
            else:
                print(f"File not found: {target}", file=sys.stderr)
                sys.exit(1)

    latest = find_latest_media()
    if latest:
        copy_file_to_clipboard(latest, use_xclip=use_xclip)
    else:
        print("No recent media found in watched directories.")


if __name__ == "__main__":
    main()
PYTHON_EOF

chmod +x "$DEST_BIN"
ln -sf "$DEST_BIN" "$HOME/.local/bin/clip-media"
ln -sf "$DEST_BIN" "$HOME/.local/bin/clip-sync"
ln -sf "$DEST_BIN" "$HOME/.local/bin/clip-latest"

# 4. Configure systemd user service
echo "==> [4/5] Setting up systemd user service..."
mkdir -p "$HOME/.config/systemd/user"

cat << 'SERVICE_EOF' > "$DEST_SERVICE"
[Unit]
Description=Android Screenshot & Media Clipboard Sync for AVF Debian
After=default.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 %h/.local/bin/android-clip-sync watch
Restart=always
RestartSec=2
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/1000

[Install]
WantedBy=default.target
SERVICE_EOF

systemctl --user daemon-reload
systemctl --user enable --now android-clip-sync.service

# 5. Ensure shell environment
echo "==> [5/5] Updating shell environment in ~/.bashrc..."
for var in \
    'export WAYLAND_DISPLAY="wayland-0"' \
    'export DISPLAY=":0"' \
    'export XDG_RUNTIME_DIR="/run/user/1000"' \
    'alias clip-latest="android-clip-sync latest"' \
    'alias clip-paste="wl-paste"'; do
    if ! grep -qF "$var" "$BASHRC" 2>/dev/null; then
        echo "$var" >> "$BASHRC"
    fi
done

echo ""
echo "=========================================================="
echo " [SUCCESS] Android Clipboard Sync is fully installed!    "
echo "=========================================================="
echo " - Daemon is running in background (systemd user unit)."
echo " - Tested with VirtioFS at /mnt/shared/Pictures/Screenshots."
echo " - To test: Take a screenshot on Android, then press Ctrl+V"
echo "   inside Antigravity (agy) to attach it directly!"
echo "=========================================================="
