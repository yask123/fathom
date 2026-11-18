#!/bin/zsh
# Scroll benchmark of the Code tab: tools/bench.sh out.json [VAR=value ...]
# Runs build/Tracer.app as its own process with FATHOM_SCROLLBENCH set, brings it to the front (a hidden window
# doesn't draw), waits for it to scroll by itself and quit, and prints what it measured.
# e.g. tools/bench.sh /tmp/bench.json FATHOM_HOME=/tmp/home "FATHOM_OPEN=owner/repo#12" FATHOM_NO_AI=1
set -euo pipefail
cd "${0:A:h}/.."
out=$1; shift
rm -f "$out"
pkill -f "$PWD/build/Tracer.app/Contents/MacOS/Tracer" 2>/dev/null && sleep 0.6 || true
env FATHOM_SCROLLBENCH=${BENCH_SPEEDS:-2400,7000} FATHOM_BENCH_OUT="$out" FATHOM_NO_PREFETCH=1 FATHOM_NO_HOVER=1 FATHOM_MUTE=1 \
    FATHOM_WINDOW=${BENCH_WINDOW:-1500x950} "$@" "$PWD/build/Tracer.app/Contents/MacOS/Tracer" >/dev/null 2>&1 &
pid=$!
for i in {1..120}; do
  sleep 0.25
  [[ -f "$out" ]] && break
  kill -0 $pid 2>/dev/null || break
  (( i < 16 )) && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
done
wait $pid 2>/dev/null || true
cat "$out" 2>/dev/null || echo '{"error":"no result"}'
echo
