/*
 * Lab image only (v7, 2026-10-09): catch the writer of one byte in RAM with the Cortex-M4's data
 * watchpoint unit, without a debugger. v6 showed that lll.c's preempt_req is set to 0 at a PC
 * disconnect while no code in lll.c writes 0 there (only ++ and "= preempt_ack"), i.e. something
 * else writes that address. DWT comparator 0 watches writes to LAB_ADDR_PREEMPT_REQ (the two-pass
 * build's address) and raises the DebugMonitor exception (DEMCR.MON_EN; it works with no debugger
 * attached, CoreDebug C_DEBUGEN = 0). The handler records the stacked PC/LR/xPSR (the write site:
 * a watchpoint is imprecise by one or two instructions), the value found at the address, the
 * current time and whether the exception was taken late (a write from a handler at the same
 * priority as the monitor is pended until that handler returns; then the stacked PC is where it
 * returned to, and the ISR trace says which handler ran).
 * Zephyr's z_arm_debug_monitor is weak (fault_s.S), replaced here.
 */
#include <stdint.h>
#include <string.h>

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <cmsis_core.h>

#include "diag_lab.h"

#if defined(LAB_ADDR_PREEMPT_REQ)

#define DWT_HITS 64

struct dwt_hit {
    uint32_t t_us;
    uint32_t pc;
    uint32_t lr;
    uint32_t xpsr;   /* of the interrupted context (IPSR in bits 8..0) */
    uint8_t value;   /* *LAB_ADDR_PREEMPT_REQ after the write */
    uint8_t ack;     /* *LAB_ADDR_PREEMPT_ACK at that moment */
    uint8_t ipsr;    /* of the monitor itself (always 12) */
    uint8_t late;    /* 1 = the stacked frame is not the writer (exception was pended) */
    uint32_t dfsr;
};

static struct {
    uint32_t n;
    uint32_t zero_n; /* hits that found the value 0 */
    struct dwt_hit ring[DWT_HITS];
} hits;

void lab_dwt_hit(uint32_t *frame, uint32_t exc_return) {
    struct dwt_hit h;

    ARG_UNUSED(exc_return);
    h.t_us = diag_lab_now_us();
    h.lr = frame[5];
    h.pc = frame[6];
    h.xpsr = frame[7];
    h.value = *(volatile uint8_t *)LAB_ADDR_PREEMPT_REQ;
    h.ack = *(volatile uint8_t *)LAB_ADDR_PREEMPT_ACK;
    h.ipsr = (uint8_t)__get_IPSR();
    h.dfsr = SCB->DFSR;
    /* pended: the monitor could not preempt the writer (same or higher priority); the writer was
     * an exception handler whose frame is not this one (DEMCR.MON_PEND is set by the DWT when the
     * event cannot be taken at once) */
    h.late = (uint8_t)((CoreDebug->DEMCR & CoreDebug_DEMCR_MON_PEND_Msk) ? 1u : 0u);
    hits.ring[hits.n % DWT_HITS] = h;
    hits.n++;
    if (h.value == 0u) {
        hits.zero_n++;
    }
    SCB->DFSR = SCB_DFSR_DWTTRAP_Msk; /* write-one-to-clear */
    CoreDebug->DEMCR &= ~CoreDebug_DEMCR_MON_PEND_Msk;
    __DSB();
    __ISB();
}

/* the DebugMonitor exception: r0 = the stacked frame (MSP or PSP by EXC_RETURN bit 2), r1 = EXC_RETURN */
__attribute__((naked)) void z_arm_debug_monitor(void) {
    __asm volatile(
        "tst lr, #4\n"
        "ite eq\n"
        "mrseq r0, msp\n"
        "mrsne r0, psp\n"
        "mov r1, lr\n"
        "push {r4, lr}\n"
        "bl lab_dwt_hit\n"
        "pop {r4, pc}\n");
}

static int lab_dwt_init(void) {
    memset(&hits, 0, sizeof(hits));
    /* DebugMonitor at the highest priority the kernel leaves to interrupts (0): precise for writers
     * at lower priority (the ticker job, threads); pended for writers at priority 0 (RADIO, SWI4) */
    NVIC_SetPriority(DebugMonitor_IRQn, 0);
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->COMP0 = LAB_ADDR_PREEMPT_REQ;
    DWT->MASK0 = 0; /* exact address */
    DWT->FUNCTION0 = 0; /* disabled while programming */
    __DSB();
    DWT->FUNCTION0 = 0x6; /* watchpoint on write, debug event -> DebugMonitor */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_MON_EN_Msk;
    __DSB();
    __ISB();
    return 0;
}
SYS_INIT(lab_dwt_init, APPLICATION, 98);

void diag_lab_dwt_print(void (*out)(const char *fmt, ...), uint32_t t_ref) {
    uint32_t cnt = MIN(hits.n, (uint32_t)DWT_HITS);
    uint32_t first = hits.n - cnt;

    out("ZDIAG lab dwt n=%u zero=%u comp=%x func=%x demcr=%x", hits.n, hits.zero_n, DWT->COMP0, DWT->FUNCTION0,
        CoreDebug->DEMCR);
    for (uint32_t i = 0; i < cnt; i++) {
        const struct dwt_hit *h = &hits.ring[(first + i) % DWT_HITS];

        out("ZDIAG lab dwthit dt=%d pc=%x lr=%x xpsr=%x value=%u ack=%u late=%u dfsr=%x", (int32_t)(h->t_us - t_ref),
            h->pc, h->lr, h->xpsr, h->value, h->ack, h->late, h->dfsr);
    }
}

#else
void diag_lab_dwt_print(void (*out)(const char *fmt, ...), uint32_t t_ref) {
    ARG_UNUSED(t_ref);
    out("ZDIAG lab dwt n=0 (no address compiled in)");
}
#endif
