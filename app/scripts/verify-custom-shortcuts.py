"""Verify only the opted-in probe: real Windows registration, dispatch and rollback."""
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
folder = args.results.resolve()
folder.mkdir(parents=True, exist_ok=True)
if any(folder.iterdir()):
    raise SystemExit('Use a new empty probe results directory')
user = ctypes.WinDLL('user32', use_last_error=True)
user.RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int, wintypes.UINT, wintypes.UINT]
user.UnregisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int]
user.keybd_event.argtypes = [wintypes.BYTE, wintypes.BYTE, wintypes.DWORD, ctypes.c_size_t]

def press(modifier, key):
    # Use only combinations verified as owned by the isolated probe.
    for code in modifier + [key]:
        user.keybd_event(code, 0, 0, 0)
    for code in reversed(modifier + [key]):
        user.keybd_event(code, 0, 2, 0)

process = None
reserved = False
try:
    env = dict(os.environ, FOCUS_NATIVE_PROBE='1', FOCUS_SETTINGS_PROBE_DIR=str(folder))
    with (folder / 'runtime.log').open('w', encoding='utf-8') as log:
        process = subprocess.Popen([str(args.executable.resolve()), '--autostart'],
            cwd=args.executable.resolve().parent, env=env, creationflags=subprocess.CREATE_NO_WINDOW,
            stdout=log, stderr=log)
        def wait(name):
            deadline = time.monotonic() + 40
            while not (folder / name).exists():
                if (folder / 'result.json').exists():
                    raise RuntimeError((folder / 'result.json').read_text(encoding='utf-8'))
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f'Probe stopped or timed out at {name}')
                time.sleep(.05)
        wait('ready')
        press([0x11, 0x10], 0x78)  # Ctrl+Shift+F9 (music)
        time.sleep(.2)
        press([0x11, 0x12], 0x78)  # Ctrl+Alt+F9 (timer)
        wait('reserve-conflict')
        reserved = bool(user.RegisterHotKey(None, 5511, 6 | 0x4000, 0x79))
        if not reserved:
            raise RuntimeError('Could not reserve the explicit conflict test combination')
        (folder / 'conflict-reserved').touch()
        wait('rollback-ready')
        press([0x11, 0x12], 0x78)
        wait('swap-ready')
        user.UnregisterHotKey(None, 5511)
        reserved = False
        (folder / 'conflict-released').touch()
        wait('swapped')
        # Both former probe combinations must now be available to this process.
        for index, modifiers in enumerate([6, 3]):
            if not user.RegisterHotKey(None, 5520 + index, modifiers | 0x4000, 0x78):
                raise RuntimeError('Old custom binding was not released')
            user.UnregisterHotKey(None, 5520 + index)
        press([0x11, 0x12], 0x79)
        wait('result.json')
        result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
        if not result['ok'] or process.wait(timeout=15) != 0:
            raise RuntimeError('Native validation failed')
        result['oldBindingsReleased'] = True
        (folder / 'verification.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print(json.dumps(result, indent=2))
finally:
    if reserved:
        user.UnregisterHotKey(None, 5511)
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
