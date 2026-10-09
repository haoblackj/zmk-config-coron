/*
 * LAB ONLY (CONFIG_CORON_DIAG_LAB, 2026-10-09, v2 after the Codex review). One recording image that
 * takes everything the chip can tell about a link-layer crash, so the measurement is done ONCE
 * (leader: no repeated loops, no flash wear, nothing kept inside the chip in production).
 *
 * Records live in one RAM block at 0x2002d000 (LABREC, 44 KB: above the 4 KB DIAGREC region, below
 * the bootloader's stack top 0x20040000 by 32 KB; not in devicetree; the app's RAM ends at
 * 0x2002c000 so nothing in the image initialises it). Crash records sit at the bottom of the block
 * (farthest from the bootloader's stack); the live rings above them are rebuilt every boot.
 *
 *  1. Lateness probe (TIMER4, free-running 1 MHz, compare advanced by 1000 us each tick, ISR at the
 *     LLL's IRQ level = IRQ_CONNECT priority 0, masked by irq_lock exactly like the LLL): lateness
 *     = capture - scheduled compare, so a 1.2 ms blockage reads 1200 (no modulo), skipped periods
 *     are counted and the schedule catches up. Latencies >= 100 us go to a 16-entry ring with the
 *     interrupted thread's PC/LR, NVIC active bits and thread name.
 *  2. Activity timeline: every tick stores {IABR[0], IABR[1] low byte (USBD = IRQ 39 = bit 7),
 *     thread PC, lateness, thread index} in a 256-entry ring.
 *  3. ISR trace (CONFIG_TRACING_USER + TRACING_ISR + TRACING_THREAD): every ISR entry/exit and
 *     every thread switch, with a microsecond timestamp, in a 512-entry ring. This is what tells a
 *     same-priority ISR tail apart from an irq_lock region, and gives the previous radio event's
 *     ISR timing.
 *  4. Masked-region sampler (TIMER3, 100 us, zero-latency IRQ = hardware priority above BASEPRI):
 *     each sample that finds interrupts masked (BASEPRI/PRIMASK) or any ISR active records
 *     {time, interrupted PC, mask state, IPSR of the interrupted context, IABR} in a 384-entry
 *     ring. A 275 us masked region gets 2-3 samples with the PC inside the culprit. Cost: ~1 us
 *     every 100 us, and up to ~1 us added latency to the LLL per sample.
 *  5. printk capture: at APPLICATION 99 (after the UART console installed its own hook at init
 *     priority 60), the hook is replaced by a tee: characters go to a 2 KB ring AND to the previous
 *     hook (the UART), so the Bluetooth assert text ("Actual EVENT_OVERHEAD_START_US = <n>") is
 *     captured without being lost from the console.
 *  6. Crash capture: CONFIG_BT_CTLR_ASSERT_HANDLER routes every LL_ASSERT to
 *     bt_ctlr_assert_handle(file, line). It fills one crash record in place (file/line, uptime,
 *     interrupted context, thread-name table, the controller's per-connection state (diag_lab_ctlr.c),
 *     NVMC state, tails of all rings and the console module's connection events), seals it with a
 *     checksum, then k_oops() so the watchdog module records and reboots as before. Four records
 *     are kept; after four, further crashes only bump a dropped counter (the first record is never
 *     lost). 'c' on the console clears them. Console 'A' = self-test through the same path.
 *
 * The console dump prints the live counters/rings and every stored crash record ('ZDIAG lab ...').
 * PCs are resolved with addr2line against THIS image's ELF.
 */

#include <string.h>

#include <zephyr/init.h>
#include <zephyr/irq.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/printk-hooks.h>
#include <zephyr/sys/util.h>
#include <cmsis_core.h>
#include <nrf.h>

#include "diag_lab.h"

#define LAB_MAGIC 0x3242414cu /* 'LAB2' */
#define LAB_ADDR 0x2002d000u
#define LAB_SIZE 0xb000u
#define PERIOD_US 1000u
#define MSK_PERIOD_US 100u
#define LAT_THRESH_US 100u
#define LAT_RING 16
#define ACT_RING 256
#define ISR_RING 512
#define MSK_RING 384
#define PK_RING 2048
#define CRASHES 4
#define NAME_LEN 12
#define THR_MAX 16
#define FILE_LEN 20
/* tails copied into a crash record */
#define LAT_TAIL 8
#define ACT_TAIL 64
#define ISR_TAIL 128
#define MSK_TAIL 128
#define PK_TAIL 384
#define EV_TAIL 24

struct lat_ev {
    uint32_t up_ms;
    uint32_t lat_us;
    uint32_t iabr0;
    uint32_t iabr1;
    uint32_t pc;
    uint32_t lr;
    char thr[NAME_LEN];
};

struct act_ev {
    uint32_t iabr0;
    uint32_t pc;
    uint16_t lat_us;
    uint8_t thr;    /* index into thr_name, 0xff = unknown */
    uint8_t iabr1l; /* NVIC IABR[1] bits 0..7 = IRQ 32..39 (bit 7 = USBD) */
};

