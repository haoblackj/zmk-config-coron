#!/usr/bin/env bash
# Watch the overnight production loop: emit each new summary.log line, a notice when a stage is silent
# past its deadline (+90 s), and the exit of the loop process.
L=$(cat /tmp/claude-1000/-home-yagu001-repo-github-com-haoblackj-zmk-workspace/f1edcf4a-4bc3-45f7-a2ec-c1b2a3233983/scratchpad/prod-loop-dir.txt)
summary() { tr -d '\r' < "$L/summary.log" 2>/dev/null | sed 's/^\xef\xbb\xbf//'; }
n=$(summary | wc -l); quiet=0
echo "watch armed $(date +%H:%M:%S), summary lines so far=$n, last: $(summary | tail -n 1 | cut -c1-100)"
while true; do
  cur=$(summary | wc -l)
  if [ "$cur" -gt "$n" ]; then summary | sed -n "$((n+1)),${cur}p" | grep -v ' dwell ' ; n=$cur; quiet=0; fi
  last=$(summary | tail -n 1)
  ts=${last%% *}
  lastsec=$(date -d "${ts%.*}" +%s 2>/dev/null || date +%s)
  now=$(date +%s); age=$((now-lastsec))
  allowed=300
  if [[ "$last" =~ \(deadline\ ([0-9]+)s\) ]]; then allowed=$(( ${BASH_REMATCH[1]} + 90 )); fi
  if [ "$age" -gt "$allowed" ] && [ "$quiet" -eq 0 ]; then
    echo "STALL? summary silent for ${age}s, allowed ${allowed}s for: $last ($(date +%H:%M:%S))"; quiet=1
  fi
  if ! pgrep -f 'prod-loop[.]ps1' >/dev/null; then
    echo "loop process exited $(date +%H:%M:%S)"; summary | tail -n 3; break
  fi
  sleep 60   # read rarely: a read overlapping the loop's append makes the Windows side throw
done
