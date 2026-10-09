#!/usr/bin/env bash
# unattended: wait for the v7 stimulus to finish, clear the stored records, then run the v8 (fix candidate) campaign
S=/tmp/claude-1000/-home-yagu001-repo-github-com-haoblackj-zmk-workspace/f1edcf4a-4bc3-45f7-a2ec-c1b2a3233983/scratchpad
WW='C:\Users\yagu001\AppData\Local\Temp\coron-flash'
until grep -q 'pnp.txt' $S/lab7-campaign-step4.out 2>/dev/null; do sleep 10; done
sleep 5
echo "$(date +%H:%M:%S) v7 done; clearing records"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WW\\calib\\half-cmd.ps1" -Serial B17318CDBE9A61B1 -Cmd c -LogDir "$WW\\lab8-preclear" 2>&1 | tr -d '\r' | tail -1
echo "$(date +%H:%M:%S) starting v8 campaign"
SKIP_LEFT=1 CYCLES=30 bash $S/lab8-campaign.sh 1
echo "$(date +%H:%M:%S) v8 campaign exit=$?"
