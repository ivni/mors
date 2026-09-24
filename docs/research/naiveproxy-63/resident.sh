#!/bin/sh
# Short resident-set snapshots only, not an L+1 load/admission gate.
set -eu
D=/opt/tmp/mors-naive63-followup-20260922
cd "$D"
umask 077
B="$D/naive"
case "$1" in
  start)
    case "$2" in 1|2|4|5) n=$2;; *) exit 2;; esac
    [ ! -e resident.pids ]
    : > resident.pids
    i=1
    while [ "$i" -le "$n" ]; do
      SSL_CERT_FILE="$D/root.pem" SSL_CERT_DIR="$D/empty-dir" \
        "$B" "$D/profile$i.json" > "$D/profile$i.log" 2>&1 &
      echo $! >> resident.pids
      i=$((i+1))
    done
    sleep 2
    ;;
  stop)
    while read -r p; do
      [ "$(readlink /proc/$p/exe)" = "$B" ]
      kill -TERM "$p"
    done < resident.pids
    sleep 1
    while read -r p; do [ ! -e "/proc/$p" ]; done < resident.pids
    rm resident.pids
    echo RESIDENT_STOPPED
    exit 0
    ;;
  sample) ;;
  *) exit 2;;
esac
rss=0
fds=0
threads=0
count=0
while read -r p; do
  [ "$(readlink /proc/$p/exe)" = "$B" ]
  value=$(awk '/VmRSS/ {print $2}' "/proc/$p/status")
  rss=$((rss+value))
  value=$(ls /proc/$p/fd | wc -l)
  fds=$((fds+value))
  value=$(awk '/Threads/ {print $2}' "/proc/$p/status")
  threads=$((threads+value))
  count=$((count+1))
done < resident.pids
available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
[ "$available" -ge 65536 ]
echo "processes=$count rss_sum_kb=$rss fd_sum=$fds threads_sum=$threads available_kb=$available"
