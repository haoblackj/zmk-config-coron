/*
 * LAB ONLY (CONFIG_CORON_DIAG_LAT, 2026-10-09): where does the interrupt latency come from?
 *
 * Background: the link layer asserts in prepare_cb (lll_central.c:252, LL_ASSERT_OVERHEAD) when its
 * prepare runs more than EVENT_OVERHEAD_START_US (275 us in this build) late. The LLL runs in an
 * ISR at IRQ_CONNECT priority 0 (hardware level 1, the highest level that irq_lock masks). Only
 * three things can delay it that much: a region that masks interrupts (irq_lock / spinlock in any
 * driver, kernel or module), the CPU halted by a flash write or erase, or the controller's own
 * ISRs at the same level running long. Thread-level CPU use cannot.
 *
 * Two probes, both writing into the DIAGREC region (0x2002c800, after diag_entry.c's crumb) that
 * survives the fatal-error reboot, so the NEXT boot prints what was recorded:
 *
 * 1. Latency probe: TIMER4 at 1 MHz, compare every 1000 us with COMPARE0_CLEAR, ISR at the same
 *    level as the LLL (IRQ_CONNECT priority 0, NOT NVIC 0: it must be masked by irq_lock exactly
 *    like the LLL). The counter value at ISR entry is the latency in microseconds. Every latency of
 *    100 us or more is recorded with the context that was interrupted: the PC/LR of the thread
 *    frame on PSP, the NVIC active-interrupt bits (a nested lower-priority ISR shows up here), and
 *    the current thread's name. The ISR makes no kernel calls (its own ms counter is the clock).
 *    Cost: one short ISR per millisecond at the LLL's level (a few microseconds), and TIMER4 keeps
 *    the 16 MHz clock running (no low-power idle; irrelevant on USB power). Lab image only.
 *
 * 2. Assert capture: CONFIG_BT_CTLR_ASSERT_HANDLER=y makes every LL_ASSERT call
 *    bt_ctlr_assert_handle(file, line) instead of k_oops() directly (hal/debug.h; an application
 *    hook, no Zephyr change). The handler records file/line and the same interrupted-context
 *    fields, then calls k_oops() so the watchdog module still records the fatal and reboots.
 *
 * The console dump (diag_min.c) prints the previous boot's record and this boot's record:
 *   ZDIAG lat prev v= ticks= max=<us>@<ms> over=<>=100>/<>=275>/<>=500>/<>=1000> n= as=
 *   ZDIAG lat prevas line= file= up= ipsr= iabr=/ pc= lr= thr=
 *   ZDIAG lat prevworst up= lat= iabr=/ pc= lr= thr=
 *   ZDIAG lat prevev up= lat= iabr=/ pc= lr= thr=            (up to 16, oldest first)
 *   ZDIAG lat now ... / nowworst / nowev                     (this boot so far)
 * PCs are resolved with addr2line against THIS image's ELF.
 */

#include <string.h>

#include <zephyr/init.h>
#include <zephyr/irq.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/util.h>
#include <cmsis_core.h>
#include <nrf.h>

#define LAT_MAGIC 0x3154414cu /* 'LAT1' */
#define LAT_ADDR 0x2002c800u
#define LAT_PERIOD_US 1000u
#define LAT_THRESH_US 100u
#define LAT_RING 16
#define LAT_NAME 12
#define LAT_FILE 20

struct lat_ev {
    uint32_t up_ms;
    uint32_t lat_us;
    uint32_t iabr0;
    uint32_t iabr1;
    uint32_t pc;
    uint32_t lr;
    char thr[LAT_NAME];
};

struct lat_as {
    uint32_t valid;
    uint32_t line;
    char file[LAT_FILE];
    uint32_t up_ms;
    uint32_t ipsr;
    uint32_t iabr0;
    uint32_t iabr1;
    uint32_t pc;
    uint32_t lr;
    char thr[LAT_NAME];
};

