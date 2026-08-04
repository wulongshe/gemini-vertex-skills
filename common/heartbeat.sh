#!/usr/bin/env bash
# Shared heartbeat for long-running generation scripts — source, then:
#   hb_start <label>   start printing "<label>...(Ns)" progress
#   hb_stop            stop it (safe to call more than once)
#
# On a TTY the line refreshes in place every second. When piped (an agent
# polling the output) a new line is printed with a backoff — 5s after start,
# doubling up to one line every 30s — so liveness shows up fast without
# flooding long runs.

hb_start() {
  if [[ -t 1 ]]; then
    ( i=0; while :; do sleep 1; i=$((i+1)); printf '\r%s...(%ds)' "$1" "$i"; done ) &
  else
    ( i=0; d=5; while :; do sleep "$d"; i=$((i+d)); echo "$1...(${i}s)"; d=$(( d*2 > 30 ? 30 : d*2 )); done ) &
  fi
  HB=$!
}

hb_stop() {
  [[ -z "${HB:-}" ]] || kill "$HB" 2>/dev/null || true
  if [[ -t 1 ]]; then printf '\r\033[K'; fi
}
