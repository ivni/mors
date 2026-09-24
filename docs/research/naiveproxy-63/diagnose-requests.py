"""Compare bounded direct-origin and router-SOCKS probes after a failed benchmark."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys

directory = Path(sys.argv[1]).resolve()
count = int(sys.argv[2]) if len(sys.argv) > 2 else 100
concurrency = int(sys.argv[3]) if len(sys.argv) > 3 else 8
if not 1 <= count <= 200:
    raise SystemExit('count must be 1..200')
if concurrency not in (1, 8, 32):
    raise SystemExit('concurrency must be 1, 8, or 32')


def probe(route, index):
    command = ['curl.exe', '-sS', '--ssl-revoke-best-effort', '--cacert',
        str(directory / 'root.pem'), '--connect-timeout', '8', '--max-time', '20',
        '-o', 'NUL', '-w', '%{http_code} %{size_download} %{time_total}']
    if route == 'socks':
        command += ['--socks5-hostname', '127.0.0.1:28100']
    else:
        command += ['--noproxy', '*', '--resolve', 'nonce.fixture.invalid:18444:127.0.0.1']
    command += ['https://nonce.fixture.invalid:18444/bytes']
    result = subprocess.run(command, capture_output=True, text=True, timeout=25)
    labels = [label for needle, label in [
        ('schannel', 'schannel'), ('handshake', 'handshake'), ('timed out', 'timeout'),
        ('reset', 'reset'), ('certificate', 'certificate'), ('recv', 'receive'),
        ('connect', 'connect'), ('SEC_E_', 'schannel_status')]
        if needle.lower() in result.stderr.lower()]
    fields = result.stdout.split()
    row = dict(route=route, index=index, exit=result.returncode, labels=labels)
    if len(fields) == 3:
        row.update(http=int(fields[0]), size=int(fields[1]), seconds=float(fields[2]))
    return row


rows = []
for route in ['direct', 'socks']:
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        batch = list(executor.map(lambda index: probe(route, index), range(count)))
    rows.extend(batch)
    failures = [r for r in batch if r['exit'] or r.get('http') != 200 or r.get('size') != 262144]
    print(json.dumps(dict(route=route, total=count, failed=len(failures), failures=failures)), flush=True)
(directory / 'diagnostic-results.json').write_text(json.dumps(rows))
