/*
 * LAB ONLY (CONFIG_CORON_DIAG_LAB, 2026-10-09, v3). One recording image that takes everything the
 * chip can tell about a late link-layer prepare, so the measurement is done ONCE (leader: no repeated
 * loops, no flash wear, nothing kept inside the chip in production).
 *
 * v3 (after the two crash records of 18:29/18:30): the lateness itself was explained (the split
 * central's prepare ran only after the PC's connection event ended, i.e. the preempt timeout did
 * not fire), so this version records the controller's scheduling steps (diag_lab_ctlr.c, --wrap)
 * and runs with the PRODUCTION interrupt layout (no zero-latency IRQs: v2's ZLI made the radio
 * interrupts unmaskable, which production does not have) and the production assert setting (off:
 * a late prepare skips the event; the wrapper takes a record of the rings at that moment instead
 * of a reboot).
 *
 * Records live in one RAM block at 0x2002d000 (LABREC, 44 KB: above the 4 KB DIAGREC region, below
 * the bootloader's stack top 0x20040000 by 32 KB; not in devicetree; the app's RAM ends at
 * 0x2002c000 so nothing in the image initialises it). Records sit at the bottom of the block
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
 *     every thread switch, with a microsecond timestamp, in a 512-entry ring.
 *  4. Controller scheduling trace: prepares arriving, the pipeline, the preempt timeout's
 *     start/stop/answer/fire, abort decisions and aborts, lateness checks, ticker updates
 *     (diag_lab_ctlr.c), 256-entry ring.
 *  5. Masked-region sampler (TIMER3, 100 us, zero-latency IRQ): only when CONFIG_ZERO_LATENCY_IRQS
 *     is on (v2); off in v3 so the interrupt layout equals production.
 *  6. printk capture: at APPLICATION 99 (after the UART console installed its own hook at init
 *     priority 60), the hook is replaced by a tee: characters go to a 2 KB ring AND to the previous
 *     hook (the UART), so controller messages are captured without being lost from the console.
 *  7. Records (3 kept, then a dropped counter): (a) every LL_ASSERT (CONFIG_BT_CTLR_ASSERT_HANDLER ->
 *     bt_ctlr_assert_handle) fills one in place and k_oops()es as before; (b) a late prepare seen
 *     by the lll_preempt_calc wrapper marks the time and a work item fills one a few ms later (the
 *     tails are long enough; dt in the printout is relative to the mark, not the fill); (c) console
 *     'A' = the assert path, 'M' = the mark path, both self-tests. Each record: file/line or ticker
 *     id, uptime, interrupted context, thread names, the controller's per-connection state (incl.
 *     forced, supervision/connect countdown, prepare offset, slot), NVMC, tails of all rings and the
 *     console module's connection events, sealed with a checksum. 'c' clears them.
 *
 * The console dump prints the live counters/rings and every stored record ('ZDIAG lab ...').
 * PCs are resolved with addr2line against THIS image's ELF (tools/coron-diag/lab-dump.py).
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

#define LAB_MAGIC 0x3542414cu /* 'LAB5' */
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
#define CTL_RING 256
#define PRE_RING 256  /* sparse: only the preempt-related steps, so it reaches minutes back */
#define PREP_RING 64
#define CRASHES 3
#define NAME_LEN 12
#define THR_MAX 16
#define FILE_LEN 20
/* tails copied into a record */
#define LAT_TAIL 8
#define ACT_TAIL 64
#define ISR_TAIL 192
#define MSK_TAIL 128
#define PK_TAIL 384
#define EV_TAIL 24
#define CTL_TAIL 128
#define PRE_TAIL 96
#define PREP_TAIL 32
#define PREP_STATS 8
#define LIVE_CTL 48
#define LIVE_PRE 48

#if defined(CONFIG_ZERO_LATENCY_IRQS)
#define HAVE_MSK 1
#else
#define HAVE_MSK 0
#endif

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

