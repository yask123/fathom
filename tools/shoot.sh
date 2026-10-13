#!/bin/zsh
# QA screenshot of a test instance of Fathom: tools/shoot.sh out.png [VAR=value ...]
# Runs build/Fathom.app as its own process and only ever touches that process, so a Fathom you're using stays put.
# e.g. tools/shoot.sh /tmp/overview.png FATHOM_OPEN=yask123/walkai#49 FATHOM_HOME=/tmp/fathom-home
set -euo pipefail
cd "${0:A:h}/.."
out=$1; shift
mkdir -p build/tmp
[[ -x build/tmp/winid && build/tmp/winid -nt tools/winid.swift ]] || swiftc -O tools/winid.swift -o build/tmp/winid
pkill -f "$PWD/build/Fathom.app/Contents/MacOS/Fathom" 2>/dev/null && sleep 0.6 || true
env "$@" "$PWD/build/Fathom.app/Contents/MacOS/Fathom" >/dev/null 2>&1 &
pid=$!
for i in {1..60}; do
  sleep 0.25
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
  id=$(build/tmp/winid --pid $pid 2>/dev/null) && break
done
sleep ${SHOOT_WAIT:-3}
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
sleep 0.5
id=$(build/tmp/winid --pid $pid)
screencapture -l"$id" -o -x "$out"
echo "$out (window $id, pid $pid)"
