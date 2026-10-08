#!/usr/bin/env bash
# Build the right-half PRODUCTION candidate with the boot-entry clean and the breadcrumb:
# the same configuration as .build/R-diag (the image 2725423: snippet studio-rpc-usb-uart,
# modules zmk-config-coron + local/coron-diag) plus prod-entry.conf and diagrec.overlay.
# usage: build-prod-entry.sh <builddir-name>
set -euo pipefail
BD=$1
cd ~/zmk-dya-build
C=$PWD/config/zmk-config-coron
env -u LD_LIBRARY_PATH nix develop --command bash -c "
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
west build -p -s zmk/app -d .build/$BD -b xiao_ble//zmk -S studio-rpc-usb-uart -- -DZMK_CONFIG=$C/config \"-DZMK_EXTRA_MODULES=$C;$PWD/local/coron-diag\" -DSHIELD=coron_R -DEXTRA_CONF_FILE=$PWD/local/coron-diag/prod-entry.conf -DEXTRA_DTC_OVERLAY_FILE=$PWD/local/coron-diag/diagrec.overlay > .build/$BD.log 2>&1 || true
ninja -C .build/$BD >> .build/$BD.log 2>&1
"
tail -2 .build/$BD.log
ls -la .build/$BD/zephyr/zmk.uf2 .build/$BD/zephyr/zmk.elf
grep -E "^CONFIG_(CORON_DIAG_ENTRY|CORON_DIAG_BOOT|BOARD_EARLY_INIT_HOOK|SRAM_SIZE|ZMK_WATCHDOG_FREEZE_DETECT|ZMK_WATCHDOG_FATAL_DETECT|ZMK_STUDIO)=" .build/$BD/zephyr/.config
NM=/nix/store/57hybry1spzvsy5ml99wdm6p49hlr3nh-zephyr-sdk-0.16.9/arm-zephyr-eabi/bin/arm-zephyr-eabi-nm
echo "crumb (must be 2002c000):"; env -u LD_LIBRARY_PATH $NM -S .build/$BD/zephyr/zmk.elf | grep -E " [bBdD] diag_crumb$"