/* one controller scheduling step (enum lab_ctl_type, diag_lab.h) */
struct ctl_ev {
    uint32_t t_us;
    uint8_t type;
    uint8_t a;
    uint16_t b;
    uint32_t c;
    uint32_t d;
};

enum rec_kind { KIND_ASSERT = 0, KIND_MARK = 1 };

struct crash_rec {
    uint32_t magic;
    uint32_t seq;        /* breadcrumb seq of the boot that recorded */
    uint32_t idx;        /* 0-based record index */
    uint32_t kind;       /* enum rec_kind */
    uint32_t line;       /* assert line, or the ticker id of the late prepare */
    char file[FILE_LEN]; /* assert file tail, or "late" */
    uint32_t up_ms;
    uint32_t t_us;       /* the moment of the assert / the late check: dt = 0 in the printout */
    uint32_t cap_t_us;   /* when the rings were copied (= t_us for an assert) */
    uint32_t late_ticks; /* mark: ticks_now - ticks_at_event at the check */
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
#if HAVE_MSK
    uint32_t msk_n;
    struct msk_ev msk[MSK_TAIL];
#endif
    uint32_t pk_n;
    char pk[PK_TAIL];
    uint32_t ev_n;
    struct ev_out ev[EV_TAIL];
    uint32_t prep_n;
    struct prep_ev prep[PREP_TAIL];
    struct prep_stat pstat[PREP_STATS];
    uint32_t ctl_n;
    struct ctl_ev ctl[CTL_TAIL];
    uint32_t pre_n;
    struct ctl_ev pre[PRE_TAIL];
    struct lab_ticker_snap tk; /* mark records only (thread context) */
    uint32_t sum; /* FNV-1a over the record with sum = 0 */
};

