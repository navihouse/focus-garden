"""Run the desktop probe without touching an existing app or its data.

Build test_support/desktop_integration_probe.dart first, then pass its exe and
an empty result directory. The FocusGarden Run value is always restored.
"""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import time
import winreg

args = argparse.ArgumentParser()
args.add_argument('executable', type=Path)
args.add_argument('results', type=Path)
options = args.parse_args()
executable = options.executable.resolve()
folder = options.results.resolve()
folder.mkdir(parents=True, exist_ok=True)
if any(folder.iterdir()):
    raise SystemExit('Use a new, empty results directory')
run_key = r'Software\Microsoft\Windows\CurrentVersion\Run'
key = winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, run_key, 0,
                        winreg.KEY_QUERY_VALUE | winreg.KEY_SET_VALUE)
try:
    previous = winreg.QueryValueEx(key, 'FocusGarden')
except FileNotFoundError:
    previous = None

user = ctypes.WinDLL('user32', use_last_error=True)
callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user.EnumWindows.argtypes = [callback, wintypes.LPARAM]
user.EnumChildWindows.argtypes = [wintypes.HWND, callback, wintypes.LPARAM]
user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user.IsWindowVisible.argtypes = [wintypes.HWND]
user.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]

def wait(predicate, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        if process.poll() is not None:
            raise RuntimeError(f'Probe exited early: {process.returncode}')
        time.sleep(.1)
    raise TimeoutError('Desktop probe timed out')

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

process = None
try:
    env = dict(os.environ, FOCUS_NATIVE_PROBE='1', FOCUS_DESKTOP_PROBE_DIR=str(folder))
    with (folder / 'runtime.log').open('w', encoding='utf-8') as log:
        process = subprocess.Popen([str(executable), '--autostart'],
                                   cwd=executable.parent, env=env,
                                   creationflags=subprocess.CREATE_NO_WINDOW,
                                   stdout=log, stderr=log)
        wait(lambda: (folder / 'enabled.json').exists() or (folder / 'result.json').exists())
        command, value_type = winreg.QueryValueEx(key, 'FocusGarden')
        # resolve() canonicalizes a SUBST drive to its actual physical path.
        assert value_type == winreg.REG_SZ
        assert command == f'"{executable}" --autostart', 'Run command has an alias or wrong executable'
        assert not any(user.IsWindowVisible(handle) for handle in windows()), 'Autostart showed a window'
        (folder / 'continue').touch()
        wait(lambda: (folder / 'result.json').exists())
        result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
        assert result['ok'], result
        main = wait(lambda: windows())
        for handle in main:
            user.PostMessageW(handle, 0x401, 0, 0x202)
            for child in windows(handle):
                user.PostMessageW(child, 0x401, 0, 0x202)
        wait(lambda: any(user.IsWindowVisible(handle) for handle in windows()))
        result.update(hiddenAutostart=True, physicalRunPath=True, trayRestore=True)
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
    if previous is None:
        try:
            winreg.DeleteValue(key, 'FocusGarden')
        except FileNotFoundError:
            pass
    else:
        winreg.SetValueEx(key, 'FocusGarden', 0, previous[1], previous[0])
    key.Close()
