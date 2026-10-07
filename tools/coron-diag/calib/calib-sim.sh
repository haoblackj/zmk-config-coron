#!/usr/bin/env bash
# Runs every mock scenario through the real PowerShell scripts (Windows PowerShell 5.1 via
# powershell.exe, scripts and logs on the WSL side through their UNC path). No device is touched:
# mock mode never calls Get-PnpDevice, CIM, SerialPort or Copy-Item.
# Prints, per scenario: the verdict line(s), what was stopped before, and every DEVICE-OP that
# the script would have performed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/gen-scenarios.py" >/dev/null
LOGS="$HERE/sim-logs/$(date +%m%d-%H%M%S)"; mkdir -p "$LOGS"
W() { wslpath -w "$1"; }
SERIAL=B17318CDBE9A61B1
COMMON=(-Serial $SERIAL -Uf2Base 'C:\T\coron_R-bt4.uf2' -Md5Base df108d7ad2009afccfbfbba66b6ad093 -Uf2Alt 'C:\T\coron_R-bt4-alt.uf2' -Md5Alt e1e62efeeda0f87a1678a3d53f8151cf -Uf2Prod 'C:\T\coron_R-prod-2725423.uf2' -Md5Prod 889f3a4816c82bdd4adc253b16f28689)
ps() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$@" 2>&1 | tr -d '\r' || true; }
report() { # $1 = log dir
  grep -h -E "RESULT|STOPPED before|DEVICE-OP|^.{12} (CALIBRATION|restore|results:)|NOTE reset|SKIP" "$1"/*.log | sed -E 's/^[0-9:.]+ //' | sed 's/^/    /'
}
echo "=== normal (full run through calib-all.ps1)"
mkdir -p "$LOGS/normal"
ps "$(W "$HERE/calib-all.ps1")" "${COMMON[@]}" -LogDir "$(W "$LOGS/normal")" -MockDir "$(W "$HERE/sim/normal")" >/dev/null
report "$LOGS/normal"
run_step() { # scenario step
  local sc=$1 st=$2; mkdir -p "$LOGS/$sc"
  echo "=== $sc (calib-run -Step $st)"
  ps "$(W "$HERE/calib-run.ps1")" -Step "$st" "${COMMON[@]}" -LogDir "$(W "$LOGS/$sc")" -Mock "$(W "$HERE/sim/$sc/$st.json")" >/dev/null
  report "$LOGS/$sc"
}
run_flash() { # scenario expect
  local sc=$1 ex=$2; mkdir -p "$LOGS/$sc"
  echo "=== $sc (calib-flash -Expect $ex)"
  if [ "$ex" = prod ]; then F='C:\T\coron_R-prod-2725423.uf2'; M=889f3a4816c82bdd4adc253b16f28689; else F='C:\T\coron_R-bt4.uf2'; M=df108d7ad2009afccfbfbba66b6ad093; fi
  ps "$(W "$HERE/calib-flash.ps1")" -Serial $SERIAL -LogDir "$(W "$LOGS/$sc")" -Uf2 "$F" -Md5 $M -Expect $ex -Mock "$(W "$HERE/sim/$sc/flash-$ex.json")" >/dev/null
  report "$LOGS/$sc"
}
run_step trunc 0
run_step missing-end 1
run_step missing-field 1
run_step no-dump 1
run_step early-reset 2
run_step no-reset 2
run_step foreign-uf2 7
run_step two-uf2 7
run_step copy-fail 7
run_step copy-not-taken 7
run_step prod-missing pre
run_step prod-md5 pre
run_flash prod-md5 prod
run_step inc-changed 7
run_step inc-missing-line 7
run_flash prod-still-test prod
echo "=== done; logs in $LOGS"