struct isr_ev {
    uint32_t t_us; /* TIMER4 free-running microseconds since probe start */
    uint8_t irq;   /* IRQ number for dir 0/1, thread index for dir 2 */
    uint8_t dir;   /* 0 = ISR enter, 1 = ISR exit, 2 = thread switched in */
    uint16_t seq;
};

struct msk_ev {
    uint32_t t_us;
    uint32_t pc;      /* interrupted PC: thread frame (PSP) or handler frame (MSP scan) */
    uint8_t basepri;  /* BASEPRI of the interrupted context (hardware level; 0 = not masked) */
    uint8_t primask;
    uint16_t ipsr;    /* IPSR of the interrupted context (0 = thread) */
    uint32_t iabr0;
    uint16_t iabr1l;
    uint16_t pad;
};

struct ev_out {
    uint32_t ms;
    uint8_t type;
    uint16_t a;
    uint16_t b;
};

/* one call of lll_preempt_calc (the controller's prepare-latency check), via --wrap */
struct prep_ev {
    uint32_t t_us;
    uint32_t ticks_at_event; /* the radio event's planned time (RTC ticks, 30.52 us) */
    uint32_t ticks_now;      /* ticker time when the check ran */
    uint32_t result;         /* 0 = in time; else the overhead the controller computed (ticks) */
    uint8_t ticker_id;       /* ticker_id - TICKER_ID_CONN_BASE = connection handle */
    uint8_t pad[3];
};

struct prep_stat {
    uint8_t ticker_id;
    uint8_t used;
    uint16_t pad;
    uint32_t count;
    uint32_t max_late;  /* max of (ticks_now - ticks_at_event), RTC ticks, signed-clamped at 0 */
    uint32_t last_late;
    uint32_t nonzero;   /* calls that returned an overhead */
};
#define PREP_RING 64
#define PREP_TAIL 16
#define PREP_STATS 8

struct crash_rec {
    uint32_t magic;
    uint32_t seq;        /* breadcrumb seq of the boot that crashed */
    uint32_t idx;        /* 0-based crash index */
    uint32_t line;
    char file[FILE_LEN];
    uint32_t up_ms;
    uint32_t t_us;
    uint32_t ipsr;
    uint32_t iabr0;
    uint32_t iabr1;
    uint32_t pc;
    uint32_t lr;
    uint32_t xpsr;
    char thr[NAME_LEN];
    uint32_t max_us;
    uint32_t over[4];
    uint32_t skipped;
    uint32_t n_lat;
    struct lab_ctlr_snap ctlr;
    uint32_t thr_n;
    char thr_name[THR_MAX][NAME_LEN];
    uint32_t lat_n;
    struct lat_ev lat[LAT_TAIL];
    uint32_t act_n;
    struct act_ev act[ACT_TAIL];
    uint32_t isr_n;
    struct isr_ev isr[ISR_TAIL];
    uint32_t msk_n;
    struct msk_ev msk[MSK_TAIL];
    uint32_t pk_n;
    char pk[PK_TAIL];
    uint32_t ev_n;
    struct ev_out ev[EV_TAIL];
    uint32_t prep_n;
    struct prep_ev prep[PREP_TAIL];
    struct prep_stat pstat[PREP_STATS];
    uint32_t sum; /* FNV-1a over the record with sum = 0 */
};

struct labrec {
    /* kept across boots */
    uint32_t magic;
    uint32_t magic_inv;
    uint32_t crash_n;   /* crash records committed (<= CRASHES) */
    uint32_t dropped;   /* crashes after the 4 slots were full */
    struct crash_rec crash[CRASHES];
    /* live, rebuilt every boot (everything from here on) */
    uint32_t live_start;
    uint32_t base_ms;
    uint32_t ticks;
    uint32_t skipped;
    uint32_t next_cc;   /* scheduled compare value of the next tick */
    uint32_t max_us;
    uint32_t max_at_ms;
    uint32_t over[4];
    uint32_t n_lat;
    struct lat_ev lat[LAT_RING];
    uint32_t act_head;
    struct act_ev act[ACT_RING];
    uint32_t isr_head;
    struct isr_ev isr[ISR_RING];
    uint32_t msk_head;
    uint32_t msk_samples;
    struct msk_ev msk[MSK_RING];
    uint32_t thr_n;
    char thr_name[THR_MAX][NAME_LEN];
    struct k_thread *thr_ptr[THR_MAX];
    uint32_t pk_head;
    char pk[PK_RING];
    uint32_t prep_head;
    struct prep_ev prep[PREP_RING];
    struct prep_stat pstat[PREP_STATS];
};
BUILD_ASSERT(sizeof(struct labrec) <= LAB_SIZE, "labrec must fit in the LABREC block");
BUILD_ASSERT(DT_REG_ADDR(DT_NODELABEL(diagrec)) == 0x2002c000 && DT_REG_SIZE(DT_NODELABEL(diagrec)) == 0x1000,
             "LABREC sits right above the 4 KB DIAGREC region at 0x2002c000 (diagrec.overlay)");