struct labrec {
    /* kept across boots */
    uint32_t magic;
    uint32_t magic_inv;
    uint32_t crash_n;   /* records committed (<= CRASHES) */
    uint32_t dropped;   /* records after the slots were full */
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
#if HAVE_MSK
    uint32_t msk_head;
    uint32_t msk_samples;
    struct msk_ev msk[MSK_RING];
#endif
    uint32_t thr_n;
    char thr_name[THR_MAX][NAME_LEN];
    struct k_thread *thr_ptr[THR_MAX];
    uint32_t pk_head;
    char pk[PK_RING];
    uint32_t prep_head;
    struct prep_ev prep[PREP_RING];
    struct prep_stat pstat[PREP_STATS];
    uint32_t ctl_head;
    struct ctl_ev ctl[CTL_RING];
    uint32_t pre_head;
    struct ctl_ev pre[PRE_RING];
    /* v5: does a queued prepare get its preempt timeout started? (healthy) or not (the controller
     * believes one is pending: the stale state seen on 2026-10-09). Tracked per enqueue -> the
     * dequeued prepare runs; a change of state is a CT_FLIP entry and a record. */
    uint32_t pre_enq_pending;
    uint32_t pre_tstart_seen;
    uint32_t pre_state;  /* 0 unknown, 1 healthy, 2 stale */
    uint32_t flips;
    uint32_t stale_runs; /* dequeued prepares that ran without a preempt timeout having been started */
    uint32_t marks;     /* late prepares seen (records taken or dropped) */
    uint32_t mark_busy; /* a mark is waiting for its record */
    uint32_t mark_t_us;
    uint32_t mark_id;
    uint32_t mark_late;
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

static uint32_t fnv1a_step(uint32_t h, const void *p, size_t n) {
    const uint8_t *b = p;

    for (size_t i = 0; i < n; i++) {
        h ^= b[i];
        h *= 0x01000193u;
    }
    return h;
}

/* checksum of a record in place (no copy: the record is ~8 KB and the console thread's stack
 * is 2 KB; v1's copy on the stack faulted the device on every dump), skipping the sum field */
static uint32_t rec_sum(const struct crash_rec *c) {
    uint32_t h = 0x811c9dc5u;

    h = fnv1a_step(h, c, offsetof(struct crash_rec, sum));
    return h;
}

static inline uint32_t now_us(void) {
    NRF_TIMER4->TASKS_CAPTURE[3] = 1;
    return NRF_TIMER4->CC[3];
}

uint32_t diag_lab_now_us(void) { return now_us(); }

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

#if HAVE_MSK
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
#endif

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

/* ---- 10 kHz masked-region sampler (TIMER3, zero-latency IRQ; v2 only) ------------------------- */

#if HAVE_MSK
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
#endif

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

/* ---- controller scheduling trace and the prepare-latency check (fed by diag_lab_ctlr.c) ------- */

void diag_lab_ctl_put(uint8_t type, uint8_t a, uint16_t b, uint32_t c, uint32_t d) {
    struct labrec *r = REC;
    struct ctl_ev e;

    if (r->magic != LAB_MAGIC) {
        return;
    }
    e.t_us = now_us();
    e.type = type;
    e.a = a;
    e.b = b;
    e.c = c;
    e.d = d;
    r->ctl[r->ctl_head % CTL_RING] = e;
    r->ctl_head++;
    /* the sparse ring: everything about the preempt timeout and the pipeline, nothing routine
     * (a prepare that ran at once, its lateness check when on time, the pipeline runs) */
    switch (type) {
    case CT_PREPCALC:
        if (b == 0) { return; }
        break;
    case CT_PREP:
        if ((b & 3u) == 0u && d == 0u) { return; }
        break;
    case CT_DEQ:
    case CT_TUPD:
        return;
    default:
        break;
    }
    r->pre[r->pre_head % PRE_RING] = e;
    r->pre_head++;
    /* the preempt-timeout health state machine (see the labrec fields) */
    if (type == CT_ENQ) {
        r->pre_enq_pending = 1;
        r->pre_tstart_seen = 0;
    } else if (type == CT_TSTART && a == 0u) {
        r->pre_tstart_seen = 1;
    } else if (type == CT_PREP && (b & 2u) && r->pre_enq_pending) {
        uint32_t st = r->pre_tstart_seen ? 1u : 2u;

        r->pre_enq_pending = 0;
        if (st == 2u) {
            r->stale_runs++;
        }
        if (r->pre_state != 0u && st != r->pre_state) {
            struct ctl_ev f = { .t_us = now_us(), .type = CT_FLIP, .a = (st == 1u), .b = 0, .c = c, .d = r->stale_runs };

            r->flips++;
            r->ctl[r->ctl_head % CTL_RING] = f;
            r->ctl_head++;
            r->pre[r->pre_head % PRE_RING] = f;
            r->pre_head++;
            diag_lab_mark((st == 1u) ? 0xf2 : 0xf1, 0); /* a record: 0xf1 = became stale, 0xf2 = healthy again */
        }
        r->pre_state = st;
    }
}

void diag_lab_prep_put(uint8_t ticker_id, uint32_t ticks_at_event, uint32_t ticks_now, uint32_t result) {
    struct labrec *r = REC;
    struct prep_ev e;
    uint32_t late = (ticks_now - ticks_at_event) & 0x00ffffffu; /* RTC is 24-bit */
    struct prep_stat *s = NULL;

    if (r->magic != LAB_MAGIC) {
        return;
    }
    if (late & 0x00800000u) {
        late = 0; /* the event is still in the future */
    }
    e.t_us = now_us();
    e.ticks_at_event = ticks_at_event;
    e.ticks_now = ticks_now;
    e.result = result;
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
        if (result != 0u) { s->nonzero++; }
    }
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
        /* clear only the live part; the records and their counters stay */
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

#if HAVE_MSK
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
#endif
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

/* ---- records ---------------------------------------------------------------------------------- */

static void copy_tail_u8(void *dst, const void *ring, uint32_t esz, uint32_t ring_n, uint32_t head,
                         uint32_t tail_n, uint32_t *out_n) {
    uint32_t cnt = MIN(head, tail_n);
    uint32_t first = head - cnt;

    for (uint32_t i = 0; i < cnt; i++) {
        memcpy((uint8_t *)dst + i * esz, (const uint8_t *)ring + ((first + i) % ring_n) * esz, esz);
    }
    *out_n = cnt;
}

/* fill the next free record from the rings; returns NULL when the slots are full (dropped++) */
static struct crash_rec *take_record(uint32_t kind, const char *file, uint32_t line, uint32_t t_us) {
    struct labrec *r = REC;
    struct crash_rec *c;
    size_t len = file ? strlen(file) : 0;
    uint8_t ti;

