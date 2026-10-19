"""Permit pre-created local plugin junctions without changing Windows Developer Mode."""
from pathlib import Path
import sys
root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / 'work'
file = root / 'flutter/packages/flutter_tools/lib/src/flutter_plugins.dart'
source = file.read_text(encoding='utf-8')
old = 'if (link.existsSync()) {\n      continue;\n    }'
new = 'if (link.existsSync() || symlinkDirectory.childDirectory(name).existsSync()) {\n      continue;\n    }'
if old in source:
    source = source.replace(old, new)
original_catch = '''} on FileSystemException catch (e) {
      handleSymlinkException('''
junction_catch = '''} on FileSystemException catch (e) {
      if (globals.platform.isWindows && e.osError?.errorCode == 1314) {
        final result = globals.processManager.runSync(
          <String>['cmd.exe', '/d', '/c', 'mklink', '/J', link.path, path],
        );
        if (result.exitCode == 0) { continue; }
      }
      handleSymlinkException('''
if original_catch in source:
    source = source.replace(original_catch, junction_catch)
file.write_text(source, encoding='utf-8')
print('Flutter plugin junction compatibility ready')