#define REC ((struct labrec *)LAB_ADDR)

uint32_t diag_entry_seq(void);
uint32_t diag_min_events_tail(struct ev_out *dst, uint32_t max);
const char *diag_min_ev_name(uint8_t type);

static printk_hook_fn_t prev_hook;
static volatile bool selftest_armed;
void bt_ctlr_assert_handle(char *file, uint32_t line);

/* ---- small helpers (ISR-safe: memory reads and stores only) ----------------------------------- */

static uint32_t fnv1a(const void *p, size_t n) {
    const uint8_t *b = p;
    uint32_t h = 0x811c9dc5u;

    for (size_t i = 0; i < n; i++) {
        h ^= b[i];
        h *= 0x01000193u;
    }
    return h;
}

static inline uint32_t now_us(void) {
    NRF_TIMER4->TASKS_CAPTURE[3] = 1;
    return NRF_TIMER4->CC[3];
}

static uint8_t thr_index(void) {
    struct k_thread *t = k_current_get();
    struct labrec *r = REC;

    if (t == NULL) {
        return 0xff;
    }
    for (uint32_t i = 0; i < r->thr_n && i < THR_MAX; i++) {
        if (r->thr_ptr[i] == t) {
            return (uint8_t)i;
        }
    }
    if (r->thr_n >= THR_MAX) {
        return 0xff;
    }
    uint32_t i = r->thr_n;
    const char *name = k_thread_name_get(t);

    r->thr_ptr[i] = t;
    memset(r->thr_name[i], 0, NAME_LEN);
    if (name != NULL) {
        strncpy(r->thr_name[i], name, NAME_LEN - 1);
    } else {
        r->thr_name[i][0] = '?';
    }
    r->thr_n = i + 1;
    return (uint8_t)i;
}

/* The thread frame on PSP: r0 r1 r2 r3 r12 lr pc xpsr (the FP extension, if stacked, follows). */
static void thread_frame(uint32_t *pc, uint32_t *lr, uint32_t *xpsr) {
    uint32_t psp = __get_PSP();

    *pc = 0;
    *lr = 0;
    *xpsr = 0;
    if (psp >= 0x20000000u && psp + 32u <= 0x2002c000u) {
        const uint32_t *f = (const uint32_t *)psp;
        *lr = f[5];
        *pc = f[6];
        *xpsr = f[7];
    }
}

/* Handler-mode frame: scan upward from the current MSP for the hardware-stacked frame of the
 * interrupted handler (xPSR with the Thumb bit and the expected IPSR, a Thumb return address). */
static uint32_t handler_frame_pc(uint32_t want_ipsr) {
    uint32_t msp = __get_MSP();
    const uint32_t *w = (const uint32_t *)msp;

    for (uint32_t i = 0; i < 40; i++) {
        uint32_t xpsr = w[i + 7];
        uint32_t pc = w[i + 6];

        if ((uintptr_t)&w[i + 8] > 0x2002c000u) {
            break;
        }
        if ((xpsr & BIT(24)) && (xpsr & 0x1ffu) == want_ipsr && (pc & 1u) == 0u &&
            ((pc >= 0x27000u && pc < 0x100000u) || (pc >= 0x20000000u && pc < 0x2002c000u))) {
            return pc;
        }
    }
    return 0;
}

static void fill_lat(struct lat_ev *ev, uint32_t lat) {
    struct labrec *r = REC;
    uint8_t ti = thr_index();
    uint32_t xpsr;

    ev->up_ms = r->base_ms + r->ticks;
    ev->lat_us = lat;
    ev->iabr0 = NVIC->IABR[0];
    ev->iabr1 = NVIC->IABR[1];
    thread_frame(&ev->pc, &ev->lr, &xpsr);
    memset(ev->thr, 0, NAME_LEN);
    if (ti != 0xff) {
        memcpy(ev->thr, r->thr_name[ti], NAME_LEN);
    }
}

/* ---- 1 kHz lateness probe (TIMER4, free-running) ---------------------------------------------- */

