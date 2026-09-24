#!/bin/sh
# Only for the explicitly verified disposable router; never invoke on a host.
set -eu
D=/opt/tmp/mors-naive63-followup-20260922
B="$D/naive"
cd "$D"
umask 077
case "$1" in
  prepare)
    chmod 700 "$B"
    [ "$(sha256sum "$B" | cut -d ' ' -f1)" = 25531478648e9b586af7f85f5188e20151cc0a0f77940a2926d86658d5eaef95 ]
    mkdir empty-dir
    ip -4 rule > rules.before
    ip -4 route show table all > routes.before
    "$B" --version
    ;;
  start)
    name=$2
    case "$name" in valid|empty|missing|wrong-name|expired|incomplete|full-chain|unknown|bad-auth|bad-dns|public|load) ;; *) exit 2;; esac
    [ ! -e active.pid ]
    ca="$D/root.pem"
    [ "$name" != empty ] || ca="$D/empty.pem"
    [ "$name" != missing ] || ca="$D/missing.pem"
    SSL_CERT_FILE="$ca" SSL_CERT_DIR="$D/empty-dir" "$B" "$D/$name.json" > "$D/$name.log" 2>&1 &
    p=$!
    echo "$p" > active.pid
    sleep 1
    [ "$(readlink /proc/$p/exe)" = "$B" ]
    echo STARTED
    ;;
  stop)
    p=$(cat active.pid)
    [ "$(readlink /proc/$p/exe)" = "$B" ]
    kill -TERM "$p"
    sleep 1
    [ ! -e /proc/$p ]
    rm active.pid
    echo STOPPED
    ;;
  snapshot)
    p=$(cat active.pid)
    [ "$(readlink /proc/$p/exe)" = "$B" ]
    awk '/VmRSS|VmHWM|Threads/ {print}' "/proc/$p/status"
    printf 'fd='; ls "/proc/$p/fd" | wc -l
    ;;
  *) exit 2;;
esac
