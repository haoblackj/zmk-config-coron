#!/usr/bin/env bash
# Lab image v3 campaign (2026-10-09 evening): production interrupt layout, assert off, the controller's
# scheduling steps recorded. One write per half, then the reconnect stimulus only (no flash writes).
#   1. write v3 to the right half (one write), check 'ZDIAG lab live v3', clear
#   2. right self-tests: 'A' (assert path -> reboot -> crash0 kind=assert line=4242 file=selftest, text
#      captured, checksum ok; then the same-file rewrite through the bootloader keeps it), then 'M'
#      (late-prepare path, no reboot -> a kind=late record with line=238 late=4242); clear
#   3. the same for the left half
#   4. stimulus: recon-loop.ps1 -StopOnRecord:$false, 50 PC reconnects; records are taken without
#      reboots, the loop stops only on a reboot/stage change
#   5. capture: watchdog store, both dumps, Windows PnP log
# usage: lab3-campaign.sh <step-from> (1..4); SKIP_LEFT=1 skips step 3; CYCLES=n (default 50)
set -u
W=/mnt/c/Users/yagu001/AppData/Local/Temp/coron-flash
WW='C:\Users\yagu001\AppData\Local\Temp\coron-flash'
S=/tmp/claude-1000/-home-yagu001-repo-github-com-haoblackj-zmk-workspace/f1edcf4a-4bc3-45f7-a2ec-c1b2a3233983/scratchpad
E=$HOME/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/prod-entry-20261009/wdlog
RSER=B17318CDBE9A61B1; LSER=743A486E04021F9D
RUF2=coron_R-lab3.uf2; LUF2=coron_L-lab3.uf2
RMD5=$(md5sum $W/$RUF2 | cut -d' ' -f1); LMD5=$(md5sum $W/$LUF2 | cut -d' ' -f1)
from=${1:-1}; CYCLES=${CYCLES:-50}
ps() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$@" 2>&1 | tr -d '\r'; }
say() { echo "$(date +%H:%M:%S) $*"; }
dump_of() { cat "$1"/*-io*.out 2>/dev/null | tr -d '\r'; }

flash_half() { # serial uf2 md5 logdir -> 0 if the write went through (the post-flash dump check may be
               # incomplete on its own: the v3 dump is longer than the flash script's read window)
    local o
    o=$(ps "$WW\\calib\\calib-flash.ps1" -Serial "$1" -LogDir "$WW\\$4" -Uf2 "$WW\\$2" -Md5 "$3" -Expect prod)
    echo "$o" | grep -E 'RESULT|FAIL' | cut -c1-160
    if echo "$o" | grep -q 'RESULT PASS'; then return 0; fi
    if echo "$o" | grep -q 'RESULT FAIL (1 failed checks)' && echo "$o" | grep -q 'FAIL after flash:dump complete'; then
        say "flash: only the post-flash dump read was incomplete; verifying with a full read"; return 0
    fi
    return 1
}
read_half() { # serial logdir -> prints dump lines of interest
    ps "$WW\\calib\\half-io.ps1" -Serial "$1" -LogDir "$WW\\$2" | grep -E 'ZDIAG (begin|crumb|lab live|lab crash[0-9] |lab crash[0-9]pk|lab end|end)' | cut -c1-200
}
send_cmd() { # serial cmd logdir
    ps "$WW\\calib\\half-cmd.ps1" -Serial "$1" -Cmd "$2" -LogDir "$WW\\$3" | tail -3
}
selftest() { # serial logdir-prefix
    local ser=$1 pre=$2 d
    say "self-test on $ser: send A (assert path, reboots)"
    send_cmd "$ser" A "$pre-A"
    sleep 12
    say "self-test on $ser: read the next boot's dump"
    read_half "$ser" "$pre-after" | grep -E 'lab live|crash0 |crash0pk' | cut -c1-200
    d=$(dump_of "$W/$pre-after")
    if echo "$d" | grep -q 'ZDIAG lab crash0 .*kind=assert line=4242 file=selftest.*sum=ok' && echo "$d" | grep -q 'crash0pk .*Actual EVENT_OVERHEAD_START_US = 4242'; then
        say "self-test on $ser: PASS (assert record survived the reboot, text captured, checksum ok)"
    else
        say "self-test on $ser: FAIL (assert path)"; return 1
    fi
    local uf2 md5
    if [ "$ser" = "$RSER" ]; then uf2=$RUF2; md5=$RMD5; else uf2=$LUF2; md5=$LMD5; fi
    say "self-test on $ser: same-file rewrite through the bootloader, then re-read"
    flash_half "$ser" "$uf2" "$md5" "$pre-rewrite" || { say "self-test on $ser: FAIL (rewrite did not go through)"; return 1; }
    read_half "$ser" "$pre-rewrite-read" | grep -E 'crumb|lab live|crash0 ' | cut -c1-200
    d=$(dump_of "$W/$pre-rewrite-read")
    if echo "$d" | grep -q 'ZDIAG lab crash0 .*kind=assert line=4242 file=selftest.*sum=ok'; then
        say "self-test on $ser: PASS (record survived the bootloader pass too)"
    else
        say "self-test on $ser: FAIL (record lost or corrupted across the bootloader pass)"; return 1
    fi
    say "self-test on $ser: send M (late-prepare path, no reboot)"
    send_cmd "$ser" M "$pre-M"
    sleep 3
    read_half "$ser" "$pre-M-read" | grep -E 'crumb|lab live|crash1 ' | cut -c1-200
    d=$(dump_of "$W/$pre-M-read")
    if echo "$d" | grep -q 'ZDIAG lab crash1 .*kind=late line=238 file=late .*late=4242 .*sum=ok'; then
        say "self-test on $ser: PASS (late-prepare record taken without a reboot, checksum ok)"
    else
        say "self-test on $ser: FAIL (late-prepare path)"; return 1
    fi
    send_cmd "$ser" c "$pre-clear" >/dev/null
    return 0
}
stop_capture() { # label: watchdog store + both dumps + PnP export
    local lb=$1; mkdir -p "$S/lab3-$lb"
    say "capture at $lb: watchdog store"
    bash $E/studio-rpc.sh "$S/lab3-$lb/wd-list.txt" "08 09 a2 06 08 12 06 08 02 12 02 12 00" 4 >/dev/null; python3 $E/pb-decode.py "$S/lab3-$lb/wd-list.txt" | head -80 > "$S/lab3-$lb/wd-list.decoded.txt"
    say "capture at $lb: dumps"
    read_half "$RSER" "lab3-$lb-R" >/dev/null; read_half "$LSER" "lab3-$lb-L" >/dev/null
    say "capture at $lb: Windows PnP log (last 24 h)"
    powershell.exe -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap | Out-String -Width 400" 2>/dev/null | tr -d '\r' > "$S/lab3-$lb/pnp.txt"
    wc -l "$S/lab3-$lb/pnp.txt"
}

if [ "$from" -le 1 ]; then
    say "step 1: write v3 to R ($RMD5)"
    flash_half "$RSER" $RUF2 "$RMD5" lab3-flashR || exit 1
    read_half "$RSER" lab3-R0 | grep -E 'crumb|lab live v3' || { say "no 'lab live v3' in the first dump"; exit 1; }
    send_cmd "$RSER" c lab3-R0-clear >/dev/null
fi
if [ "$from" -le 2 ]; then
    say "step 2: right self-tests"; selftest "$RSER" lab3-selfR || exit 1
fi
if [ "$from" -le 3 ] && [ "${SKIP_LEFT:-0}" != 1 ]; then
    say "step 3: write v3 to L ($LMD5) and self-test"
    flash_half "$LSER" $LUF2 "$LMD5" lab3-flashL || exit 1
    read_half "$LSER" lab3-L0 | grep -E 'crumb|lab live v3' || { say "no 'lab live v3' in the left's first dump"; exit 1; }
    send_cmd "$LSER" c lab3-L0-clear >/dev/null
    selftest "$LSER" lab3-selfL || exit 1
fi
if [ "$from" -le 4 ]; then
    say "step 4: reconnect stimulus, $CYCLES cycles, records do not stop it"
    (cd $W && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WW\\calib\\recon-loop.ps1" -RunDir "$WW\\lab3-recon" -Cycles $CYCLES -WaitSec 30 -StopOnRecord:\$false > $S/lab3-recon.out 2>&1); rc=$?
    tail -n 3 $W/lab3-recon/summary.log | cut -c1-240
    say "recon loop ended (rc=$rc): capture and END"; stop_capture recon-end; exit $rc
fi