ISR_DIRECT_DECLARE(lab_isr) {
    struct labrec *r = REC;
    uint32_t now, lat;
    struct act_ev a;

    NRF_TIMER4->EVENTS_COMPARE[0] = 0;
    now = now_us();
    lat = now - r->next_cc; /* how late this tick ran (wraps correctly in uint32) */
    r->ticks++;
    /* schedule the next tick; if we are more than a period late, skip whole periods */
    r->next_cc += PERIOD_US;
    while ((int32_t)(now - r->next_cc) >= 0) {
        r->next_cc += PERIOD_US;
        r->skipped++;
    }
    NRF_TIMER4->CC[0] = r->next_cc;
    if (selftest_armed) {
        selftest_armed = false;
        /* the same text path as LL_ASSERT_MSG (BT_ASSERT_PRINT + BT_ASSERT_PRINT_MSG, hal/debug.h) */
        printk("ASSERT: selftest\n");
        printk("lab_selftest: Actual EVENT_OVERHEAD_START_US = %u\n", 4242);
        bt_ctlr_assert_handle("selftest", 4242); /* does not return */
    }
    if (lat > r->max_us) {
        r->max_us = lat;
        r->max_at_ms = r->base_ms + r->ticks;
    }
    a.iabr0 = NVIC->IABR[0];
    a.iabr1l = (uint8_t)(NVIC->IABR[1] & 0xffu);
    a.lat_us = (lat > 0xffffu) ? 0xffffu : (uint16_t)lat;
    a.thr = thr_index();
    {
        uint32_t lr, xpsr;
        thread_frame(&a.pc, &lr, &xpsr);
    }
    r->act[r->act_head % ACT_RING] = a;
    r->act_head++;
    if (lat >= LAT_THRESH_US) {
        struct lat_ev ev;

        r->over[0]++;
        if (lat >= 275u) { r->over[1]++; }
        if (lat >= 500u) { r->over[2]++; }
        if (lat >= 1000u) { r->over[3]++; }
        fill_lat(&ev, lat);
        r->lat[r->n_lat % LAT_RING] = ev;
        r->n_lat++;
        __DSB();
    }
    return 0;
}

/* ---- 10 kHz masked-region sampler (TIMER3, zero-latency IRQ) ---------------------------------- */

ISR_DIRECT_DECLARE(msk_isr) {
    struct labrec *r = REC;
    uint32_t iabr0, iabr1, basepri, primask;

    NRF_TIMER3->EVENTS_COMPARE[0] = 0;
    NRF_TIMER3->CC[0] += MSK_PERIOD_US;
    r->msk_samples++;
    iabr0 = NVIC->IABR[0] & ~(1u << TIMER3_IRQn);
    iabr1 = NVIC->IABR[1];
    /* the interrupted context's masks are still in the registers: a ZLI handler runs above them */
    basepri = __get_BASEPRI();
    primask = __get_PRIMASK();
    if (basepri == 0u && primask == 0u && iabr0 == 0u && (iabr1 & 0xffffu) == 0u) {
        return 0; /* nothing in the way of the LLL right now */
    }
    {
        struct msk_ev m;
        uint32_t ipsr = 0;

        /* which ISR was interrupted: the active one with the highest hardware priority; approximate
         * by the lowest-numbered LLL-level ISR present (RADIO=1, TIMER0=8, RTC0=11, SWI4=20, SWI5=21) */
        if (iabr0 != 0u) {
            ipsr = (uint32_t)__builtin_ctz(iabr0) + 16u;
        } else if ((iabr1 & 0xffffu) != 0u) {
            ipsr = (uint32_t)__builtin_ctz(iabr1) + 32u + 16u;
        }
        m.t_us = now_us();
        m.basepri = (uint8_t)basepri;
        m.primask = (uint8_t)primask;
        m.ipsr = (uint16_t)ipsr;
        m.iabr0 = iabr0;
        m.iabr1l = (uint16_t)(iabr1 & 0xffffu);
        m.pad = 0;
        if (ipsr == 0u) {
            uint32_t lr, xpsr;
            thread_frame(&m.pc, &lr, &xpsr);
        } else {
            m.pc = handler_frame_pc(ipsr);
        }
        r->msk[r->msk_head % MSK_RING] = m;
        r->msk_head++;
    }
    return 0;
}

/* ---- ISR / thread trace (Zephyr user tracing hooks) ------------------------------------------- */

static inline void trace_put(uint8_t irq, uint8_t dir) {
    struct labrec *r = REC;
    struct isr_ev e;

    if (r->magic != LAB_MAGIC) {
        return;
    }
    e.t_us = now_us();
    e.irq = irq;
    e.dir = dir;
    e.seq = (uint16_t)r->isr_head;
    r->isr[r->isr_head % ISR_RING] = e;
    r->isr_head++;
}

void sys_trace_isr_enter_user(void) {
    uint32_t ipsr = __get_IPSR();

    if (ipsr == TIMER4_IRQn + 16u || ipsr == TIMER3_IRQn + 16u) {
        return; /* the probes themselves */
    }
    trace_put((uint8_t)(ipsr - 16u), 0);
}

void sys_trace_isr_exit_user(void) {
    uint32_t ipsr = __get_IPSR();

    if (ipsr == TIMER4_IRQn + 16u || ipsr == TIMER3_IRQn + 16u) {
        return;
    }
    trace_put((uint8_t)(ipsr - 16u), 1);
}

void sys_trace_thread_switched_in_user(void) {
    trace_put(thr_index(), 2);
}

/* ---- the controller's prepare-latency check, wrapped (-Wl,--wrap=lll_preempt_calc) ----------- */

struct ull_hdr;
uint32_t __real_lll_preempt_calc(struct ull_hdr *ull, uint8_t ticker_id, uint32_t ticks_at_event);
uint32_t ticker_ticks_now_get(void);

