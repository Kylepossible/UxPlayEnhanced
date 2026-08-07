"""Portable UxPlayEnhanced system-tray launcher.

The release contains a frozen UxPlayEnhanced.exe, so end users do not need
Python, pystray, or Pillow installed.  This source file is also useful when
running directly from a source checkout.
"""

import datetime
import os
import re
import socket
import subprocess
import sys
import threading

from PIL import Image, ImageDraw
import pystray


def application_dir():
    executable = sys.executable if getattr(sys, "frozen", False) else __file__
    return os.path.dirname(os.path.abspath(executable))


def resource_path(*parts):
    if getattr(sys, "frozen", False):
        base_dir = sys._MEIPASS
    else:
        base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base_dir, *parts)


SCRIPT_DIR = application_dir()
UXPLAY_EXE = os.path.join(SCRIPT_DIR, "uxplay.exe")
GST_PLUGIN_PATH = os.path.join(SCRIPT_DIR, "lib", "gstreamer-1.0")
USER_DATA_DIR = os.environ.get("UXPLAYENHANCED_DATA_DIR")
if not USER_DATA_DIR:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        USER_DATA_DIR = os.path.join(local_app_data, "UxPlayEnhanced")
    else:
        USER_DATA_DIR = os.path.join(os.path.expanduser("~"), "UxPlayEnhanced")
LOG_DIR = os.path.join(USER_DATA_DIR, "Logs")
LOG_PATH = os.path.join(LOG_DIR, "UxPlayEnhanced.log")
ICON_PATH = resource_path("assets", "UxPlayEnhanced-icon.png")
AIRPLAY_NAME = socket.gethostname()
VERBOSE_LOGGING = "--verbose" in sys.argv[1:]

UXPLAY_ARGS = [
    UXPLAY_EXE,
    "-n", AIRPLAY_NAME,
    "-nh",
    "-vs", "0",
]
if not VERBOSE_LOGGING:
    UXPLAY_ARGS.append("-no-progress")

process = None
log_file = None
state_lock = threading.Lock()
stop_monitor = threading.Event()


class UxPlayTrayIcon(pystray.Icon):
    """Keep dynamic menu updates from interrupting Windows hover tracking."""

    _WM_RBUTTONUP = 0x0205

    def __init__(self, *args, **kwargs):
        self.menu_open = False
        super().__init__(*args, **kwargs)

    def _on_notify(self, wparam, lparam):
        is_context_menu = lparam == self._WM_RBUTTONUP
        if is_context_menu:
            # Refresh before TrackPopupMenuEx starts. Rebuilding the native
            # HMENU while it is open breaks Windows' hover/highlight state.
            self.menu_open = True
            self.update_menu()
        try:
            return super()._on_notify(wparam, lparam)
        finally:
            if is_context_menu:
                self.menu_open = False


def create_icon_image():
    """Load the high-contrast UxPlayEnhanced application icon."""
    try:
        with Image.open(ICON_PATH) as source:
            return source.convert("RGBA")
    except OSError:
        # Keep a visible fallback if a developer runs the source without the
        # bundled asset.
        image = Image.new("RGBA", (64, 64), (4, 37, 91, 255))
        draw = ImageDraw.Draw(image)
        for x, height in ((18, 12), (25, 22), (32, 32), (39, 22), (46, 12)):
            draw.rounded_rectangle(
                (x - 2, 32 - height // 2, x + 2, 32 + height // 2),
                radius=2,
                fill=(0, 204, 255, 255),
            )
        return image


def read_log_tail():
    try:
        with open(LOG_PATH, "r", encoding="utf-8", errors="replace") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 131072), os.SEEK_SET)
            return stream.read()
    except OSError:
        return ""


def latest_line(text, marker):
    matches = [line.strip() for line in text.splitlines() if marker in line]
    return matches[-1] if matches else ""


def metadata_value(text, field):
    """Return the last exact metadata field, ignoring similar fields."""
    pattern = re.compile(r"^" + re.escape(field) + r":\s*(.*)$", re.IGNORECASE)
    values = []
    for line in text.splitlines():
        match = pattern.match(line.strip())
        if match and match.group(1).strip():
            values.append(match.group(1).strip())
    return values[-1] if values else ""


def current_song(text):
    title = metadata_value(text, "Title")
    artist = metadata_value(text, "Artist")
    album = metadata_value(text, "Album")
    if title and artist:
        song = f"{artist} - {title}"
    else:
        song = title or artist or "No song metadata yet"
    if album:
        song = f"{song} [{album}]"
    return song[:110]


def current_client(text):
    pattern = re.compile(
        r"connection request from\s+(.+?)\s+\(([^)]+)\)\s+with deviceID",
        re.IGNORECASE,
    )
    matches = pattern.findall(text)
    if not matches:
        return "Waiting for connection"
    name, model = matches[-1]
    return f"{name.strip()} ({model.strip()})"[:110]


