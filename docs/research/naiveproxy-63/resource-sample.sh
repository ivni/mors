#!/bin/sh
set -eu
D=/opt/tmp/mors-naive63-followup-20260922
p=$(cat "$D/active.pid")
[ "$(readlink /proc/$p/exe)" = "$D/naive" ]
awk '/VmRSS|VmHWM|Threads/ {gsub(":", "", $1); print $1 "=" $2}' "/proc/$p/status"
printf 'fd='; ls "/proc/$p/fd" | wc -l
awk '/MemAvailable/ {print "available_kb=" $2}' /proc/meminfo
awk '{print "process_ticks=" $14+$15}' "/proc/$p/stat"
awk '/^cpu / {for(i=2;i<=9;i++) n+=$i; printf "machine_ticks=%.0f\n", n}' /proc/stat
awk '{print "uptime=" $1}' /proc/uptime
if [ -r "/proc/$p/smaps" ]; then
  awk '/^Pss:/ {n+=$2} END {print "pss_kb=" n}' "/proc/$p/smaps"
fi
