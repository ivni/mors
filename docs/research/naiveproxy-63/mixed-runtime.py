"""Bounded 20-minute mixed workload on the Pi; private settings, sanitized output."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

directory = Path(sys.argv[1]).resolve()
settings = json.loads((directory / 'bench-settings.json').read_text())
lock = threading.Lock()
stop = threading.Event()
phases = []
errors = []
for port in [18170, 18171, 18172, 18173, 18174, 18179]:
    config = directory / f'curl-{port}.conf'
    config.write_text(f'proxy = "socks5h://{settings["host"]}:{port}"\n'
                      f'proxy-user = "{settings["user"]}:{settings["password"]}"\n')
    config.chmod(0o600)
query = (bytes.fromhex('123401000001000000000000')
         + b''.join(bytes([len(x)]) + x.encode() for x in 'probe.fixture.invalid'.split('.'))
         + bytes.fromhex('0000010001'))
(directory / 'dns.query').write_bytes(query)
dns_response = (query[:2] + bytes.fromhex('81800001000100000000') + query[12:]
                + bytes.fromhex('c00c000100010000001e0004c612003f'))


def save():
    target = directory / 'mixed-results.json'
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps({'phases': phases, 'errors': errors}))
    temporary.replace(target)


def probe(kind, port, phase):
    command = ['curl', '-sS', '--config', str(directory / f'curl-{port}.conf'),
               '--cacert', str(directory / 'root.pem'), '--connect-timeout', '8',
               '--max-time', '20', '--limit-rate', '64K', '-o', '/dev/null',
               '-w', '%{http_code} %{size_download} %{time_total}']
    if kind == 'dns':
        command[command.index('-o') + 1] = str(directory / 'dns.response')
        command += ['-H', 'Content-Type: application/dns-message',
                    '--data-binary', '@' + str(directory / 'dns.query'),
                    'https://nonce.fixture.invalid:18444/dns-query']
    else:
        command += ['https://nonce.fixture.invalid:18444/bytes']
    started = time.time()
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=24)
        code = result.returncode
        fields = result.stdout.split()
        http, size, elapsed = ((int(fields[0]), int(fields[1]), float(fields[2]))
                               if len(fields) == 3 else (0, 0, time.time() - started))
        reasons = [label for needle, label in [('reset', 'reset'), ('eof', 'eof'),
                   ('broken pipe', 'broken_pipe'), ('timed out', 'timeout'),
                   ('certificate', 'certificate')] if needle in result.stderr.lower()]
    except subprocess.TimeoutExpired:
        code, http, size, elapsed, reasons = 124, 0, 0, time.time() - started, ['driver_timeout']
    dns_ok = (kind != 'dns' or ((directory / 'dns.response').exists()
              and (directory / 'dns.response').read_bytes() == dns_response))
    ok = code == 0 and http == 200 and dns_ok and (size == len(dns_response)
                                                 if kind == 'dns' else size == 262144)
    with lock:
        count = phase['traffic'][kind]
        count['ok' if ok else 'failed'] += 1
        count['latency_max'] = max(count['latency_max'], elapsed)
        if not ok:
            errors.append(dict(started=started, phase=phase['name'], kind=kind,
                               exit=code, http=http, bytes=size, seconds=elapsed, reasons=reasons))
            # Private diagnostic detail is never included in the exported result.
            if code != 124:
                with (directory / 'errors-private.jsonl').open('a') as output:
                    output.write(json.dumps({'started': started, 'stderr': result.stderr}) + '\n')
            save()


def worker(kind, deadline, phase, port):
    index = 0
    while time.monotonic() < deadline and not stop.is_set():
        selected = 18171 + index % 4 if kind == 'standby' else port
        probe(kind, selected, phase)
        index += 1
        stop.wait(15 if kind == 'standby' else 2 if kind == 'dns' else .25)


try:
    for name, concurrency in [('idle', 0), ('load1', 1), ('load8', 8), ('load32', 32)]:
        phase = dict(name=name, concurrency=concurrency, started=time.time(),
                     traffic={kind: dict(ok=0, failed=0, latency_max=0.)
                              for kind in ['naive', 'xray', 'dns', 'standby']})
        phases.append(phase)
        deadline = time.monotonic() + 300
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, concurrency + 3)) as pool:
            futures = []
            if concurrency:
                futures = [pool.submit(worker, 'naive', deadline, phase, 18170)
                           for _ in range(concurrency)]
                futures += [pool.submit(worker, kind, deadline, phase, port)
                            for kind, port in [('xray', 18179), ('dns', 18170), ('standby', 18171)]]
            while time.monotonic() < deadline:
                time.sleep(min(30, max(0, deadline - time.monotonic())))
                with lock:
                    save()
                    print(json.dumps(phase), flush=True)
            for future in futures:
                future.result()
        phase['ended'] = time.time()
        save()
finally:
    stop.set()
    save()
