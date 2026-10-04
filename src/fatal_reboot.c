/*
 * 致命的エラーで止まらず、再起動する。
 *
 * Zephyr の既定は停止（割り込みを止めたまま無限ループ）で、キーボードはリセットボタンを
 * 押すまで無反応になる。右手側は、Bluetooth コントローラが無線の予定を積む行列をあふれさせて
 * 停止することがある（lll_prepare_resolve の LL_ASSERT。2026-10-05 に通常使用中に1回、
 * 割り込みを長く止める診断処理のもとで複数回観測）。再起動なら数秒で復帰する。
 */

#include <zephyr/kernel.h>
#include <zephyr/fatal.h>
#include <zephyr/sys/reboot.h>

void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf) {
    ARG_UNUSED(reason);
    ARG_UNUSED(esf);

    sys_reboot(SYS_REBOOT_WARM);
    CODE_UNREACHABLE;
}
