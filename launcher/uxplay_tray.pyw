"""
UxPlay AirPlay Receiver - System Tray Launcher
Runs uxplay.exe in the background with a tray icon.
Right-click the tray icon to quit.

Requirements: pip install pystray pillow
"""

import os
import socket
import subprocess
import sys

from PIL import Image, ImageDraw
import pystray

# Paths relative to this script
SCRIPT_DIR = os.path.dirname(os.path.abspath(sys.argv[0] if sys.argv[0] else __file__))
UXPLAY_EXE = os.path.join(SCRIPT_DIR, "uxplay.exe")
GST_PLUGIN_PATH = os.path.join(SCRIPT_DIR, "lib", "gstreamer-1.0")

# Auto-detect a friendly name from the computer's hostname
AIRPLAY_NAME = socket.gethostname()

# UxPlay arguments
UXPLAY_ARGS = [
    UXPLAY_EXE,
    "-n", AIRPLAY_NAME,
    "-nh",
    "-vs",
    "0",
]

process = None


def create_icon_image():
    """Create a simple AirPlay-style tray icon."""
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx, cy = size // 2, size // 2 + 8
    for r in [28, 20, 12]:
        bbox = (cx - r, cy - r, cx + r, cy + r)
        draw.arc(bbox, 200, 340, fill="white", width=3)

    tri_y = cy + 2
    draw.polygon([(cx - 6, tri_y), (cx + 6, tri_y), (cx, tri_y - 10)], fill="white")

    return img


def start_uxplay():
    """Start the uxplay process hidden."""
    global process

    env = os.environ.copy()
    env["GST_PLUGIN_PATH"] = GST_PLUGIN_PATH
    env["PATH"] = SCRIPT_DIR + os.pathsep + env.get("PATH", "")

    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = 0  # SW_HIDE

    process = subprocess.Popen(
        UXPLAY_ARGS,
        cwd=SCRIPT_DIR,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        startupinfo=startupinfo,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )


def stop_uxplay():
    """Stop the uxplay process."""
    global process
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    process = None


def on_quit(icon, item):
    stop_uxplay()
    icon.stop()


def on_restart(icon, item):
    stop_uxplay()
    start_uxplay()
    icon.notify("UxPlay restarted", "AirPlay Receiver")


def setup(icon):
    icon.visible = True
    start_uxplay()


def main():
    icon = pystray.Icon(
        "UxPlay",
        create_icon_image(),
        f"UxPlay AirPlay Receiver ({AIRPLAY_NAME})",
        menu=pystray.Menu(
            pystray.MenuItem(
                f"AirPlay: {AIRPLAY_NAME}", None, enabled=False
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Restart", on_restart),
            pystray.MenuItem("Quit", on_quit),
        ),
    )
    icon.run(setup)


if __name__ == "__main__":
    main()
