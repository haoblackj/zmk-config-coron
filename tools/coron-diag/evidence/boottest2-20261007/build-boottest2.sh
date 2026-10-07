#!/usr/bin/env bash
# Build one Coron test image with the boot instrument.
# usage: build-boottest2.sh <builddir-name> <conf-file-under-local/coron-diag> <tag> [extra cmake args]
set -euo pipefail
BD=$1; CONF=$2; TAG=$3; shift 3
cd ~/zmk-dya-build
C=$PWD/config/zmk-config-coron
env -u LD_LIBRARY_PATH nix develop --command bash -c "
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
west build -p -s zmk/app -d .build/$BD -b xiao_ble//zmk -- -DZMK_CONFIG=$C/config \"-DZMK_EXTRA_MODULES=$C;$PWD/local/coron-diag\" -DSHIELD=coron_R -DEXTRA_CONF_FILE=$PWD/local/coron-diag/$CONF -DCORON_BUILD_TAG=$TAG $* > .build/$BD.log 2>&1 || true
ninja -C .build/$BD >> .build/$BD.log 2>&1
"
tail -2 .build/$BD.log
ls -la .build/$BD/zephyr/zmk.uf2 .build/$BD/zephyr/zmk.elf
grep -E "^CONFIG_(CORON_DIAG_BOOT|CORON_DIAG_BOOT_FIX|BOARD_EARLY_INIT_HOOK|SPEED_OPTIMIZATIONS)=" .build/$BD/zephyr/.config
# Record addresses must match across every image used in one run (alternating flashes).
NM=/nix/store/57hybry1spzvsy5ml99wdm6p49hlr3nh-zephyr-sdk-0.16.9/arm-zephyr-eabi/bin/arm-zephyr-eabi-nm
echo "record addresses:"; env -u LD_LIBRARY_PATH $NM -S .build/$BD/zephyr/zmk.elf | grep -E " [bB] (cur|last|ring|arm_next)$" | grep -v " 00000004 "
