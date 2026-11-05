"""Verify playlist scope with generated WAV files. Never read personal audio or databases."""
import argparse
import ctypes
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import time
import wave

parser = argparse.ArgumentParser()
parser.add_argument('executable', type=Path)
parser.add_argument('results', type=Path)
parser.add_argument('--skip-shortcuts', action='store_true')
args = parser.parse_args()
folder = args.results.resolve()
folder.mkdir(parents=True, exist_ok=True)
if any(folder.iterdir()):
    raise SystemExit('Use a new empty results directory')
for name, frequency in [('a',220),('b',330),('outside',440)]:
    with wave.open(str(folder/(name+'.wav')),'wb') as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
        output.writeframes(b''.join(struct.pack('<h',int(3000*math.sin(2*math.pi*frequency*i/16000))) for i in range(64000)))
process = None
sent = set()
def track_shortcut(key):
    # The probe publishes readiness only after successful global registration.
    from ctypes import wintypes
    user = ctypes.WinDLL('user32', use_last_error=True)
    user.keybd_event.argtypes = [wintypes.BYTE, wintypes.BYTE, wintypes.DWORD, ctypes.c_size_t]
    pressed = []
    try:
        for code in (0x11, 0x10, key):
            user.keybd_event(code, 0, 1 if code == key else 0, 0)
            pressed.append(code)
            time.sleep(.03)
    finally:
        for code in reversed(pressed):
            user.keybd_event(code, 0, 3 if code == key else 2, 0)
try:
    with (folder/'runtime.log').open('w',encoding='utf-8') as log:
        process = subprocess.Popen([str(args.executable.resolve()),'--autostart'],cwd=args.executable.resolve().parent,
            env=dict(os.environ,FOCUS_NATIVE_PROBE='1',FOCUS_PLAYLIST_PROBE_DIR=str(folder),
                FOCUS_PROBE_SKIP_SHORTCUTS=str(int(args.skip_shortcuts))),
            creationflags=subprocess.CREATE_NO_WINDOW,stdout=log,stderr=log)
        deadline=time.monotonic()+120
        while not (folder/'result.json').exists():
            if process.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('Playlist probe exited or timed out')
            for marker, key in [('shortcut-previous-ready', 0x27), ('shortcut-next-ready', 0x25)]:
                if marker not in sent and (folder/marker).exists():
                    track_shortcut(key)
                    sent.add(marker)
            time.sleep(.1)
        result=json.loads((folder/'result.json').read_text(encoding='utf-8'))
        if not result['ok'] or process.wait(timeout=15)!=0:
            raise RuntimeError(str(result))
        print(json.dumps(result,indent=2))
finally:
    if process is not None and process.poll() is None:
        process.terminate(); process.wait(timeout=10)