    if (r->magic != LAB_MAGIC || r->crash_n >= CRASHES) {
        if (r->magic == LAB_MAGIC) {
            r->dropped++;
            __DSB();
        }
        return NULL;
    }
    c = &r->crash[r->crash_n];
    memset(c, 0, sizeof(*c));
    c->magic = LAB_MAGIC;
    c->seq = diag_entry_seq();
    c->idx = r->crash_n;
    c->kind = kind;
    c->line = line;
    if (len > 0) {
        const char *tail = (len > FILE_LEN - 1) ? file + len - (FILE_LEN - 1) : file;
        strncpy(c->file, tail, FILE_LEN - 1);
    }
    c->up_ms = r->base_ms + r->ticks;
    c->t_us = t_us;
    c->cap_t_us = now_us();
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
#if HAVE_MSK
    copy_tail_u8(c->msk, r->msk, sizeof(struct msk_ev), MSK_RING, r->msk_head, MSK_TAIL, &c->msk_n);
#endif
    copy_tail_u8(c->pk, r->pk, 1, PK_RING, r->pk_head, PK_TAIL, &c->pk_n);
    c->ev_n = diag_min_events_tail(c->ev, EV_TAIL);
    copy_tail_u8(c->prep, r->prep, sizeof(struct prep_ev), PREP_RING, r->prep_head, PREP_TAIL, &c->prep_n);
    memcpy(c->pstat, r->pstat, sizeof(c->pstat));
    copy_tail_u8(c->ctl, r->ctl, sizeof(struct ctl_ev), CTL_RING, r->ctl_head, CTL_TAIL, &c->ctl_n);
    copy_tail_u8(c->pre, r->pre, sizeof(struct ctl_ev), PRE_RING, r->pre_head, PRE_TAIL, &c->pre_n);
    return c;
}

static void commit_record(struct crash_rec *c) {
    struct labrec *r = REC;

    c->sum = rec_sum(c);
    __DSB();
    r->crash_n++;
    __DSB();
}

void bt_ctlr_assert_handle(char *file, uint32_t line) {
    struct crash_rec *c = take_record(KIND_ASSERT, file, line, now_us());

    if (c != NULL) {
        commit_record(c);
    }
    k_oops();
}

/* a late prepare: the wrapper runs in the LLL's ISR, so only mark here and fill the record from
 * the system work queue (an 8 KB copy inside the radio ISR would itself delay the controller) */
static void mark_work_fn(struct k_work *w) {
    struct labrec *r = REC;
    struct crash_rec *c;

    ARG_UNUSED(w);
    c = take_record(KIND_MARK, "late", r->mark_id, r->mark_t_us);
    if (c != NULL) {
        c->late_ticks = r->mark_late;
        diag_lab_ticker_snapshot(&c->tk); /* asks the ticker job; a few ms */
        commit_record(c);
    }
    r->mark_busy = 0;
    __DSB();
}
static K_WORK_DEFINE(mark_work, mark_work_fn);

void diag_lab_mark(uint8_t ticker_id, uint32_t late_ticks) {
    struct labrec *r = REC;

    if (r->magic != LAB_MAGIC) {
        return;
    }
    r->marks++;
    diag_lab_ctl_put(CT_MARK, ticker_id, 0, late_ticks, 0);
    if (r->mark_busy) {
        return; /* one at a time; the counter keeps the rest */
    }
    r->mark_busy = 1;
    r->mark_t_us = now_us();
    r->mark_id = ticker_id;
    r->mark_late = late_ticks;
    __DSB();
    k_work_submit(&mark_work);
}

/* ---- console output --------------------------------------------------------------------------- */

static const char *thr_of(const char names[][NAME_LEN], uint32_t n, uint8_t i) {
    return (i < THR_MAX && i < n) ? names[i] : "?";
}

static const char *ctl_name(uint8_t t) {
    switch (t) {
    case CT_PREPCALC: return "prepcalc";
    case CT_PREP: return "prepare";
    case CT_TSTART: return "tstart";
    case CT_TSTOP: return "tstop";
    case CT_TSTART_OP: return "tstart-op";
    case CT_TSTOP_OP: return "tstop-op";
    case CT_PREEMPT: return "preempt";
    case CT_ISABORT: return "is-abort";
    case CT_ABORT: return "abort";
    case CT_ENQ: return "enqueue";
    case CT_DEQ: return "dequeue";
    case CT_TUPD: return "tupdate";
    case CT_MARK: return "MARK";
    case CT_FLIP: return "FLIP";
    default: return "?";
    }
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

#if HAVE_MSK
static void print_msk(void (*out)(const char *fmt, ...), const char *tag, const struct msk_ev *m, uint32_t n,
                      uint32_t t_ref) {
    for (uint32_t i = 0; i < n; i++) {
        out("ZDIAG lab %s dt=%d pc=%x bp=%u pm=%u ipsr=%u iabr=%x/%x", tag, (int32_t)(m[i].t_us - t_ref),
            m[i].pc, m[i].basepri, m[i].primask, m[i].ipsr, m[i].iabr0, m[i].iabr1l);
    }
}
#endif

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

static void print_ctl(void (*out)(const char *fmt, ...), const char *tag, const struct ctl_ev *e, uint32_t n,
                      uint32_t t_ref) {
    for (uint32_t i = 0; i < n; i++) {
        out("ZDIAG lab %s dt=%d %s a=%u b=%x c=%u d=%u", tag, (int32_t)(e[i].t_us - t_ref), ctl_name(e[i].type),
            e[i].a, e[i].b, e[i].c, e[i].d);
    }
}

static void print_crash(void (*out)(const char *fmt, ...), const struct crash_rec *c) {
    char tag[16], t2[24];
    uint32_t sum = rec_sum(c);

    snprintk(tag, sizeof(tag), "crash%u", c->idx);
    out("ZDIAG lab %s seq=%u kind=%s line=%u file=%s up=%u t=%u cap=%u late=%u ipsr=%u iabr=%x/%x pc=%x lr=%x xpsr=%x thr=%s sum=%s",
        tag, c->seq, (c->kind == KIND_MARK) ? "late" : "assert", c->line, c->file, c->up_ms, c->t_us, c->cap_t_us,
        c->late_ticks, c->ipsr, c->iabr0, c->iabr1, c->pc, c->lr, c->xpsr, c->thr, (sum == c->sum) ? "ok" : "BAD");
    out("ZDIAG lab %sstat max=%u over=%u/%u/%u/%u skipped=%u nlat=%u ticker=%u rtc0=%u nvmc=%x/%x", tag,
        c->max_us, c->over[0], c->over[1], c->over[2], c->over[3], c->skipped, c->n_lat, c->ctlr.ticker_now,
        c->ctlr.rtc0_counter, c->ctlr.nvmc_config, c->ctlr.nvmc_ready);
    for (uint32_t h = 0; h < LAB_CONN_MAX; h++) {
        const struct lab_conn_snap *s = &c->ctlr.conn[h];

        out("ZDIAG lab %sconn h=%u valid=%u connected=%u role=%u interval=%u latency=%u lat_prep=%u lazy_prep=%u lat_ev=%u evcnt=%u forced=%u sv_exp=%u conn_exp=%u sv_to=%u prep2start=%x slot=%u",
            tag, h, s->valid, s->connected, s->role, s->interval, s->latency, s->latency_prepare, s->lazy_prepare,
            s->latency_event, s->event_counter, s->forced, s->supervision_expire, s->connect_expire,
            s->supervision_timeout, s->ticks_prepare_to_start, s->ticks_slot);
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
    snprintk(t2, sizeof(t2), "%sctl", tag);
    print_ctl(out, t2, c->ctl, MIN(c->ctl_n, (uint32_t)CTL_TAIL), c->t_us);
    snprintk(t2, sizeof(t2), "%spre", tag);
    print_ctl(out, t2, c->pre, MIN(c->pre_n, (uint32_t)PRE_TAIL), c->t_us);
    {
        char line[160];
        int k = snprintk(line, sizeof(line), "ZDIAG lab %stk cur=%u n=%u", tag, c->tk.ticks_current, c->tk.n);

        for (uint32_t i = 0; i < MIN(c->tk.n, (uint32_t)LAB_TICKERS); i++) {
            k += snprintk(line + k, sizeof(line) - k, " %u:%u", c->tk.t[i].id, c->tk.t[i].ticks_to_expire);
        }
        out("%s", line);
    }
    snprintk(t2, sizeof(t2), "%sact", tag);
    print_act(out, t2, c->thr_name, c->thr_n, c->act, MIN(c->act_n, (uint32_t)ACT_TAIL));
    snprintk(t2, sizeof(t2), "%sisr", tag);
    print_isr(out, t2, c->thr_name, c->thr_n, c->isr, MIN(c->isr_n, (uint32_t)ISR_TAIL), c->t_us);
#if HAVE_MSK
    snprintk(t2, sizeof(t2), "%smsk", tag);
    print_msk(out, t2, c->msk, MIN(c->msk_n, (uint32_t)MSK_TAIL), c->t_us);
#endif
    snprintk(t2, sizeof(t2), "%spk", tag);
    print_text(out, t2, c->pk, MIN(c->pk_n, (uint32_t)PK_TAIL));
}

void diag_lab_print(void (*out)(const char *fmt, ...)) {
    const struct labrec *r = REC;

    if (r->magic != LAB_MAGIC || r->magic_inv != ~LAB_MAGIC) {
        out("ZDIAG lab invalid");
        return;
    }
    out("ZDIAG lab live v5 ticks=%u skipped=%u max=%u@%u over=%u/%u/%u/%u nlat=%u isr=%u ctl=%u thr=%u marks=%u crashes=%u dropped=%u prestate=%u flips=%u stale_runs=%u",
        r->ticks, r->skipped, r->max_us, r->max_at_ms, r->over[0], r->over[1], r->over[2], r->over[3], r->n_lat,
        r->isr_head, r->ctl_head, r->thr_n, r->marks, r->crash_n, r->dropped, r->pre_state, r->flips, r->stale_runs);
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
        /* live prepare stats and the last checks (the margin every radio event has right now) */
        struct prep_ev tail[PREP_TAIL];
        uint32_t n;

        copy_tail_u8(tail, r->prep, sizeof(struct prep_ev), PREP_RING, r->prep_head, PREP_TAIL, &n);
        print_prep(out, "liveprep", r->pstat, tail, n, now_us());
    }
    {
        /* the last controller scheduling steps, newest last; dt relative to now */
        struct ctl_ev tail[LIVE_CTL];
        uint32_t n;

        copy_tail_u8(tail, r->ctl, sizeof(struct ctl_ev), CTL_RING, r->ctl_head, LIVE_CTL, &n);
        print_ctl(out, "livectl", tail, n, now_us());
        copy_tail_u8(tail, r->pre, sizeof(struct ctl_ev), PRE_RING, r->pre_head, LIVE_PRE, &n);
        print_ctl(out, "livepre", tail, n, now_us());
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

/* console 'M': the mark path (a record without a reboot), ticker id 0xee, late 4242 */
void diag_lab_marktest(void) {
    diag_lab_mark(0xee, 4242);
}

void diag_lab_clear(void) {
    struct labrec *r = REC;

    memset(r->crash, 0, sizeof(r->crash));
    r->crash_n = 0;
    r->dropped = 0;
    __DSB();
}
