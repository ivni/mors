#!/usr/bin/env bash
set -euo pipefail

# Run after scripts/qa/rust.sh. Root is required to test both allowed and denied
# peers; silently skipping those tests is not sufficient for this gate.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
if [ "$(id -u)" -ne 0 ]; then
    echo "read-api I/O gate requires an isolated Linux root test environment" >&2
    exit 1
fi
mapfile -t binaries < <(find target/debug/deps -maxdepth 1 -type f -name 'local_api-*' -executable)
if [ "${#binaries[@]}" -ne 1 ]; then
    echo "Expected exactly one compiled local_api test binary" >&2
    exit 1
fi
"${binaries[0]}"
trace="$(mktemp)"
trap 'rm -f "$trace"' EXIT
strace -f -qq -yy -s 128 -o "$trace" \
    -e trace=%file,%network,write,writev,fsync,fdatasync,ftruncate \
    "${binaries[0]}" --exact root_roundtrip_all_operations_and_no_reader_filesystem_writes --nocapture
python3 - "$trace" <<'PY'
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
begin = next(i for i, line in enumerate(lines) if "MORS72_READ_BEGIN" in line)
end = next(i for i, line in enumerate(lines) if "MORS72_READ_END" in line)
assert end > begin
allowed = {"socket", "connect", "accept4", "accept", "getsockopt", "setsockopt", "sendto", "recvfrom", "shutdown"}
count = 0
for line in lines[begin + 1:end]:
    match = re.match(r"\d+\s+(\w+)\(", line)
    resumed = re.match(r"\d+\s+<\.\.\. (\w+) resumed>", line)
    if not match:
        assert resumed and resumed[1] in allowed | {"write"}, line
        continue
    name = match[1]
    if name in {"write", "sendto"}:
        assert "UNIX-STREAM" in line, line
        count += 1
    else:
        assert name in allowed, line  # rejects every file access and durable write
    if name == "socket":
        assert "AF_UNIX" in line, line  # no network probes
assert count >= 100, count
print(f"PASS: {count} socket writes; no filesystem access, durable writes or network probes in reader window")
PY
