"""Verify workflow_probe.dart with isolated data and only that process's windows."""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('executable', type=Path)
parser.add_argument('results', type=Path)
args = parser.parse_args()
exe, folder = args.executable.resolve(), args.results.resolve()
folder.mkdir(parents=True, exist_ok=True)
if any(folder.iterdir()):
    raise SystemExit('Use a new empty results directory')
user = ctypes.WinDLL('user32', use_last_error=True)
callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user.EnumWindows.argtypes = [callback, wintypes.LPARAM]
user.EnumChildWindows.argtypes = [wintypes.HWND, callback, wintypes.LPARAM]
user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
user.GetWindowLongPtrW.restype = ctypes.c_ssize_t
user.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]

def windows(parent=None):
    found = []
    @callback
    def visit(handle, _):
        pid = wintypes.DWORD()
        user.GetWindowThreadProcessId(handle, ctypes.byref(pid))
        if pid.value == process.pid:
            found.append(handle)
        return True
    if parent is None:
        user.EnumWindows(visit, 0)
    else:
        user.EnumChildWindows(parent, visit, 0)
    return found

def wait_file(name):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        path = folder / name
        if path.exists():
            return path
        if (folder / 'result.json').exists():
            raise RuntimeError((folder / 'result.json').read_text(encoding='utf-8'))
        if process.poll() is not None:
            raise RuntimeError(f'Probe exited: {process.returncode}')
        time.sleep(.1)
    raise TimeoutError(name)

process = None
try:
    with (folder / 'runtime.log').open('w', encoding='utf-8') as log:
        env = dict(os.environ, FOCUS_NATIVE_PROBE='1', FOCUS_WORKFLOW_PROBE_DIR=str(folder))
        process = subprocess.Popen([str(exe), '--autostart'], cwd=exe.parent, env=env,
                                   creationflags=subprocess.CREATE_NO_WINDOW, stdout=log, stderr=log)
        wait_file('pinned.json')
        assert any(user.GetWindowLongPtrW(handle, -20) & 8 for handle in windows()), 'WS_EX_TOPMOST not set'
        (folder / 'continue').touch()
        result = json.loads(wait_file('result.json').read_text(encoding='utf-8'))
        assert result['ok'], result
        assert not any(user.GetWindowLongPtrW(handle, -20) & 8 for handle in windows()), 'WS_EX_TOPMOST not cleared'
        result['osTopmostStyleVerified'] = True
        for handle in windows():
            for child in windows(handle):
                user.PostMessageW(child, 0x111, 1026, 0)
            user.PostMessageW(handle, 0x111, 1026, 0)
        result['cleanTrayExit'] = process.wait(timeout=20) == 0
        assert result['cleanTrayExit']
        (folder / 'verification.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print(json.dumps(result, indent=2))
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
