"""Use a unique temporary file association to verify ShellExecute without opening user apps."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
import winreg

parser = argparse.ArgumentParser()
parser.add_argument('executable', type=Path)
parser.add_argument('results', type=Path)
args = parser.parse_args()
folder = args.results.resolve()
folder.mkdir(parents=True, exist_ok=True)
if any(folder.iterdir()):
    raise SystemExit('Use a new empty probe result directory')
suffix = uuid.uuid4().hex
extension = '.fg' + suffix
program_id = 'FocusGarden.LinkProbe.' + suffix
prefix = 'Software\\Classes\\'
target = folder / ('讲义 & 练习 (1)' + extension)
target.write_text('isolated fixture', encoding='utf-8')
(folder / 'target-path.txt').write_text(str(target), encoding='utf-8')
helper = folder / 'association-helper.py'
helper.write_text("import json,sys\nfrom pathlib import Path\nPath(__file__).with_name('opened.json').write_text(json.dumps({'path':sys.argv[1]},ensure_ascii=False),encoding='utf-8')\n", encoding='utf-8')
created = []
process = None
try:
    # These UUID-named keys are new. Never replace an existing association.
    for name in [extension, program_id]:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, prefix + name):
                raise RuntimeError('Temporary test key unexpectedly exists')
        except FileNotFoundError:
            pass
    command = subprocess.list2cmdline([str(Path(sys.executable).with_name('pythonw.exe')), str(helper)]) + ' "%1"'
    for name, value in [(extension, program_id), (program_id, 'Focus Garden isolated test'),
                        (program_id + r'\shell', ''), (program_id + r'\shell\open', ''),
                        (program_id + r'\shell\open\command', command)]:
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, prefix + name) as key:
            winreg.SetValueEx(key, '', 0, winreg.REG_SZ, value)
        created.append(name)
    ctypes.windll.shell32.SHChangeNotify(0x08000000, 0, None, None)
    with (folder / 'runtime.log').open('w', encoding='utf-8') as log:
        process = subprocess.Popen([str(args.executable.resolve()), '--autostart'], cwd=args.executable.resolve().parent,
            env=dict(os.environ, FOCUS_NATIVE_PROBE='1', FOCUS_LINK_PROBE_DIR=str(folder)),
            stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
        deadline = time.monotonic() + 45
        while not (folder / 'result.json').exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Probe exited or timed out')
            time.sleep(.1)
        result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
        if not result['ok'] or process.wait(timeout=15) != 0:
            raise RuntimeError(str(result))
        print(json.dumps(result, indent=2))
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=10)
    for name in reversed(created):
        winreg.DeleteKey(winreg.HKEY_CURRENT_USER, prefix + name)
    ctypes.windll.shell32.SHChangeNotify(0x08000000, 0, None, None)
