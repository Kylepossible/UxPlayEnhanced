"""Portable UxPlayEnhanced system-tray launcher.

The release contains a frozen UxPlayEnhanced.exe, so end users do not need
Python, pystray, or Pillow installed.  This source file is also useful when
running directly from a source checkout.
"""

import datetime
import ctypes
from ctypes import wintypes
import logging
import logging.handlers
import os
import re
import socket
import subprocess
import sys
import threading
import uuid

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
LOG_MAX_BYTES = 5 * 1024 * 1024
LOG_BACKUP_COUNT = 2
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
reader_thread = None
shutdown_signal = None
state_lock = threading.Lock()
stop_monitor = threading.Event()


class SingleInstance:
    """Hold a Windows session mutex across all installed/portable copies."""

    def __init__(self, name=r"Local\UxPlayEnhanced.AudioReceiver"):
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
        self.kernel32.CreateMutexW.restype = wintypes.HANDLE
        self.kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel32.CloseHandle.restype = wintypes.BOOL
        self.handle = self.kernel32.CreateMutexW(None, False, name)
        error = ctypes.get_last_error()
        if not self.handle:
            raise ctypes.WinError(error)
        self.acquired = error != 183  # ERROR_ALREADY_EXISTS
        if not self.acquired:
            self.close()

    def close(self):
        if self.handle:
            self.kernel32.CloseHandle(self.handle)
            self.handle = None


class ShutdownSignal:
    """Ask the hidden receiver to run its normal AirPlay/mDNS cleanup."""

    def __init__(self):
        self.name = "Local\\UxPlayEnhanced.Stop." + uuid.uuid4().hex
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel32.CreateEventW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
        self.kernel32.CreateEventW.restype = wintypes.HANDLE
        self.kernel32.SetEvent.argtypes = [wintypes.HANDLE]
        self.kernel32.SetEvent.restype = wintypes.BOOL
        self.kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel32.CloseHandle.restype = wintypes.BOOL
        self.handle = self.kernel32.CreateEventW(None, True, False, self.name)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())

    def request(self):
        if not self.kernel32.SetEvent(self.handle):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            self.kernel32.CloseHandle(self.handle)
            self.handle = None


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


# ---------------------------------------------------------------------------
# Log capture
#
# UxPlay's console output is piped into this process instead of straight into
# the log file. Owning the file handle is what lets the log be rotated while a
# session is running, and it lets each line be parsed once on arrival rather
# than re-reading and re-parsing the tail of the file for every menu redraw.
# ---------------------------------------------------------------------------

log_writer = None


def create_log_writer():
    os.makedirs(LOG_DIR, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        LOG_PATH,
        maxBytes=LOG_MAX_BYTES,
        backupCount=LOG_BACKUP_COUNT,
        encoding="utf-8",
        errors="replace",
        delay=True,
    )
    handler.setFormatter(logging.Formatter("%(message)s"))
    writer = logging.getLogger("uxplayenhanced.session")
    writer.propagate = False
    writer.setLevel(logging.INFO)
    for existing in list(writer.handlers):
        writer.removeHandler(existing)
        existing.close()
    writer.addHandler(handler)
    return writer


CLIENT_PATTERN = re.compile(
    r"connection request from\s+(.+?)\s+\(([^)]+)\)\s+with deviceID",
    re.IGNORECASE,
)
QUALITY_PATTERN = re.compile(
    r"codec=([^;\s]+)(?:\s+\([^)]*\))?;\s*"
    r"quality=([^;]+);\s*resolution=(\d+)-bit/(\d+)\s*Hz;\s*"
    r"channels=(\d+)",
    re.IGNORECASE,
)
METADATA_PATTERN = re.compile(r"^(Title|Artist|Album):\s*(.*)$", re.IGNORECASE)


def new_state():
    return {
        "client": "",
        "title": "",
        "artist": "",
        "album": "",
        "quality": "",
        "audio_connected": False,
        "audio_error": False,
    }


def format_quality(line):
    match = QUALITY_PATTERN.search(line)
    if not match:
        return "Codec: Audio format available in logs"

    codec, quality, bit_depth, sample_rate, channels = match.groups()
    sample_rate_khz = int(sample_rate) / 1000
    return (
        f"Codec: {codec} | Quality: {quality.strip()} | "
        f"Bit/Sample Rate: {bit_depth}-bit / {sample_rate_khz:g} kHz | "
        f"Channels: {channels}"
    )[:160]