uint32_t __wrap_lll_preempt_calc(struct ull_hdr *ull, uint8_t ticker_id, uint32_t ticks_at_event) {
    struct labrec *r = REC;
    uint32_t now = ticker_ticks_now_get();
    uint32_t res = __real_lll_preempt_calc(ull, ticker_id, ticks_at_event);

    if (r->magic == LAB_MAGIC) {
        struct prep_ev e;
        uint32_t late = (now - ticks_at_event) & 0x00ffffffu; /* RTC is 24-bit */
        struct prep_stat *s = NULL;

        if (late & 0x00800000u) {
            late = 0; /* the event is still in the future */
        }
        e.t_us = now_us();
        e.ticks_at_event = ticks_at_event;
        e.ticks_now = now;
        e.result = res;
        e.ticker_id = ticker_id;
        e.pad[0] = e.pad[1] = e.pad[2] = 0;
        r->prep[r->prep_head % PREP_RING] = e;
        r->prep_head++;
        for (uint32_t i = 0; i < PREP_STATS; i++) {
            if (r->pstat[i].used && r->pstat[i].ticker_id == ticker_id) { s = &r->pstat[i]; break; }
            if (!r->pstat[i].used) { s = &r->pstat[i]; s->used = 1; s->ticker_id = ticker_id; break; }
        }
        if (s != NULL) {
            s->count++;
            s->last_late = late;
            if (late > s->max_late) { s->max_late = late; }
            if (res != 0u) { s->nonzero++; }
        }
    }
    return res;
}

/* ---- printk tee ------------------------------------------------------------------------------- */

static int lab_printk_char(int c) {
    struct labrec *r = REC;

    r->pk[r->pk_head % PK_RING] = (char)c;
    r->pk_head++;
    if (prev_hook != NULL) {
        prev_hook(c);
    }
    return c;
}

/* ---- init ------------------------------------------------------------------------------------- */

static int lab_init(void) {
    struct labrec *r = REC;
    bool keep = (r->magic == LAB_MAGIC && r->magic_inv == ~LAB_MAGIC && r->crash_n <= CRASHES);

    if (!keep) {
        memset(r, 0, sizeof(*r));
        r->magic = LAB_MAGIC;
        r->magic_inv = ~LAB_MAGIC;
    } else {
        /* clear only the live part; the crash records and their counters stay */
        memset(&r->live_start, 0, sizeof(*r) - offsetof(struct labrec, live_start));
    }
    r->base_ms = k_uptime_get_32();
    __DSB();

    /* TIMER4: free-running 1 MHz, tick compare on CC[0], capture channel CC[3] for timestamps */
    NRF_TIMER4->TASKS_STOP = 1;
    NRF_TIMER4->MODE = TIMER_MODE_MODE_Timer;
    NRF_TIMER4->BITMODE = TIMER_BITMODE_BITMODE_32Bit;
    NRF_TIMER4->PRESCALER = 4; /* 16 MHz / 16 */
    NRF_TIMER4->SHORTS = 0;
    NRF_TIMER4->TASKS_CLEAR = 1;
    r->next_cc = PERIOD_US;
    NRF_TIMER4->CC[0] = r->next_cc;
    NRF_TIMER4->EVENTS_COMPARE[0] = 0;
    NRF_TIMER4->INTENSET = TIMER_INTENSET_COMPARE0_Msk;
    IRQ_DIRECT_CONNECT(TIMER4_IRQn, 0, lab_isr, 0); /* the LLL's level; masked by irq_lock like it */
    NVIC_ClearPendingIRQ(TIMER4_IRQn);
    irq_enable(TIMER4_IRQn);
    NRF_TIMER4->TASKS_START = 1;

    /* TIMER3: 100 us sampler as a zero-latency IRQ (above BASEPRI: it sees masked regions) */
    NRF_TIMER3->TASKS_STOP = 1;
    NRF_TIMER3->MODE = TIMER_MODE_MODE_Timer;
    NRF_TIMER3->BITMODE = TIMER_BITMODE_BITMODE_32Bit;
    NRF_TIMER3->PRESCALER = 4;
    NRF_TIMER3->SHORTS = 0;
    NRF_TIMER3->TASKS_CLEAR = 1;
    NRF_TIMER3->CC[0] = MSK_PERIOD_US;
    NRF_TIMER3->EVENTS_COMPARE[0] = 0;
    NRF_TIMER3->INTENSET = TIMER_INTENSET_COMPARE0_Msk;
    IRQ_DIRECT_CONNECT(TIMER3_IRQn, 0, msk_isr, IRQ_ZERO_LATENCY);
    NVIC_ClearPendingIRQ(TIMER3_IRQn);
    irq_enable(TIMER3_IRQn);
    NRF_TIMER3->TASKS_START = 1;
    return 0;
}
SYS_INIT(lab_init, POST_KERNEL, 0);

static void name_thread(const struct k_thread *t, void *user) {
    ARG_UNUSED(user);
    struct labrec *r = REC;

    if (r->thr_n >= THR_MAX) {
        return;
    }
    for (uint32_t i = 0; i < r->thr_n; i++) {
        if (r->thr_ptr[i] == t) {
            return;
        }
    }
    {
        uint32_t i = r->thr_n;
        const char *name = k_thread_name_get((k_tid_t)t);

        r->thr_ptr[i] = (struct k_thread *)t;
        memset(r->thr_name[i], 0, NAME_LEN);
        strncpy(r->thr_name[i], name ? name : "?", NAME_LEN - 1);
        r->thr_n = i + 1;
    }
}

