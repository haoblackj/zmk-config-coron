#!/usr/bin/env bash
# Build a LEFT-half image with the entry clean + breadcrumb: build-left.sh <builddir> <conf1[;conf2]>
set -euo pipefail
BD=$1; CONFS=$2
cd ~/zmk-dya-build
C=$PWD/config/zmk-config-coron
env -u LD_LIBRARY_PATH nix develop --command bash -c "
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
west build -p -s zmk/app -d .build/$BD -b xiao_ble//zmk -- -DZMK_CONFIG=$C/config \"-DZMK_EXTRA_MODULES=$C;$PWD/local/coron-diag\" -DSHIELD=coron_L \"-DEXTRA_CONF_FILE=$CONFS\" -DEXTRA_DTC_OVERLAY_FILE=$PWD/local/coron-diag/diagrec.overlay > .build/$BD.log 2>&1 || true
ninja -C .build/$BD >> .build/$BD.log 2>&1
"
tail -2 .build/$BD.log
ls -la .build/$BD/zephyr/zmk.uf2
grep -E "^CONFIG_(CORON_DIAG_ENTRY|BOARD_EARLY_INIT_HOOK|SRAM_SIZE|SPEED_OPTIMIZATIONS|UART_LINE_CTRL|BT_CTLR_ASSERT_OVERHEAD_START|ZMK_WATCHDOG|ZMK_WATCHDOG_FATAL_DETECT|ZMK_SPLIT_ROLE_CENTRAL)=" .build/$BD/zephyr/.config
NM=/nix/store/57hybry1spzvsy5ml99wdm6p49hlr3nh-zephyr-sdk-0.16.9/arm-zephyr-eabi/bin/arm-zephyr-eabi-nm
echo "crumb (must be 2002c000):"; env -u LD_LIBRARY_PATH $NM -S .build/$BD/zephyr/zmk.elf | grep -E " [bBdD] diag_crumb$"
md5sum .build/$BD/zephyr/zmk.uf2