def host_text(item=None):
    return f"AirPlay Host: {AIRPLAY_NAME}"


def client_text(item=None):
    return "AirPlay Client: " + current_client(read_log_tail())


def status_text(item=None):
    with state_lock:
        running = process is not None and process.poll() is None
    if not running:
        return "Status: Stopped"

    text = read_log_tail()
    if "audio error" in text.lower():
        return "Status: Audio error (view logs)"
    if "start audio connection" in text or "changed audio connection" in text:
        return "Status: Audio connected"
    return "Status: Waiting for AirPlay audio"


def song_text(item=None):
    return "Song: " + current_song(read_log_tail())


def quality_text(item=None):
    line = latest_line(read_log_tail(), "audio quality:")
    if not line:
        return "Codec: Waiting for audio"

    match = re.search(
        r"codec=([^;\s]+)(?:\s+\([^)]*\))?;\s*"
        r"quality=([^;]+);\s*resolution=(\d+)-bit/(\d+)\s*Hz;\s*"
        r"channels=(\d+)",
        line,
        re.IGNORECASE,
    )
    if not match:
        return "Codec: Audio format available in logs"

    codec, quality, bit_depth, sample_rate, channels = match.groups()
    sample_rate_khz = int(sample_rate) / 1000
    sample_rate_text = f"{sample_rate_khz:g} kHz"
    return (
        f"Codec: {codec} | Quality: {quality.strip()} | "
        f"Bit/Sample Rate: {bit_depth}-bit / {sample_rate_text} | "
        f"Channels: {channels}"
    )[:160]


def start_uxplay():
    """Start UxPlay hidden and append its console output to the log."""
    global process, log_file

    stop_uxplay()
    os.makedirs(LOG_DIR, exist_ok=True)
    log_file = open(LOG_PATH, "a", encoding="utf-8", errors="replace", buffering=1)
    log_file.write(
        "\n=== UxPlayEnhanced tray session "
        + datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        + " ===\n"
    )

    env = os.environ.copy()
    env["GST_PLUGIN_PATH"] = GST_PLUGIN_PATH
    env["PATH"] = SCRIPT_DIR + os.pathsep + env.get("PATH", "")

    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = 0

    with state_lock:
        process = subprocess.Popen(
            UXPLAY_ARGS,
            cwd=SCRIPT_DIR,
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            startupinfo=startupinfo,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )


def stop_uxplay():
    """Stop UxPlay and close the log handle."""
    global process, log_file

    with state_lock:
        current_process = process
        process = None

    if current_process and current_process.poll() is None:
        current_process.terminate()
        try:
            current_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            current_process.kill()
            current_process.wait(timeout=5)

    if log_file:
        log_file.close()
        log_file = None


def on_quit(icon, item):
    stop_monitor.set()
    stop_uxplay()
    icon.stop()


def on_restart(icon, item):
    start_uxplay()
    icon.notify("UxPlay restarted", "UxPlayEnhanced")
    icon.update_menu()


def on_view_logs(icon, item):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        if log_file:
            log_file.flush()
        if not os.path.exists(LOG_PATH):
            with open(LOG_PATH, "a", encoding="utf-8"):
                pass
        # Opening through Notepad is deterministic even when Windows has no
        # file association registered for the .log extension.
        subprocess.Popen(["notepad.exe", LOG_PATH])
    except OSError as error:
        icon.notify(f"Could not open the log: {error}", "UxPlayEnhanced")


def on_open_folder(icon, item):
    os.startfile(SCRIPT_DIR)


def refresh_menu(icon):
    while not stop_monitor.wait(1):
        try:
            if not icon.menu_open:
                icon.update_menu()
        except Exception:
            return


def setup(icon):
    icon.visible = True
    start_uxplay()
    threading.Thread(target=refresh_menu, args=(icon,), daemon=True).start()


def main():
    icon = UxPlayTrayIcon(
        "UxPlayEnhanced",
        create_icon_image(),
        f"UxPlayEnhanced Audio Receiver ({AIRPLAY_NAME})",
        menu=pystray.Menu(
            pystray.MenuItem(host_text, None, enabled=False),
            pystray.MenuItem(client_text, None, enabled=False),
            pystray.MenuItem(status_text, None, enabled=False),
            pystray.MenuItem(song_text, None, enabled=False),
            pystray.MenuItem(quality_text, None, enabled=False),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("View logs", on_view_logs),
            pystray.MenuItem("Open folder", on_open_folder),
            pystray.MenuItem("Restart", on_restart),
            pystray.MenuItem("Quit", on_quit),
        ),
    )
    icon.run(setup)


if __name__ == "__main__":
    main()