struct latrec {
    uint32_t magic;
    uint32_t magic_inv;
    uint32_t base_ms;  /* k_uptime when the probe started; up_ms = base_ms + ticks */
    uint32_t ticks;    /* probe ISR count (= ms since start) */
    uint32_t max_us;
    uint32_t max_at_ms;
    uint32_t over[4];  /* latencies >= 100, 275, 500, 1000 us */
    uint32_t n;        /* events recorded (ring index = n % LAT_RING) */
    struct lat_ev ring[LAT_RING];
    struct lat_ev worst;
    struct lat_as as;
};
BUILD_ASSERT(sizeof(struct latrec) <= 0x800, "latrec must fit in the upper 2 KB of DIAGREC");
BUILD_ASSERT(DT_REG_ADDR(DT_NODELABEL(diagrec)) == 0x2002c000 && DT_REG_SIZE(DT_NODELABEL(diagrec)) >= 0x1000,
             "DIAGREC must be the 4 KB region at 0x2002c000 (diagrec.overlay)");

#define REC ((struct latrec *)LAT_ADDR)

static struct latrec prev;
static bool prev_valid;

static void copy_name(char *dst, size_t n) {
    const char *name = NULL;
    struct k_thread *t = k_current_get();

    if (t != NULL) {
        name = k_thread_name_get(t);
    }
    memset(dst, 0, n);
    if (name != NULL) {
        strncpy(dst, name, n - 1);
    }
}

/* The thread frame on PSP: r0 r1 r2 r3 r12 lr pc xpsr. When this ISR preempted a lower-priority
 * ISR, PSP still holds the frame of the thread THAT ISR preempted (and iabr names the ISR). */
static void thread_frame(uint32_t *pc, uint32_t *lr) {
    uint32_t psp = __get_PSP();

    *pc = 0;
    *lr = 0;
    if (psp >= 0x20000000u && psp + 32u <= 0x2002c000u) {
        const uint32_t *f = (const uint32_t *)psp;
        *lr = f[5];
        *pc = f[6];
    }
}

static void fill_ev(struct lat_ev *ev, uint32_t lat) {
    ev->up_ms = REC->base_ms + REC->ticks;
    ev->lat_us = lat;
    ev->iabr0 = NVIC->IABR[0];
    ev->iabr1 = NVIC->IABR[1];
    thread_frame(&ev->pc, &ev->lr);
    copy_name(ev->thr, sizeof(ev->thr));
}

ISR_DIRECT_DECLARE(lat_isr) {
    struct latrec *r = REC;
    uint32_t lat;

    NRF_TIMER4->EVENTS_COMPARE[0] = 0;
    NRF_TIMER4->TASKS_CAPTURE[1] = 1;
    lat = NRF_TIMER4->CC[1]; /* the counter was cleared at the compare event: this is the latency */
    r->ticks++;
    if (lat > r->max_us) {
        r->max_us = lat;
        r->max_at_ms = r->base_ms + r->ticks;
    }
    if (lat >= LAT_THRESH_US) {
        struct lat_ev ev;

        r->over[0]++;
        if (lat >= 275u) { r->over[1]++; }
        if (lat >= 500u) { r->over[2]++; }
        if (lat >= 1000u) { r->over[3]++; }
        fill_ev(&ev, lat);
        r->ring[r->n % LAT_RING] = ev;
        r->n++;
        if (lat > r->worst.lat_us) {
            r->worst = ev;
        }
        __DSB();
    }
    return 0; /* no scheduling decision from this ISR */
}

