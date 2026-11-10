#!/bin/bash
# Run in a fresh shared directory after publishing ready-$role atomically.
set -euo pipefail
waitio_role=${1:?Usage: wait-peer.sh c|g timeout-seconds}
waitio_timeout=${2:-600}
case "$waitio_role" in c) waitio_peer=g ;; g) waitio_peer=c ;; *) exit 2 ;; esac
[[ "$waitio_timeout" =~ ^[0-9]+$ ]] || exit 2
waitio_deadline=$((SECONDS + waitio_timeout))
while true; do
  if [[ -f "exit-$waitio_peer.txt" ]]; then
    echo "Peer $waitio_peer exited before rendezvous: $(cat "exit-$waitio_peer.txt")" >&2
    exit 1
  fi
  if [[ -s "ready-$waitio_peer" && -s "capabilities-$waitio_peer.toml" ]]; then
    break
  fi
  if (( SECONDS >= waitio_deadline )); then
    echo "Timed out waiting for peer $waitio_peer configuration" >&2
    exit 1
  fi
  sleep 1
done
printf 'peer_ready=%s\n' "$waitio_peer"
