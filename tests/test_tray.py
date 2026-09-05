import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("tray_under_test", str(ROOT / "launcher/uxplay_tray.pyw"))
spec = importlib.util.spec_from_loader(loader.name, loader)
tray = importlib.util.module_from_spec(spec)
loader.exec_module(tray)


class TrayTests(unittest.TestCase):
    def test_disconnect_and_reconnect(self):
        state = tray.new_state()
        for line in (
            "connection request from Phone (iPhone) with deviceID = 123",
            "audio session started",
            "audio quality: codec=ALAC (ct=2); quality=Lossless; resolution=16-bit/44100 Hz; channels=2",
            "start audio connection, format alac", "Title: Old song", "audio error",
        ):
            tray.apply_log_line(state, line)
        self.assertTrue(state["audio_connected"])
        self.assertIn("44.1 kHz", state["quality"])
        tray.apply_log_line(state, "Connection closed on socket 12")
        self.assertTrue(state["audio_connected"], "Unrelated sockets must not end audio")
        tray.apply_log_line(state, "audio session ended")
        self.assertEqual(state, tray.new_state())
        tray.apply_log_line(state, "audio session started")
        self.assertTrue(state["audio_connected"])
        self.assertFalse(state["audio_error"])

    def test_metadata_missing_and_empty_fields(self):
        state = tray.new_state()
        for line in ("Title: Old", "Artist: Previous artist", "Album: Previous album",
                     "====================Audio Metadata==================", "Title: New"):
            tray.apply_log_line(state, line)
        self.assertEqual(tray.current_song(state), "New")
        tray.apply_log_line(state, "Artist: Artist")
        tray.apply_log_line(state, "Artist: ")
        self.assertEqual(state["artist"], "")

    @unittest.skipUnless(sys.platform == "win32", "Windows named mutex")
    def test_single_instance_across_processes(self):
        name = "Local\\UxPlayEnhanced.Test." + uuid.uuid4().hex
        owner = tray.SingleInstance(name)
        self.assertTrue(owner.acquired)
        code = (
            "import runpy,sys; "
            f"m=runpy.run_path({str(ROOT / 'launcher/uxplay_tray.pyw')!r}); "
            f"guard=m['SingleInstance']({name!r}); "
            "sys.exit(0 if guard.acquired else 7)"
        )
        try:
            self.assertEqual(subprocess.run([sys.executable, "-c", code]).returncode, 7)
        finally:
            owner.close()
        self.assertEqual(subprocess.run([sys.executable, "-c", code]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
