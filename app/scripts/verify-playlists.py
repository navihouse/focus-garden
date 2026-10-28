"""Verify playlist scope with generated WAV files. Never read personal audio or databases."""
import argparse
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
try:
    with (folder/'runtime.log').open('w',encoding='utf-8') as log:
        process = subprocess.Popen([str(args.executable.resolve()),'--autostart'],cwd=args.executable.resolve().parent,
            env=dict(os.environ,FOCUS_NATIVE_PROBE='1',FOCUS_PLAYLIST_PROBE_DIR=str(folder)),
            creationflags=subprocess.CREATE_NO_WINDOW,stdout=log,stderr=log)
        deadline=time.monotonic()+90
        while not (folder/'result.json').exists():
            if process.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('Playlist probe exited or timed out')
            time.sleep(.1)
        result=json.loads((folder/'result.json').read_text(encoding='utf-8'))
        if not result['ok'] or process.wait(timeout=15)!=0:
            raise RuntimeError(str(result))
        print(json.dumps(result,indent=2))
finally:
    if process is not None and process.poll() is None:
        process.terminate(); process.wait(timeout=10)
