#!/usr/bin/env bash
# Two-pass build of the lab recording image for the RIGHT half (prod-entry-lab.conf, v6+):
#   pass 1: normal build; read the RAM addresses of lll.c's static preempt bookkeeping with nm
#   pass 2: rebuild with those addresses as LAB_ADDR_* defines (CMakeLists.txt); check with nm that
#           they did not move (the RAM layout does not depend on code constants)
# usage: build-lab-2pass.sh <builddir-name> [extra conf files, ';'-separated; default prod-entry-lab.conf]
set -euo pipefail
BD=$1
cd ~/zmk-dya-build
C=$PWD/config/zmk-config-coron
CONFS=${2:-$PWD/local/coron-diag/prod-entry-lab.conf}
NM=/nix/store/57hybry1spzvsy5ml99wdm6p49hlr3nh-zephyr-sdk-0.16.9/arm-zephyr-eabi/bin/arm-zephyr-eabi-nm
build() { # extra cmake args
    env -u LD_LIBRARY_PATH nix develop --command bash -c "
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
west build -p -s zmk/app -d .build/$BD -b xiao_ble//zmk -S studio-rpc-usb-uart -- -DZMK_CONFIG=$C/config \"-DZMK_EXTRA_MODULES=$C;$PWD/local/coron-diag\" -DSHIELD=coron_R \"-DEXTRA_CONF_FILE=$CONFS\" -DEXTRA_DTC_OVERLAY_FILE=$PWD/local/coron-diag/diagrec.overlay $* > .build/$BD.log 2>&1 || true
ninja -C .build/$BD >> .build/$BD.log 2>&1
"
}
addrs() { # prints name=0x.. for the seven symbols
    env -u LD_LIBRARY_PATH $NM .build/$BD/zephyr/zmk.elf | awk '
        / b preempt_req$/{print "REQ=0x"$1} / b preempt_ack$/{print "ACK=0x"$1}
        / b preempt_start_req$/{print "START_REQ=0x"$1} / b preempt_start_ack$/{print "START_ACK=0x"$1}
        / b preempt_stop_req$/{print "STOP_REQ=0x"$1} / b preempt_stop_ack$/{print "STOP_ACK=0x"$1}
        / b ticks_at_preempt[.0-9]*$/{print "TICKS=0x"$1}' | sort
}
# pass 1 carries placeholder addresses so that everything the defines bring in (the DWT hit ring
# of diag_lab_dwt.c) is already laid out; only the constants differ in pass 2
D0="-DLAB_ADDR_PREEMPT_REQ=0x20000000 -DLAB_ADDR_PREEMPT_ACK=0x20000001 -DLAB_ADDR_PREEMPT_START_REQ=0x20000002 -DLAB_ADDR_PREEMPT_START_ACK=0x20000003 -DLAB_ADDR_PREEMPT_STOP_REQ=0x20000004 -DLAB_ADDR_PREEMPT_STOP_ACK=0x20000005 -DLAB_ADDR_TICKS_AT_PREEMPT=0x20000008"
echo "pass 1"; build $D0; A1=$(addrs); echo "$A1"
[ "$(echo "$A1" | wc -l)" = 7 ] || { echo "pass 1: not all seven symbols found"; exit 1; }
eval "$(echo "$A1" | sed 's/^/P1_/')"
echo "pass 2"; build -DLAB_ADDR_PREEMPT_REQ=$P1_REQ -DLAB_ADDR_PREEMPT_ACK=$P1_ACK -DLAB_ADDR_PREEMPT_START_REQ=$P1_START_REQ -DLAB_ADDR_PREEMPT_START_ACK=$P1_START_ACK -DLAB_ADDR_PREEMPT_STOP_REQ=$P1_STOP_REQ -DLAB_ADDR_PREEMPT_STOP_ACK=$P1_STOP_ACK -DLAB_ADDR_TICKS_AT_PREEMPT=$P1_TICKS
A2=$(addrs)
if [ "$A1" != "$A2" ]; then echo "pass 2: the addresses moved"; echo "$A2"; exit 1; fi
echo "addresses unchanged across the passes"
tail -2 .build/$BD.log
grep -c 'LAB_ADDR_PREEMPT_REQ' .build/$BD/build.ninja >/dev/null && echo "defines in build.ninja: yes"
ls -la .build/$BD/zephyr/zmk.uf2 .build/$BD/zephyr/zmk.elf
grep -E "^CONFIG_(CORON_DIAG_LAB|BT_CTLR_ASSERT_OVERHEAD_START|ZERO_LATENCY_IRQS|SRAM_SIZE)=" .build/$BD/zephyr/.config
echo "crumb (must be 2002c000):"; env -u LD_LIBRARY_PATH $NM -S .build/$BD/zephyr/zmk.elf | grep -E " [bBdD] diag_crumb$"
md5sum .build/$BD/zephyr/zmk.uf2
