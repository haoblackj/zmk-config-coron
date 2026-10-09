#!/usr/bin/env bash
# Production image (2026-10-09 evening): the shield's own config + prod-entry.conf (boot-entry clean,
# NO breadcrumb, NO diagrec.overlay: full 256 KB RAM). Right: studio-rpc-usb-uart snippet.
# Left: + left-console.conf (line control for the console's 'b').
# usage: build-prod.sh <builddir-name> <R|L>
set -euo pipefail
BD=$1; H=$2
cd ~/zmk-dya-build
C=$PWD/config/zmk-config-coron
if [ "$H" = R ]; then SN="-S studio-rpc-usb-uart"; SH=coron_R; CONFS=$PWD/local/coron-diag/prod-entry.conf; else SN=""; SH=coron_L; CONFS="$PWD/local/coron-diag/prod-entry.conf;$PWD/local/coron-diag/left-console.conf"; fi
env -u LD_LIBRARY_PATH nix develop --command bash -c "
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
west build -p -s zmk/app -d .build/$BD -b xiao_ble//zmk $SN -- -DZMK_CONFIG=$C/config \"-DZMK_EXTRA_MODULES=$C;$PWD/local/coron-diag\" -DSHIELD=$SH \"-DEXTRA_CONF_FILE=$CONFS\" > .build/$BD.log 2>&1 || true
ninja -C .build/$BD >> .build/$BD.log 2>&1
"
tail -2 .build/$BD.log
grep -E "^CONFIG_(CORON_DIAG_ENTRY|CORON_DIAG_ENTRY_CRUMB|CORON_DIAG_LAB|BOARD_EARLY_INIT_HOOK|SRAM_SIZE|BT_CTLR_ASSERT_OVERHEAD_START|ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING|ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_PROXY|ZERO_LATENCY_IRQS|ZMK_WATCHDOG_FATAL_DETECT|ZMK_STUDIO)=" .build/$BD/zephyr/.config
grep -E "CORON_DIAG_ENTRY_CRUMB|BATTERY_LEVEL_FETCHING|ASSERT_OVERHEAD_START|CORON_DIAG_LAB" .build/$BD/zephyr/.config | grep 'is not set' || true
NM=/nix/store/57hybry1spzvsy5ml99wdm6p49hlr3nh-zephyr-sdk-0.16.9/arm-zephyr-eabi/bin/arm-zephyr-eabi-nm
echo "crumb symbol (must be absent):"; env -u LD_LIBRARY_PATH $NM .build/$BD/zephyr/zmk.elf | grep -E ' diag_crumb$' || echo "  none"
env -u LD_LIBRARY_PATH $NM .build/$BD/zephyr/zmk.elf | grep -E ' (board_early_init_hook|peripheral_battery_levels)$' || true
md5sum .build/$BD/zephyr/zmk.uf2
