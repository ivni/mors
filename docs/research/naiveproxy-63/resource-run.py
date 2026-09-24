"""Bounded fixture benchmark; run only after disposable target identity checks.

Five minutes idle then five minutes each at concurrency 1/8/32. The
loopback SSH path and unpadded CONNECT fixture are NOT WAN performance.
Samples and aggregate curl results contain no credentials or endpoints.
"""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

directory = Path(sys.argv[1]).resolve()
duration = int(sys.argv[2]) if len(sys.argv) > 2 else 300
if not 10 <= duration <= 300:
    raise SystemExit('duration must be 10..300 seconds')
base = '/opt/tmp/mors-naive63-followup-20260922'
stop = threading.Event()
lock = threading.Lock()
results = []
aggregates = {}
guard_hit = False


def ssh(command):
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                             'mors-test-router', command], capture_output=True,
                            text=True, timeout=20)
    if result.returncode:
        raise RuntimeError('SSH_CONTROL_FAILED')
    return result.stdout


def worker(phase, deadline):
    while time.monotonic() < deadline and not stop.is_set():
        result = subprocess.run(['curl.exe', '-s', '--ssl-revoke-best-effort',
            '--cacert', str(directory / 'root.pem'), '--connect-timeout', '8',
            '--max-time', '20', '--socks5-hostname', '127.0.0.1:28100',
            '-o', 'NUL', '-w', '%{http_code} %{size_download} %{time_total}',
            'https://nonce.fixture.invalid:18444/bytes'], capture_output=True,
            text=True, timeout=25)
        fields = result.stdout.split()
        with lock:
            agg = aggregates[phase]
            if result.returncode == 0 and len(fields) == 3 and fields[0] == '200':
                agg['ok'] += 1
                agg['bytes'] += int(fields[1])
                agg['latency_sum'] += float(fields[2])
                agg['latency_max'] = max(agg['latency_max'], float(fields[2]))
            else:
                agg['failed'] += 1
                # Numeric classifications only; never persist raw stderr.
                error = str(result.returncode)
                agg['curl_exit_counts'][error] = agg['curl_exit_counts'].get(error, 0) + 1
        stop.wait(0.25)


try:
    ssh(f'sh {base}/fixture-client.sh start load')
    for phase, concurrency in [('idle', 0), ('load1', 1), ('load8', 8), ('load32', 32)]:
        started = time.monotonic()
        deadline = started + duration
        aggregates[phase] = dict(ok=0, failed=0, bytes=0, latency_sum=0.0,
                                 latency_max=0.0, curl_exit_counts={})
        print(f'PHASE_START {phase}', flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(concurrency, 1)) as executor:
            futures = [executor.submit(worker, phase, deadline) for _ in range(concurrency)]
            while time.monotonic() < deadline and not stop.is_set():
                sample = {'phase': phase, 'elapsed': round(time.monotonic() - started, 2)}
                for line in ssh(f'sh {base}/resource-sample.sh').splitlines():
                    key, value = line.split('=', 1)
                    sample[key] = float(value)
                results.append(sample)
                if sample['available_kb'] < 65536 or sample['fd'] > 256:
                    guard_hit = True
                    stop.set()
                    print('RESOURCE_GUARD_STOP', flush=True)
                (directory / 'resource-results.json').write_text(json.dumps(
                    {'samples': results, 'aggregates': aggregates, 'guard_stop': guard_hit}))
                print(json.dumps({key: sample[key] for key in
                    ['phase', 'elapsed', 'VmRSS', 'fd', 'available_kb']}), flush=True)
                stop.wait(min(30, max(0, deadline - time.monotonic())))
            for future in futures:
                future.result()
        aggregates[phase]['elapsed'] = round(time.monotonic() - started, 2)
        print('PHASE_END ' + phase + ' ' + json.dumps(aggregates[phase]), flush=True)
        if stop.is_set():
            break
finally:
    stop.set()
    ssh(f'sh {base}/fixture-client.sh stop')
    (directory / 'resource-results.json').write_text(json.dumps(
        {'samples': results, 'aggregates': aggregates, 'guard_stop': guard_hit}))
    print('BENCHMARK_CLIENT_STOPPED', flush=True)