def apply_log_line(state, line):
    """Fold one line of UxPlay output into the tray's view of the session."""
    event = line.strip()
    if event == "audio session ended":
        state.update(new_state())
        return state
    if event == "audio session started":
        client = state["client"]
        state.update(new_state())
        state["client"] = client
        state["audio_connected"] = True
    if event.startswith("====") and "Audio Metadata" in event:
        for field in ("title", "artist", "album"):
            state[field] = ""
    match = CLIENT_PATTERN.search(line)
    if match:
        state["client"] = f"{match.group(1).strip()} ({match.group(2).strip()})"[:110]

    if "audio error" in line.lower():
        state["audio_error"] = True

    if "start audio connection" in line or "changed audio connection" in line:
        state["audio_connected"] = True
        # A fresh connection supersedes an error from the previous one.
        state["audio_error"] = False

    if "audio quality:" in line:
        state["quality"] = format_quality(line)

    match = METADATA_PATTERN.match(line.strip())
    if match:
        state[match.group(1).lower()] = match.group(2).strip()

    return state


session_state = new_state()


def read_state():
    with state_lock:
        return dict(session_state)


def handle_output_line(line):
    if log_writer is not None:
        log_writer.info(line)
    with state_lock:
        apply_log_line(session_state, line)


def pump_output(stream, on_line):
    """Forward UxPlay's output line by line until the process exits."""
    try:
        for line in stream:
            on_line(line.rstrip("\r\n"))
    except (OSError, ValueError):
        pass
    finally:
        try:
            stream.close()
        except (OSError, ValueError):
            pass


def current_song(state):
    title = state["title"]
    artist = state["artist"]
    album = state["album"]
    if title and artist:
        song = f"{artist} - {title}"
    else:
        song = title or artist or "No song metadata yet"
    if album:
        song = f"{song} [{album}]"
    return song[:110]


def host_text(item=None):
    return f"AirPlay Host: {AIRPLAY_NAME}"


def client_text(item=None):
    return "AirPlay Client: " + (read_state()["client"] or "Waiting for connection")


def status_text(item=None):
    with state_lock:
        running = process is not None and process.poll() is None
        audio_error = session_state["audio_error"]
        audio_connected = session_state["audio_connected"]

    if not running:
        return "Status: Stopped"
    if audio_error:
        return "Status: Audio error (view logs)"
    if audio_connected:
        return "Status: Audio connected"
    return "Status: Waiting for AirPlay audio"


def song_text(item=None):
    return "Song: " + current_song(read_state())


def quality_text(item=None):
    return read_state()["quality"] or "Codec: Waiting for audio"


def start_uxplay():
    """Start UxPlay hidden and append its console output to the log."""
    global process, reader_thread, log_writer, session_state, shutdown_signal

    stop_uxplay()

    if log_writer is None:
        log_writer = create_log_writer()
    log_writer.info(
        "\n=== UxPlayEnhanced tray session "
        + datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        + " ==="
    )

    env = os.environ.copy()
    env["GST_PLUGIN_PATH"] = GST_PLUGIN_PATH
    env["PATH"] = SCRIPT_DIR + os.pathsep + env.get("PATH", "")
    signal = ShutdownSignal()
    env["UXPLAYENHANCED_STOP_EVENT"] = signal.name
    env["UXPLAYENHANCED_PARENT_PID"] = str(os.getpid())

    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = 0

    with state_lock:
        session_state = new_state()
        try:
            process = subprocess.Popen(
                UXPLAY_ARGS,
                cwd=SCRIPT_DIR,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                startupinfo=startupinfo,
                creationflags=subprocess.CREATE_NO_WINDOW,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
        except BaseException:
            signal.close()
            raise
        shutdown_signal = signal
        started = process

    reader_thread = threading.Thread(
        target=pump_output,
        args=(started.stdout, handle_output_line),
        daemon=True,
    )
    reader_thread.start()


def stop_uxplay():
    """Stop UxPlay and wait for its output reader to drain."""
    global process, reader_thread, shutdown_signal

    with state_lock:
        current_process = process
        process = None
    current_reader = reader_thread
    reader_thread = None
    current_signal = shutdown_signal
    shutdown_signal = None

    if current_process and current_process.poll() is None:
        try:
            if current_signal:
                current_signal.request()
            current_process.wait(timeout=10)
        except OSError:
            current_process.terminate()
            current_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if log_writer:
                log_writer.warning("Graceful receiver shutdown timed out; forcing exit.")
            current_process.kill()
            current_process.wait(timeout=5)

    if current_signal:
        current_signal.close()

    if current_reader:
        # The reader ends when the pipe closes, which the exit above guarantees.
        current_reader.join(timeout=5)


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
    instance = SingleInstance()
    if not instance.acquired:
        return
    try:
        run_tray()
    finally:
        stop_monitor.set()
        stop_uxplay()
        instance.close()


def run_tray():
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