static int lab_late_init(void) {
    /* name the threads that exist now, so the ISRs only do table lookups afterwards */
    k_thread_foreach(name_thread, NULL);
    /* the UART console installed its hook at init priority 60; tee into it from here on */
    prev_hook = __printk_get_hook();
    __printk_hook_install(lab_printk_char);
    return 0;
}
SYS_INIT(lab_late_init, APPLICATION, 99);

/* ---- crash capture ---------------------------------------------------------------------------- */

static void copy_tail_u8(void *dst, const void *ring, uint32_t esz, uint32_t ring_n, uint32_t head,
                         uint32_t tail_n, uint32_t *out_n) {
    uint32_t cnt = MIN(head, tail_n);
    uint32_t first = head - cnt;

    for (uint32_t i = 0; i < cnt; i++) {
        memcpy((uint8_t *)dst + i * esz, (const uint8_t *)ring + ((first + i) % ring_n) * esz, esz);
    }
    *out_n = cnt;
}

void bt_ctlr_assert_handle(char *file, uint32_t line) {
    struct labrec *r = REC;
    struct crash_rec *c;
    size_t len = file ? strlen(file) : 0;
    uint8_t ti;

    if (r->magic != LAB_MAGIC || r->crash_n >= CRASHES) {
        if (r->magic == LAB_MAGIC) {
            r->dropped++;
            __DSB();
        }
        k_oops();
    }
    c = &r->crash[r->crash_n];
    memset(c, 0, sizeof(*c));
    c->magic = LAB_MAGIC;
    c->seq = diag_entry_seq();
    c->idx = r->crash_n;
    c->line = line;
    if (len > 0) {
        const char *tail = (len > FILE_LEN - 1) ? file + len - (FILE_LEN - 1) : file;
        strncpy(c->file, tail, FILE_LEN - 1);
    }
    c->up_ms = r->base_ms + r->ticks;
    c->t_us = now_us();
    c->ipsr = __get_IPSR();
    c->iabr0 = NVIC->IABR[0];
    c->iabr1 = NVIC->IABR[1];
    thread_frame(&c->pc, &c->lr, &c->xpsr);
    ti = thr_index();
    if (ti != 0xff) {
        memcpy(c->thr, r->thr_name[ti], NAME_LEN);
    }
    c->max_us = r->max_us;
    memcpy(c->over, r->over, sizeof(c->over));
    c->skipped = r->skipped;
    c->n_lat = r->n_lat;
    diag_lab_ctlr_snapshot(&c->ctlr);
    c->thr_n = MIN(r->thr_n, (uint32_t)THR_MAX);
    memcpy(c->thr_name, r->thr_name, sizeof(c->thr_name));
    copy_tail_u8(c->lat, r->lat, sizeof(struct lat_ev), LAT_RING, r->n_lat, LAT_TAIL, &c->lat_n);
    copy_tail_u8(c->act, r->act, sizeof(struct act_ev), ACT_RING, r->act_head, ACT_TAIL, &c->act_n);
    copy_tail_u8(c->isr, r->isr, sizeof(struct isr_ev), ISR_RING, r->isr_head, ISR_TAIL, &c->isr_n);
    copy_tail_u8(c->msk, r->msk, sizeof(struct msk_ev), MSK_RING, r->msk_head, MSK_TAIL, &c->msk_n);
    copy_tail_u8(c->pk, r->pk, 1, PK_RING, r->pk_head, PK_TAIL, &c->pk_n);
    c->ev_n = diag_min_events_tail(c->ev, EV_TAIL);
    copy_tail_u8(c->prep, r->prep, sizeof(struct prep_ev), PREP_RING, r->prep_head, PREP_TAIL, &c->prep_n);
    memcpy(c->pstat, r->pstat, sizeof(c->pstat));
    c->sum = 0;
    c->sum = fnv1a(c, sizeof(*c));
    __DSB();
    r->crash_n++;
    __DSB();
    k_oops();
}

/* ---- console output --------------------------------------------------------------------------- */

static const char *thr_of(const char names[][NAME_LEN], uint32_t n, uint8_t i) {
    return (i < THR_MAX && i < n) ? names[i] : "?";
}

static void print_lat(void (*out)(const char *fmt, ...), const char *tag, const struct lat_ev *ev) {
    out("ZDIAG lab %s up=%u lat=%u iabr=%x/%x pc=%x lr=%x thr=%s", tag, ev->up_ms, ev->lat_us, ev->iabr0,
        ev->iabr1, ev->pc, ev->lr, ev->thr);
}

