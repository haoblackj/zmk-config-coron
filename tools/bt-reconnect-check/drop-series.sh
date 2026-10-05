#!/usr/bin/env bash
# Reconnection series for the diag-min aid. For each drop: wait until the host link is up and
# settled, drop it, then poll until it is back, and report how many attempts failed (0x3e).
# usage: drop-series.sh <tag> <count>
set -u
S="$(cd "$(dirname "$0")" && pwd)"
tag=$1
n=${2:-20}
state() { bash "$S/min-cmd.sh" "$S/s2-$tag.txt" "${1:-}" >/dev/null 2>&1; python3 "$S/min-parse.py" "$S/s2-$tag.txt"; }
field() { sed -n "s/.*\b$2=\([^ ]*\).*/\1/p" <<<"$1"; }
for i in $(seq 1 "$n"); do
    # wait for a settled host link before dropping it
    ok=0
    for _ in $(seq 1 40); do
        st=$(state)
        if [[ "$(field "$st" host)" == up ]]; then ok=1; break; fi
        sleep 6
    done
    if ((ok == 0)); then echo "DROP $tag #$i: SKIPPED host link never came up ($st)"; continue; fi
    sleep 6
    state x > /dev/null
    back=""
    for _ in $(seq 1 40); do
        sleep 6
        st=$(state)
        if [[ "$(field "$st" host)" == up && "$(field "$st" stable_ms)" -ge 3000 ]]; then back=1; break; fi
    done
    echo "DROP $tag #$i: failed=$(field "$st" failed) back_ms=$(field "$st" back_ms) other=$(field "$st" other) left=$(field "$st" left) interval=$(field "$st" interval)${back:+}$([[ -z "$back" ]] && echo ' NOT-BACK')"
done
echo "SERIES-DONE $tag"
