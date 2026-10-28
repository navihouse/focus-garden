"""Scan the Git index, so checks apply to the exact content being uploaded."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]

def git(*arguments):
    return subprocess.check_output(['git', '-C', str(ROOT), *arguments])

files = [name.decode('utf-8') for name in git('ls-files', '-z').split(b'\0') if name]
forbidden_parts = {'.git', '.dart_tool', '.gradle', '.kotlin', '.idea', '.cxx', 'build', 'ephemeral', 'work', 'releases', 'signing'}
forbidden_names = {'key.properties', 'local.properties', 'credentials.json', '.env'}
forbidden_suffixes = {'.jks', '.keystore', '.pem', '.p12', '.pfx', '.sqlite', '.db', '.log', '.mp3', '.m4a', '.flac', '.wav', '.ogg', '.aac'}
patterns = {
    'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'GitHub token': r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b',
    'AWS key': r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'Slack token': r'\bxox[baprs]-[A-Za-z0-9-]{20,}\b',
    'Google API key': r'\bAIza[A-Za-z0-9_-]{30,}\b',
    'credential in URL': r'https?://[^\s/:@]+:[^\s@]+@',
    'personal home path': r'[A-Z]:[/\\]Users[/\\](?!Public\b|Default\b)[^/\\\s]+',
    'personal contact email': r'\b[\w.+-]+@(?:qq|163|126|gmail|outlook|hotmail)\.com\b',
}
findings = []
size = 0
for name in files:
    path = Path(name)
    if name not in {'.gitignore', '.gitattributes', 'README.md', 'PRIVACY_CHECK.md', '.github/workflows/verify.yml'} and not name.startswith('app/'):
        findings.append((name, 'unreviewed root path'))
    if set(path.parts) & forbidden_parts or path.name in forbidden_names or path.suffix.lower() in forbidden_suffixes:
        findings.append((name, 'private file type or directory'))
    data = git('show', ':' + name)
    size += len(data)
    if len(data) > 2 * 1024 * 1024:
        findings.append((name, 'unexpected large source file'))
    try:
        content = data.decode('utf-8')
    except UnicodeDecodeError:
        if path.suffix.lower() not in {'.png', '.ico', '.jar'}:
            findings.append((name, 'unreviewed binary'))
        continue
    for label, pattern in patterns.items():
        for number, line in enumerate(content.splitlines(), 1):
            if re.search(pattern, line, re.IGNORECASE if label in {'personal home path', 'personal contact email'} else 0):
                findings.append((name + ':' + str(number), label))

if findings:
    for name, reason in findings:
        print(f'{name}: {reason}')  # Never print matching secret values.
    sys.exit(1)
print(f'PASS: {len(files)} indexed files, {size:,} bytes; no findings in configured privacy checks.')