static int lat_init(void) {
    /* the previous boot's record, before this boot overwrites it */
    prev = *REC;
    prev_valid = (prev.magic == LAT_MAGIC && prev.magic_inv == ~LAT_MAGIC);
    memset(REC, 0, sizeof(*REC));
    REC->magic = LAT_MAGIC;
    REC->magic_inv = ~LAT_MAGIC;
    REC->base_ms = k_uptime_get_32();
    __DSB();

    NRF_TIMER4->TASKS_STOP = 1;
    NRF_TIMER4->MODE = TIMER_MODE_MODE_Timer;
    NRF_TIMER4->BITMODE = TIMER_BITMODE_BITMODE_32Bit;
    NRF_TIMER4->PRESCALER = 4; /* 16 MHz / 16 = 1 MHz: one count per microsecond */
    NRF_TIMER4->CC[0] = LAT_PERIOD_US;
    NRF_TIMER4->SHORTS = TIMER_SHORTS_COMPARE0_CLEAR_Msk;
    NRF_TIMER4->EVENTS_COMPARE[0] = 0;
    NRF_TIMER4->INTENSET = TIMER_INTENSET_COMPARE0_Msk;
    /* IRQ_CONNECT priority 0 = the LLL's level (CONFIG_BT_CTLR_LLL_PRIO=0). Deliberately not
     * NVIC_SetPriority(.., 0): that would sit above irq_lock and miss exactly what we measure. */
    IRQ_DIRECT_CONNECT(TIMER4_IRQn, 0, lat_isr, 0);
    NVIC_ClearPendingIRQ(TIMER4_IRQn);
    irq_enable(TIMER4_IRQn);
    NRF_TIMER4->TASKS_CLEAR = 1;
    NRF_TIMER4->TASKS_START = 1;
    return 0;
}
SYS_INIT(lat_init, POST_KERNEL, 0);

/* CONFIG_BT_CTLR_ASSERT_HANDLER: the controller's assert sink (hal/debug.h). Runs in the asserting
 * context (an LLL or ULL ISR). Record, then die the same way BT_ASSERT_DIE would (k_oops), so the
 * watchdog module's fatal handler records the incident and reboots as before. */
void bt_ctlr_assert_handle(char *file, uint32_t line) {
    struct latrec *r = REC;
    size_t len = file ? strlen(file) : 0;

    r->as.valid = 1;
    r->as.line = line;
    memset(r->as.file, 0, sizeof(r->as.file));
    if (len > 0) {
        const char *tail = (len > LAT_FILE - 1) ? file + len - (LAT_FILE - 1) : file;
        strncpy(r->as.file, tail, LAT_FILE - 1);
    }
    r->as.up_ms = r->base_ms + r->ticks;
    r->as.ipsr = __get_IPSR();
    r->as.iabr0 = NVIC->IABR[0];
    r->as.iabr1 = NVIC->IABR[1];
    thread_frame(&r->as.pc, &r->as.lr);
    copy_name(r->as.thr, sizeof(r->as.thr));
    __DSB();
    k_oops();
}

static void print_rec(void (*out)(const char *fmt, ...), const char *tag, const struct latrec *r) {
    uint32_t cnt = MIN(r->n, (uint32_t)LAT_RING);
    uint32_t first = (r->n > LAT_RING) ? r->n - LAT_RING : 0;

    out("ZDIAG lat %s v=1 ticks=%u max=%u@%u over=%u/%u/%u/%u n=%u as=%u", tag, r->ticks, r->max_us,
        r->max_at_ms, r->over[0], r->over[1], r->over[2], r->over[3], r->n, r->as.valid);
    if (r->as.valid) {
        out("ZDIAG lat %sas line=%u file=%s up=%u ipsr=%u iabr=%x/%x pc=%x lr=%x thr=%s", tag, r->as.line,
            r->as.file, r->as.up_ms, r->as.ipsr, r->as.iabr0, r->as.iabr1, r->as.pc, r->as.lr, r->as.thr);
    }
    if (r->n > 0) {
        out("ZDIAG lat %sworst up=%u lat=%u iabr=%x/%x pc=%x lr=%x thr=%s", tag, r->worst.up_ms,
            r->worst.lat_us, r->worst.iabr0, r->worst.iabr1, r->worst.pc, r->worst.lr, r->worst.thr);
    }
    for (uint32_t i = 0; i < cnt; i++) {
        const struct lat_ev *ev = &r->ring[(first + i) % LAT_RING];

        out("ZDIAG lat %sev up=%u lat=%u iabr=%x/%x pc=%x lr=%x thr=%s", tag, ev->up_ms, ev->lat_us,
            ev->iabr0, ev->iabr1, ev->pc, ev->lr, ev->thr);
    }
}

void diag_lat_print(void (*out)(const char *fmt, ...)) {
    if (prev_valid) {
        print_rec(out, "prev", &prev);
    } else {
        out("ZDIAG lat prev v=0");
    }
    print_rec(out, "now", REC);
}