/* run-length: consecutive ticks with the same ISR set and thread are one line */
static void print_act(void (*out)(const char *fmt, ...), const char *tag, const char names[][NAME_LEN],
                      uint32_t names_n, const struct act_ev *a, uint32_t n) {
    uint32_t i = 0;

    while (i < n) {
        uint32_t j = i + 1;
        uint16_t maxlat = a[i].lat_us;
        uint32_t isr = a[i].iabr0 & ~(1u << TIMER4_IRQn) & ~(1u << TIMER3_IRQn);

        while (j < n && (a[j].iabr0 & ~(1u << TIMER4_IRQn) & ~(1u << TIMER3_IRQn)) == isr &&
               a[j].iabr1l == a[i].iabr1l && a[j].thr == a[i].thr) {
            if (a[j].lat_us > maxlat) { maxlat = a[j].lat_us; }
            j++;
        }
        out("ZDIAG lab %s t=-%u..-%u isr=%x/%x thr=%s pc=%x..%x maxlat=%u", tag, n - i, n - j + 1, isr,
            a[i].iabr1l, thr_of(names, names_n, a[i].thr), a[i].pc, a[j - 1].pc, maxlat);
        i = j;
    }
}

static void print_isr(void (*out)(const char *fmt, ...), const char *tag, const char names[][NAME_LEN],
                      uint32_t names_n, const struct isr_ev *e, uint32_t n, uint32_t t_ref) {
    /* several events per line: "irq+" enter, "irq-" exit, "T:name" switch; time relative to t_ref */
    char line[200];
    int k = 0;

    for (uint32_t i = 0; i < n; i++) {
        char item[40];
        int32_t dt = (int32_t)(e[i].t_us - t_ref);

        if (e[i].dir == 2) {
            snprintk(item, sizeof(item), " %d:T%s", dt, thr_of(names, names_n, e[i].irq));
        } else {
            snprintk(item, sizeof(item), " %d:%u%c", dt, e[i].irq, e[i].dir ? '-' : '+');
        }
        if (k + (int)strlen(item) >= (int)sizeof(line) - 1) {
            line[k] = 0;
            out("ZDIAG lab %s%s", tag, line);
            k = 0;
        }
        k += snprintk(line + k, sizeof(line) - k, "%s", item);
    }
    if (k > 0) {
        line[k] = 0;
        out("ZDIAG lab %s%s", tag, line);
    }
}

static void print_msk(void (*out)(const char *fmt, ...), const char *tag, const struct msk_ev *m, uint32_t n,
                      uint32_t t_ref) {
    for (uint32_t i = 0; i < n; i++) {
        out("ZDIAG lab %s dt=%d pc=%x bp=%u pm=%u ipsr=%u iabr=%x/%x", tag, (int32_t)(m[i].t_us - t_ref),
            m[i].pc, m[i].basepri, m[i].primask, m[i].ipsr, m[i].iabr0, m[i].iabr1l);
    }
}

static void print_text(void (*out)(const char *fmt, ...), const char *tag, const char *s, uint32_t n) {
    char line[121];
    uint32_t k = 0;

    for (uint32_t i = 0; i < n; i++) {
        char ch = s[i];

        if (ch == '\n' || k == sizeof(line) - 1) {
            line[k] = 0;
            if (k > 0) { out("ZDIAG lab %s |%s", tag, line); }
            k = 0;
            if (ch == '\n') { continue; }
        }
        if (ch == '\r') { continue; }
        line[k++] = (ch >= 32 && ch < 127) ? ch : '.';
    }
    line[k] = 0;
    if (k > 0) { out("ZDIAG lab %s |%s", tag, line); }
}

static void print_prep(void (*out)(const char *fmt, ...), const char *tag, const struct prep_stat *st,
                       const struct prep_ev *e, uint32_t n, uint32_t t_ref) {
    for (uint32_t i = 0; i < PREP_STATS; i++) {
        if (st[i].used) {
            out("ZDIAG lab %sstat id=%u n=%u max_late=%u last_late=%u over=%u (ticks of 30.52us; conn=id-%u)", tag,
                st[i].ticker_id, st[i].count, st[i].max_late, st[i].last_late, st[i].nonzero,
                diag_lab_ticker_conn_base());
        }
    }
    for (uint32_t i = 0; i < n; i++) {
        out("ZDIAG lab %s dt=%d id=%u at=%u now=%u late=%d result=%u", tag, (int32_t)(e[i].t_us - t_ref),
            e[i].ticker_id, e[i].ticks_at_event, e[i].ticks_now,
            (int32_t)((e[i].ticks_now - e[i].ticks_at_event) << 8) >> 8, e[i].result);
    }
}

