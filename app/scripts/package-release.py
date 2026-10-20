"""Package existing production builds; never include development keys or caches."""
from pathlib import Path
import hashlib
import shutil
import zipfile
import argparse
import json
import re

arguments = argparse.ArgumentParser()
arguments.add_argument('--include-android', action='store_true')
options = arguments.parse_args()

root = Path(__file__).resolve().parents[2]
app = root / 'app'
output = root / 'releases'
output.mkdir(exist_ok=True)
version = re.search(r'^version:\s*([^+\s]+)', (app/'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE).group(1)

def archive(folder, destination, prefix='', omit=None):
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as bundle:
        for file in sorted(folder.rglob('*')):
            relative = file.relative_to(folder)
            if omit and omit(relative):
                continue
            if file.is_file():
                bundle.write(file, str(Path(prefix) / relative))

release = app / 'build/windows/x64/runner/Release'
if not (release / 'focus_garden.exe').exists():
    raise SystemExit('Build production Windows main.dart first')
# Versioned destinations let a new build be delivered while an older portable
# release is running. Never overwrite a user's loaded EXE/DLLs.
desktop = output / f'FocusGarden-{version}-Windows-x64' / 'FocusGarden-Windows-x64'
shutil.copytree(release, desktop, dirs_exist_ok=True)
# Flutter's test build may leave a host-only asset map at the bundle root. The
# runtime uses data/flutter_assets/NativeAssetsManifest.json, which is portable.
host_asset_map = desktop / 'native_assets.json'
if host_asset_map.exists():
    host_asset_map.unlink()
redist = root / 'work/vsbuild/VC/Redist/MSVC/14.44.35112/x64/Microsoft.VC143.CRT'
if not redist.exists():
    raise SystemExit('MSVC runtime folder not found')
for library in redist.glob('*.dll'):
    shutil.copy2(library, desktop)
shutil.copy2(app / 'README.md', desktop / '使用说明.md')
archive(desktop, output / f'FocusGarden-{version}-Windows-x64.zip', desktop.name)

apk = app / 'build/app/outputs/flutter-apk/app-release.apk'
if options.include_android:
    metadata = json.loads((app/'build/app/outputs/apk/release/output-metadata.json').read_text(encoding='utf-8'))
    if not apk.exists() or metadata['elements'][0]['versionName'] != version:
        raise SystemExit('Build an Android APK matching the current source version first')
    shutil.copy2(apk, output / f'FocusGarden-{version}-Android.apk')

excluded_dirs = {'.git', '.dart_tool', '.gradle', '.idea', 'build', 'ephemeral', '.plugin_symlinks', '.cxx', 'captures'}
excluded_files = {'local.properties', 'key.properties', '.flutter-plugins-dependencies', '.flutter-plugins'}
def omit(relative):
    return bool(set(relative.parts) & excluded_dirs) or relative.name in excluded_files or relative.suffix in {'.jks', '.keystore', '.iml'}
archive(app, output / f'FocusGarden-{version}-source.zip', 'app', omit)
with zipfile.ZipFile(output / f'FocusGarden-{version}-source.zip') as check:
    if check.testzip() is not None:
        raise SystemExit('Source archive integrity check failed')

files = sorted([*output.glob('*.zip'), *output.glob('*.apk')])
(output / 'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}\n' for file in files), encoding='ascii')
for file in files:
    print(f'{file.name}: {file.stat().st_size:,} bytes')
