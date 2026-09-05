"""Opt-in live receiver tests. Set UXPLAYENHANCED_TEST_PACKAGE to a built ZIP folder."""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest
import uuid

from test_tray import tray, ROOT

PACKAGE = os.environ.get('UXPLAYENHANCED_TEST_PACKAGE')


def record_ttls(packet):
    def skip_name(pos):
        while packet[pos]:
            if packet[pos] & 0xc0 == 0xc0:
                return pos + 2
            pos += 1 + packet[pos]
        return pos + 1
    _, _, questions, answers, authority, additional = struct.unpack_from('!6H', packet)
    pos = 12
    for _ in range(questions):
        pos = skip_name(pos) + 4
    values = []
    for _ in range(answers + authority + additional):
        pos = skip_name(pos)
        _, _, ttl, length = struct.unpack_from('!HHIH', packet, pos)
        values.append(ttl)
        pos += 10 + length
    return values


@unittest.skipUnless(PACKAGE and sys.platform == 'win32', 'Opt-in Windows receiver test')
class ShutdownTests(unittest.TestCase):
    def test_quit_closes_socket_and_sends_goodbye(self):
        name = 'UxPlayTest-' + uuid.uuid4().hex[:12]
        signal = tray.ShutdownSignal()
        env = os.environ.copy()
        env.update(UXPLAYENHANCED_STOP_EVENT=signal.name, UXPLAYENHANCED_PARENT_PID=str(os.getpid()),
                   GST_PLUGIN_PATH=str(Path(PACKAGE) / 'lib/gstreamer-1.0'), GST_PLUGIN_SYSTEM_PATH='')
        receiver = None
        control = None
        mdns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        mdns.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        mdns.bind(('', 5353))
        mdns.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                        socket.inet_aton('224.0.0.251') + socket.inet_aton('0.0.0.0'))
        mdns.settimeout(0.2)
        lines = []
        reader = None
        try:
            receiver = subprocess.Popen([str(Path(PACKAGE) / 'uxplay.exe'), '-n', name, '-nh',
                                         '-vs', '0', '-no-progress', '-p', '19320'],
                                        cwd=PACKAGE, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, encoding='utf-8', errors='replace', creationflags=subprocess.CREATE_NO_WINDOW)
            reader = threading.Thread(target=lambda: lines.extend(receiver.stdout), daemon=True)
            reader.start()
            deadline = time.monotonic() + 15
            announced = False
            while time.monotonic() < deadline:
                if receiver.poll() is not None:
                    self.fail('Receiver exited during startup: ' + ''.join(lines))
                try:
                    data = mdns.recv(9000)
                    if name.encode() in data and any(record_ttls(data)):
                        announced = True
                        break
                except socket.timeout:
                    pass
            self.assertTrue(announced, 'No test-receiver announcement received: ' + ''.join(lines))
            control = socket.create_connection(('127.0.0.1', 19321), timeout=5)
            control.sendall(b'OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n')
            self.assertIn(b'200', control.recv(4096))
            signal.request()
            self.assertEqual(receiver.wait(timeout=12), 0)
            reader.join(timeout=2)
            self.assertIn('Stopping RAOP Server...', ''.join(lines))
            goodbye = False
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    data = mdns.recv(9000)
                    ttls = record_ttls(data) if name.encode() in data else []
                    if ttls and all(ttl == 0 for ttl in ttls):
                        goodbye = True
                        break
                except socket.timeout:
                    pass
            self.assertTrue(goodbye, 'No TTL=0 goodbye for the test receiver')
            try:
                self.assertEqual(control.recv(4096), b'')
            except ConnectionResetError:
                pass
        finally:
            if receiver and receiver.poll() is None:
                receiver.kill()
                receiver.wait()
            if reader:
                reader.join(timeout=2)
            if receiver:
                receiver.stdout.close()
            if control:
                control.close()
            signal.close()
            mdns.close()

    def test_receiver_exits_when_parent_is_killed(self):
        code = f'''
import runpy,os,subprocess,time,sys
m=runpy.run_path({str(ROOT / 'launcher/uxplay_tray.pyw')!r})
s=m['ShutdownSignal']()
e=os.environ.copy()
e.update(UXPLAYENHANCED_STOP_EVENT=s.name,UXPLAYENHANCED_PARENT_PID=str(os.getpid()),GST_PLUGIN_PATH={str(Path(PACKAGE) / 'lib/gstreamer-1.0')!r},GST_PLUGIN_SYSTEM_PATH='')
p=subprocess.Popen([{str(Path(PACKAGE) / 'uxplay.exe')!r},'-n','UxPlayParentExitTest','-nh','-vs','0','-no-progress','-p','19330'],cwd={PACKAGE!r},env=e,stdout=sys.stdout,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
print('RECEIVER_PID='+str(p.pid),flush=True)
time.sleep(60)
'''
        parent = subprocess.Popen([sys.executable, '-u', '-c', code], stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
        lines = []
        reader = threading.Thread(target=lambda: lines.extend(parent.stdout), daemon=True)
        reader.start()
        handle = None
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if any('Initialized server socket(s)' in line for line in lines):
                    break
                time.sleep(0.1)
            self.assertTrue(any('Initialized server socket(s)' in line for line in lines), ''.join(lines))
            pid = int(next(line.split('=')[1] for line in lines if line.startswith('RECEIVER_PID=')))
            handle = kernel.OpenProcess(0x100000 | 0x1000, False, pid)
            self.assertTrue(handle)
            parent.terminate()
            parent.wait(timeout=3)
            self.assertEqual(kernel.WaitForSingleObject(handle, 12000), 0, 'Receiver survived its tray parent')
            exit_code = wintypes.DWORD()
            self.assertTrue(kernel.GetExitCodeProcess(handle, ctypes.byref(exit_code)))
            self.assertEqual(exit_code.value, 0)
            reader.join(timeout=2)
            self.assertIn('Stopping RAOP Server...', ''.join(lines))
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=3)
            if handle:
                kernel.CloseHandle(handle)
            reader.join(timeout=15)
            parent.stdout.close()


if __name__ == '__main__':
    unittest.main()