static void print_crash(void (*out)(const char *fmt, ...), const struct crash_rec *c) {
    char tag[16], t2[24];
    struct crash_rec tmp;
    uint32_t sum;

    memcpy(&tmp, c, sizeof(tmp));
    tmp.sum = 0;
    sum = fnv1a(&tmp, sizeof(tmp));
    snprintk(tag, sizeof(tag), "crash%u", c->idx);
    out("ZDIAG lab %s seq=%u line=%u file=%s up=%u t=%u ipsr=%u iabr=%x/%x pc=%x lr=%x xpsr=%x thr=%s sum=%s",
        tag, c->seq, c->line, c->file, c->up_ms, c->t_us, c->ipsr, c->iabr0, c->iabr1, c->pc, c->lr, c->xpsr,
        c->thr, (sum == c->sum) ? "ok" : "BAD");
    out("ZDIAG lab %sstat max=%u over=%u/%u/%u/%u skipped=%u nlat=%u ticker=%u rtc0=%u nvmc=%x/%x", tag,
        c->max_us, c->over[0], c->over[1], c->over[2], c->over[3], c->skipped, c->n_lat, c->ctlr.ticker_now,
        c->ctlr.rtc0_counter, c->ctlr.nvmc_config, c->ctlr.nvmc_ready);
    for (uint32_t h = 0; h < LAB_CONN_MAX; h++) {
        const struct lab_conn_snap *s = &c->ctlr.conn[h];

        out("ZDIAG lab %sconn h=%u valid=%u role=%u interval=%u latency=%u lat_prep=%u lazy_prep=%u lat_ev=%u evcnt=%u",
            tag, h, s->valid, s->role, s->interval, s->latency, s->latency_prepare, s->lazy_prepare,
            s->latency_event, s->event_counter);
    }
    for (uint32_t i = 0; i < MIN(c->thr_n, (uint32_t)THR_MAX); i++) {
        out("ZDIAG lab %sthr%u=%s", tag, i, c->thr_name[i]);
    }
    snprintk(t2, sizeof(t2), "%slat", tag);
    for (uint32_t i = 0; i < MIN(c->lat_n, (uint32_t)LAT_TAIL); i++) {
        print_lat(out, t2, &c->lat[i]);
    }
    for (uint32_t i = 0; i < MIN(c->ev_n, (uint32_t)EV_TAIL); i++) {
        out("ZDIAG lab %sev ms=%u type=%s a=%u b=%u", tag, c->ev[i].ms, diag_min_ev_name(c->ev[i].type),
            c->ev[i].a, c->ev[i].b);
    }
    snprintk(t2, sizeof(t2), "%sprep", tag);
    print_prep(out, t2, c->pstat, c->prep, MIN(c->prep_n, (uint32_t)PREP_TAIL), c->t_us);
    snprintk(t2, sizeof(t2), "%sact", tag);
    print_act(out, t2, c->thr_name, c->thr_n, c->act, MIN(c->act_n, (uint32_t)ACT_TAIL));
    snprintk(t2, sizeof(t2), "%sisr", tag);
    print_isr(out, t2, c->thr_name, c->thr_n, c->isr, MIN(c->isr_n, (uint32_t)ISR_TAIL), c->t_us);
    snprintk(t2, sizeof(t2), "%smsk", tag);
    print_msk(out, t2, c->msk, MIN(c->msk_n, (uint32_t)MSK_TAIL), c->t_us);
    snprintk(t2, sizeof(t2), "%spk", tag);
    print_text(out, t2, c->pk, MIN(c->pk_n, (uint32_t)PK_TAIL));
}

void diag_lab_print(void (*out)(const char *fmt, ...)) {
    const struct labrec *r = REC;

    if (r->magic != LAB_MAGIC || r->magic_inv != ~LAB_MAGIC) {
        out("ZDIAG lab invalid");
        return;
    }
    out("ZDIAG lab live ticks=%u skipped=%u max=%u@%u over=%u/%u/%u/%u nlat=%u msk=%u/%u isr=%u thr=%u crashes=%u dropped=%u",
        r->ticks, r->skipped, r->max_us, r->max_at_ms, r->over[0], r->over[1], r->over[2], r->over[3], r->n_lat,
        r->msk_head, r->msk_samples, r->isr_head, r->thr_n, r->crash_n, r->dropped);
    for (uint32_t i = 0; i < r->thr_n && i < THR_MAX; i++) {
        out("ZDIAG lab thr%u=%s", i, r->thr_name[i]);
    }
    {
        uint32_t cnt = MIN(r->n_lat, (uint32_t)LAT_RING);
        uint32_t first = r->n_lat - cnt;

        for (uint32_t i = 0; i < cnt; i++) {
            print_lat(out, "livelat", &r->lat[(first + i) % LAT_RING]);
        }
    }
    {
        /* live prepare stats and the last 16 checks (the margin every radio event has right now) */
        struct prep_ev tail[PREP_TAIL];
        uint32_t n;

        copy_tail_u8(tail, r->prep, sizeof(struct prep_ev), PREP_RING, r->prep_head, PREP_TAIL, &n);
        print_prep(out, "liveprep", r->pstat, tail, n, now_us());
    }
    for (uint32_t k = 0; k < MIN(r->crash_n, (uint32_t)CRASHES); k++) {
        if (r->crash[k].magic == LAB_MAGIC) {
            print_crash(out, &r->crash[k]);
        }
    }
    out("ZDIAG lab end");
}

void diag_lab_selftest(void) {
    selftest_armed = true;
}

void diag_lab_clear(void) {
    struct labrec *r = REC;

    memset(r->crash, 0, sizeof(r->crash));
    r->crash_n = 0;
    r->dropped = 0;
    __DSB();
}
