/*
 * Boot-path instrument, version 3 (test builds only, never for production).
 *
 * RECORDS (RAM that survives soft and pin resets; the bootloader uses 0x20008000.. for its data
 * and the top of RAM for its stack, these records sit in between and survived 112 b/UF2 cycles):
 *  cur   the boot in progress
 *  last  the previous boot (overwritten every boot; normal-cycle log)
 *  ring  up to RING_SLOTS incident records, never overwritten (new incidents counted in dropped)
 *
 * Each record carries: magic, format version, seq, build tag, boot_done (0/1), reason, phase,
 * entry snapshot (taken in board_early_init_hook: after .bss/.data init, NOT the hand-over
 * instant), stage cycle stamps, monitor counters, and, when the net fired, the interrupted context.
 *
 * STATE TRANSITIONS (what the next boot files as an incident):
 *   event                          boot_done  reason        filed as incident?
 *   normal boot, then r/b          1          REBOOT_REQ    no
 *   normal boot, then pin reset    1          NONE          no
 *   boot never reached RUNNING,
 *     net fired                    0          BOOT_TIMEOUT  yes
 *     pin reset pressed            0          NONE          yes (INCOMPLETE)
 *     armed stall ('S') + net      0          BOOT_TIMEOUT  yes (calib_flag=1)
 *   RUNNING, monitor timed out     1          WQ_TIMEOUT    yes
 *   RUNNING, h/G then net fired    1          WQ_TIMEOUT    yes (calib_flag=h/G)
 *   RUNNING, H (no fire)           1          NONE          no
 *   record invalid (magic/CRC)     -          -             counted in ring.invalid, not filed
 *   Rule: filed iff reason in {BOOT_TIMEOUT, WQ_TIMEOUT} or (boot_done == 0 and reason != REBOOT_REQ).
 *
 * MONITORS (TIMER4, 16 MHz / 2^9, independent of the 32 kHz clock):
 *  boot monitor   hard deadline BOOT_DEADLINE_S from the early hook until RUNNING. RUNNING means
 *                 main() has returned (k_thread_join(&z_main_thread) == 0: ZMK's main() returns
 *                 after settings_load(), so the whole load completed) AND the first probe ran on
 *                 the system workqueue. Stage markers never feed the net during boot.
 *  workqueue      after RUNNING, the feeder thread (preemptible, K_PRIO_PREEMPT(10)) submits a
 *  monitor        probe to the system workqueue every PROBE_PERIOD_S and feeds the net only when
 *                 the previous probe ran. Deadline WQ_DEADLINE_S without a feed. A timeout means
 *                 "the monitor's own progress stopped" (probe not run, OR the feeder thread itself
 *                 starved by a higher-priority spinner), not necessarily "the system workqueue
 *                 stalled": the saved PC/thread decide.
 *  The ISR writes plain memory (no locks, no logging) then NVIC_SystemReset(). The vector is a
 *  naked function wired directly into the vector table, so EXC_RETURN/MSP/PSP are read before any
 *  prologue; the frame (r0-r3,r12,lr,pc,xpsr) is taken from the stack EXC_RETURN bit 2 selects.
 *  EXC_RETURN bit 3 = 0 means another handler was interrupted: then PC is inside that handler and
 *  the record is "unclassifiable", never "not USB".
 *
 * CALIBRATION (console commands; test builds only):
 *  h  spin forever on the system workqueue (cooperative)      -> WQ_TIMEOUT, PC in diag_spin_forever,
 *                                                                 thread == &k_sys_work_q.thread
 *  H  spin forever in a preemptible thread at K_PRIO_PREEMPT(12) (lower than the feeder) -> no fire
 *  G  spin forever in a preemptible thread at K_PRIO_PREEMPT(0)  (starves the feeder)    -> WQ_TIMEOUT,
 *                                                                 thread == &calib_thread (monitor
 *                                                                 limit, not a workqueue stall)
 *  S  arm a stall for the NEXT boot (SYS_INIT APPLICATION 50 spins) -> BOOT_TIMEOUT at 20 s
 *  c  clear the ring (after the incidents were copied out)
 */

#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/irq.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/crc.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/util.h>
#include <cmsis_core.h>
#include <nrf.h>

#ifndef CORON_BUILD_TAG
#define CORON_BUILD_TAG "untagged"
#endif

/* The kernel's main thread object (kernel/init.c); not in a public header. k_thread_join() on it
 * returns 0 once main() has returned. */
extern struct k_thread z_main_thread;

#define REC_MAGIC 0x33544f42u  /* 'BOT3' */
#define RING_MAGIC 0x474e4952u /* 'RING' */
#define ARM_MAGIC 0x4c415453u  /* 'STAL' */
#define REC_FMT_VER 3
#define RING_SLOTS 4

#define BOOT_DEADLINE_S 20
#define WQ_DEADLINE_S 15
#define PROBE_PERIOD_S 2
#define NET_HZ 31250 /* 16 MHz / 2^9 */
#define CYC_PER_US 64

enum boot_stage {
    STG_HOOK = 0,
    STG_PK1_EARLY,
    STG_PK1_AFTER_CLK,
    STG_PK1_LAST,
    STG_PK2_AFTER_SYSCLK,
    STG_POST,
    STG_APP_EARLY,
    STG_APP_AFTER_USB,
    STG_APP_LAST,
    STG_SETTINGS_COMMIT, /* our static settings handler's commit ran (settings_load in progress) */
    STG_MAIN_DONE,       /* main() returned (settings_load completed) */
    STG_WQ_PROBED,       /* first probe ran on the system workqueue */
    STG_RUNNING,         /* MAIN_DONE and WQ_PROBED: boot monitor off, workqueue monitor on */
    STG_COUNT,
};

enum phase { PH_BOOT = 0, PH_RUNNING = 1 };

enum reason {
    R_NONE = 0,
    R_BOOT_TIMEOUT = 1,
    R_WQ_TIMEOUT = 2,
    R_REBOOT_REQ = 3,
};

struct entry_snap {
    uint32_t lfclkstat, lfclkrun, lfclksrc, lfclksrccopy, ev_lfstarted;
    uint32_t hfclkstat, hfclkrun, ev_hfstarted;
    uint32_t rtc1_counter, resetreas, usbregstatus;
    uint32_t ficr_130, ficr_134; /* what nrf52_errata_187() reads */
};

struct fire_info {
    uint32_t exc_return, msp, psp, frame_sp;
    uint32_t pc, lr, xpsr;
    uint32_t in_handler;
    uint32_t cur_thread;
    uint32_t usbd_enable, usbd_eventcause, usbd_usbpullup, usbregstatus;
    uint32_t lfclkstat, lfclkrun, hfclkstat, hfclkrun;
    uint32_t timer4_cc0, fire_cyc;
};

struct boot_rec {
    uint32_t magic;
    uint32_t fmt_ver;
    uint32_t seq;
    char build_tag[40];
    uint32_t boot_done; /* 1 once RUNNING was reached */
    uint32_t reason;    /* enum reason */
    uint32_t phase;     /* enum phase */
    uint32_t calib;     /* 0, or the calibration command character that was issued ('h','H','G','S') */
    struct entry_snap entry;
    uint32_t stage;
    uint32_t stage_cyc[STG_COUNT];
    uint32_t fix_action, fix_us, hf_action;
    uint32_t probes_submitted, probes_run, feeds, feeder_loops, last_feed_cyc;
    struct fire_info fire;
    uint32_t crc;
};

struct ring_rec {
    uint32_t magic;
    uint32_t count;   /* incidents stored (<= RING_SLOTS) */
    uint32_t dropped; /* incidents not stored because the ring was full */
    uint32_t invalid; /* previous-boot records that failed magic/CRC (not filed) */
    struct boot_rec slot[RING_SLOTS];
    uint32_t crc;
};

struct arm_rec {
    uint32_t magic; /* ARM_MAGIC = stall the next boot (consumed by the hook) */
    uint32_t crc;
};

static struct boot_rec cur __noinit;
static struct boot_rec last __noinit;
static struct ring_rec ring __noinit;
static struct arm_rec arm_next __noinit;
static bool last_valid;
static bool stall_this_boot;

static uint32_t rec_crc(const struct boot_rec *r) {
    return crc32_ieee((const uint8_t *)r, offsetof(struct boot_rec, crc));
}
static uint32_t ring_crc(const struct ring_rec *r) {
    return crc32_ieee((const uint8_t *)r, offsetof(struct ring_rec, crc));
}
static bool rec_valid(const struct boot_rec *r) {
    return r->magic == REC_MAGIC && r->fmt_ver == REC_FMT_VER && r->crc == rec_crc(r);
}
static void rec_seal(void) { cur.crc = rec_crc(&cur); }
static inline uint32_t cyc(void) { return DWT->CYCCNT; }

/* ---- TIMER4 net ---------------------------------------------------------------------------- */

static void net_feed(void) {
    NRF_TIMER4->TASKS_CLEAR = 1;
    cur.feeds++;
    cur.last_feed_cyc = cyc();
}

static void net_set_deadline(uint32_t seconds) {
    NRF_TIMER4->TASKS_STOP = 1;
    NRF_TIMER4->CC[0] = seconds * NET_HZ;
    NRF_TIMER4->EVENTS_COMPARE[0] = 0;
    NRF_TIMER4->TASKS_CLEAR = 1;
    NRF_TIMER4->TASKS_START = 1;
}

/* Reached from the naked vector with EXC_RETURN, MSP and PSP as at exception entry. Never returns. */
void boot_net_fire(uint32_t exc_return, uint32_t msp, uint32_t psp) {
    NRF_TIMER4->TASKS_STOP = 1;
    NRF_TIMER4->EVENTS_COMPARE[0] = 0;

    struct fire_info *f = &cur.fire;
    f->exc_return = exc_return;
    f->msp = msp;
    f->psp = psp;
    const uint32_t *frame = (const uint32_t *)((exc_return & BIT(2)) ? psp : msp);
    f->frame_sp = (uint32_t)frame;
    f->lr = frame[5];
    f->pc = frame[6];
    f->xpsr = frame[7];
    f->in_handler = (exc_return & BIT(3)) ? 0 : 1;
    f->cur_thread = (uint32_t)k_current_get();
    f->usbd_enable = NRF_USBD->ENABLE;
    f->usbd_eventcause = NRF_USBD->EVENTCAUSE;
    f->usbd_usbpullup = NRF_USBD->USBPULLUP;
    f->usbregstatus = NRF_POWER->USBREGSTATUS;
    f->lfclkstat = NRF_CLOCK->LFCLKSTAT;
    f->lfclkrun = NRF_CLOCK->LFCLKRUN;
    f->hfclkstat = NRF_CLOCK->HFCLKSTAT;
    f->hfclkrun = NRF_CLOCK->HFCLKRUN;
    f->timer4_cc0 = NRF_TIMER4->CC[0];
    f->fire_cyc = cyc();

    cur.reason = (cur.phase == PH_BOOT) ? R_BOOT_TIMEOUT : R_WQ_TIMEOUT;
    rec_seal();
    NVIC_SystemReset();
    for (;;) {
    }
}

__attribute__((naked)) void boot_net_vector(void) {
    __asm volatile("mov r0, lr\n"
                   "mrs r1, msp\n"
                   "mrs r2, psp\n"
                   "b boot_net_fire\n");
}

static void net_arm(void) {
    NRF_TIMER4->TASKS_STOP = 1;
    NRF_TIMER4->MODE = TIMER_MODE_MODE_Timer;
    NRF_TIMER4->BITMODE = TIMER_BITMODE_BITMODE_32Bit;
    NRF_TIMER4->PRESCALER = 9;
    NRF_TIMER4->INTENSET = TIMER_INTENSET_COMPARE0_Msk;
    net_set_deadline(BOOT_DEADLINE_S);

    IRQ_DIRECT_CONNECT(TIMER4_IRQn, 1, boot_net_vector, 0);
    /* Priority 0 is below Zephyr's BASEPRI lock level (irq_lock masks 1 and lower). */
    NVIC_SetPriority(TIMER4_IRQn, 0);
    NVIC_ClearPendingIRQ(TIMER4_IRQn);
    NVIC_EnableIRQ(TIMER4_IRQn);
}

/* ---- stages ---------------------------------------------------------------------------------- */

static void stage(enum boot_stage s) {
    cur.stage = s;
    cur.stage_cyc[s] = cyc();
    rec_seal();
}

static void maybe_running(void) {
    if (cur.phase == PH_RUNNING) {
        return;
    }
    if (cur.stage_cyc[STG_MAIN_DONE] != 0 && cur.stage_cyc[STG_WQ_PROBED] != 0) {
        stage(STG_RUNNING);
        cur.phase = PH_RUNNING;
        cur.boot_done = 1;
        net_set_deadline(WQ_DEADLINE_S);
        rec_seal();
    }
}

/* ---- optional intervention (comparison arm only, off by default) ---------------------------- */

#if IS_ENABLED(CONFIG_CORON_DIAG_BOOT_FIX)
enum fix_action { FIX_NONE = 0, FIX_ALREADY_STOPPED = 1, FIX_STOPPED_OK = 2, FIX_STOP_TIMEOUT = 3 };

#define WAIT_US(pred, max_us)                                                                     \
    ({                                                                                             \
        uint32_t _t0 = cyc();                                                                      \
        bool _ok;                                                                                  \
        while (!(_ok = (pred)) && (cyc() - _t0) < (uint32_t)(max_us) * CYC_PER_US) {               \
        }                                                                                          \
        _ok;                                                                                       \
    })

static void lf_clean_stop(void) {
    uint32_t t0 = cyc();

    if (NRF_CLOCK->LFCLKSTAT & CLOCK_LFCLKSTAT_STATE_Msk) {
        NRF_CLOCK->TASKS_LFCLKSTOP = 1;
        cur.fix_action = WAIT_US((NRF_CLOCK->LFCLKSTAT & CLOCK_LFCLKSTAT_STATE_Msk) == 0, 2000)
                             ? FIX_STOPPED_OK
                             : FIX_STOP_TIMEOUT;
    } else {
        cur.fix_action = FIX_ALREADY_STOPPED;
    }
    NRF_CLOCK->EVENTS_LFCLKSTARTED = 0;

    if ((NRF_CLOCK->HFCLKSTAT & CLOCK_HFCLKSTAT_STATE_Msk) &&
        (NRF_CLOCK->HFCLKSTAT & CLOCK_HFCLKSTAT_SRC_Msk)) {
        NRF_CLOCK->TASKS_HFCLKSTOP = 1;
        cur.hf_action = WAIT_US((NRF_CLOCK->HFCLKSTAT & CLOCK_HFCLKSTAT_STATE_Msk) == 0, 2000)
                            ? FIX_STOPPED_OK
                            : FIX_STOP_TIMEOUT;
    } else {
        cur.hf_action = FIX_ALREADY_STOPPED;
    }
    NRF_CLOCK->EVENTS_HFCLKSTARTED = 0;
    (void)WAIT_US(false, 300);
    cur.fix_us = (cyc() - t0) / CYC_PER_US;
}
#endif

/* ---- early hook: file the previous boot, start this one ------------------------------------- */

static void ring_init_if_needed(void) {
    if (ring.magic == RING_MAGIC && ring.count <= RING_SLOTS && ring.crc == ring_crc(&ring)) {
        return;
    }
    memset(&ring, 0, sizeof(ring));
    ring.magic = RING_MAGIC;
    ring.crc = ring_crc(&ring);
}

static void ring_push(const struct boot_rec *r) {
    if (ring.count < RING_SLOTS) {
        ring.slot[ring.count++] = *r;
    } else {
        ring.dropped++;
    }
    ring.crc = ring_crc(&ring);
}

static bool is_incident(const struct boot_rec *r) {
    if (r->reason == R_BOOT_TIMEOUT || r->reason == R_WQ_TIMEOUT) {
        return true;
    }
    return r->boot_done == 0 && r->reason != R_REBOOT_REQ;
}

void board_early_init_hook(void) {
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;

    ring_init_if_needed();

    uint32_t seq = 1;
    if (rec_valid(&cur)) {
        last = cur;
        last_valid = true;
        seq = cur.seq + 1;
        if (is_incident(&cur)) {
            ring_push(&cur);
        }
    } else {
        memset(&last, 0, sizeof(last));
        last_valid = false;
        if (cur.magic == REC_MAGIC) { /* a record of ours that failed the CRC */
            ring.invalid++;
            ring.crc = ring_crc(&ring);
        }
    }

    /* 'S' armed a stall for this boot: consume the flag so the stall happens once. */
    stall_this_boot = (arm_next.magic == ARM_MAGIC &&
                       arm_next.crc == crc32_ieee((const uint8_t *)&arm_next, sizeof(uint32_t)));
    arm_next.magic = 0;

    memset(&cur, 0, sizeof(cur));
    cur.magic = REC_MAGIC;
    cur.fmt_ver = REC_FMT_VER;
    cur.seq = seq;
    strncpy(cur.build_tag, CORON_BUILD_TAG, sizeof(cur.build_tag) - 1);
    cur.phase = PH_BOOT;
    cur.calib = stall_this_boot ? 'S' : 0;

    cur.entry.lfclkstat = NRF_CLOCK->LFCLKSTAT;
    cur.entry.lfclkrun = NRF_CLOCK->LFCLKRUN;
    cur.entry.lfclksrc = NRF_CLOCK->LFCLKSRC;
    cur.entry.lfclksrccopy = NRF_CLOCK->LFCLKSRCCOPY;
    cur.entry.ev_lfstarted = NRF_CLOCK->EVENTS_LFCLKSTARTED;
    cur.entry.hfclkstat = NRF_CLOCK->HFCLKSTAT;
    cur.entry.hfclkrun = NRF_CLOCK->HFCLKRUN;
    cur.entry.ev_hfstarted = NRF_CLOCK->EVENTS_HFCLKSTARTED;
    cur.entry.rtc1_counter = NRF_RTC1->COUNTER;
    cur.entry.resetreas = NRF_POWER->RESETREAS;
    cur.entry.usbregstatus = NRF_POWER->USBREGSTATUS;
    cur.entry.ficr_130 = *(volatile uint32_t *)0x10000130ul;
    cur.entry.ficr_134 = *(volatile uint32_t *)0x10000134ul;

    net_arm();

#if IS_ENABLED(CONFIG_CORON_DIAG_BOOT_FIX)
    lf_clean_stop();
#endif

    stage(STG_HOOK);
}

__attribute__((noinline)) void diag_spin_forever(void) {
    for (;;) {
        __asm volatile("nop");
    }
}

static int st_pk1_early(void) { stage(STG_PK1_EARLY); return 0; }
SYS_INIT(st_pk1_early, PRE_KERNEL_1, 1);
static int st_pk1_after_clk(void) { stage(STG_PK1_AFTER_CLK); return 0; }
SYS_INIT(st_pk1_after_clk, PRE_KERNEL_1, 31);
static int st_pk1_last(void) { stage(STG_PK1_LAST); return 0; }
SYS_INIT(st_pk1_last, PRE_KERNEL_1, 99);
static int st_pk2_after_sysclk(void) { stage(STG_PK2_AFTER_SYSCLK); return 0; }
SYS_INIT(st_pk2_after_sysclk, PRE_KERNEL_2, 2);
static int st_post(void) { stage(STG_POST); return 0; }
SYS_INIT(st_post, POST_KERNEL, 0);
static int st_app_early(void) { stage(STG_APP_EARLY); return 0; }
SYS_INIT(st_app_early, APPLICATION, 1);

/* Calibration of the boot monitor: when armed by 'S', stall here (before USB init at 96). */
static int st_armed_stall(void) {
    if (stall_this_boot) {
        diag_spin_forever();
    }
    return 0;
}
SYS_INIT(st_armed_stall, APPLICATION, 50);

static int st_app_after_usb(void) { stage(STG_APP_AFTER_USB); return 0; }
SYS_INIT(st_app_after_usb, APPLICATION, 97);
static int st_app_last(void) { stage(STG_APP_LAST); return 0; }
SYS_INIT(st_app_last, APPLICATION, 99);

/* Intermediate marker only: this handler's commit ran, which does not mean settings_load()
 * finished (later handlers may still stall). RUNNING uses STG_MAIN_DONE instead. */
static int diag_settings_commit(void) {
    stage(STG_SETTINGS_COMMIT);
    return 0;
}
SETTINGS_STATIC_HANDLER_DEFINE(coron_diag_boot, "cdiagb", NULL, NULL, diag_settings_commit, NULL);

/* ---- workqueue monitor ---------------------------------------------------------------------- */

static void probe_fn(struct k_work *w) {
    ARG_UNUSED(w);
    cur.probes_run++;
    if (cur.stage_cyc[STG_WQ_PROBED] == 0) {
        stage(STG_WQ_PROBED);
    }
    rec_seal();
}
K_WORK_DEFINE(probe_work, probe_fn);

static void feeder_fn(void *a, void *b, void *c) {
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
    uint32_t seen = 0;

    for (;;) {
        cur.feeder_loops++;
        if (cur.stage_cyc[STG_MAIN_DONE] == 0 && k_thread_join(&z_main_thread, K_NO_WAIT) == 0) {
            stage(STG_MAIN_DONE); /* main() returned: settings_load() completed */
        }
        maybe_running();
        if (cur.phase == PH_RUNNING && cur.probes_run != seen) {
            seen = cur.probes_run;
            net_feed();
        }
        cur.probes_submitted++;
        k_work_submit(&probe_work);
        rec_seal();
        k_sleep(K_SECONDS(PROBE_PERIOD_S));
    }
}
K_THREAD_DEFINE(diag_feeder, 768, feeder_fn, NULL, NULL, NULL, K_PRIO_PREEMPT(10), 0, 500);

/* ---- console hooks -------------------------------------------------------------------------- */

void diag_boot_reboot(void) {
    cur.reason = R_REBOOT_REQ;
    rec_seal();
    sys_reboot(SYS_REBOOT_WARM);
}

void diag_boot_mark_reboot(void) {
    cur.reason = R_REBOOT_REQ;
    rec_seal();
}

static void calib_coop_fn(struct k_work *w) {
    ARG_UNUSED(w);
    diag_spin_forever();
}
K_WORK_DEFINE(calib_coop_work, calib_coop_fn);

static void calib_thread_fn(void *a, void *b, void *c) {
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
    diag_spin_forever();
}
static K_THREAD_STACK_DEFINE(calib_stack, 512);
struct k_thread calib_thread; /* global so nm resolves the thread pointer */

void diag_boot_calibrate(char which) {
    cur.calib = (uint32_t)which;
    rec_seal();
    switch (which) {
    case 'h':
        k_work_submit(&calib_coop_work);
        break;
    case 'H':
        k_thread_create(&calib_thread, calib_stack, K_THREAD_STACK_SIZEOF(calib_stack),
                        calib_thread_fn, NULL, NULL, NULL, K_PRIO_PREEMPT(12), 0, K_NO_WAIT);
        break;
    case 'G':
        k_thread_create(&calib_thread, calib_stack, K_THREAD_STACK_SIZEOF(calib_stack),
                        calib_thread_fn, NULL, NULL, NULL, K_PRIO_PREEMPT(0), 0, K_NO_WAIT);
        break;
    case 'S':
        arm_next.magic = ARM_MAGIC;
        arm_next.crc = crc32_ieee((const uint8_t *)&arm_next, sizeof(uint32_t));
        break;
    default:
        break;
    }
}

static void print_rec(void (*out)(const char *fmt, ...), const char *tag, const struct boot_rec *r) {
    out("ZBOOT %s seq=%u tag=%s done=%u reason=%u phase=%u calib=%c stage=%u reset=0x%x "
        "fix=%u/%u/%u probes=%u/%u feeds=%u loops=%u lastfeed_us=%u",
        tag, r->seq, r->build_tag, r->boot_done, r->reason, r->phase, r->calib ? (char)r->calib : '-',
        r->stage, r->entry.resetreas, r->fix_action, r->fix_us, r->hf_action, r->probes_submitted,
        r->probes_run, r->feeds, r->feeder_loops, r->last_feed_cyc / CYC_PER_US);
    out("ZBOOT %s entry lfstat=0x%x lfrun=%u lfsrc=0x%x lfcopy=0x%x lfev=%u hfstat=0x%x hfrun=%u "
        "hfev=%u rtc1=%u usbreg=0x%x ficr130=0x%x ficr134=0x%x",
        tag, r->entry.lfclkstat, r->entry.lfclkrun, r->entry.lfclksrc, r->entry.lfclksrccopy,
        r->entry.ev_lfstarted, r->entry.hfclkstat, r->entry.hfclkrun, r->entry.ev_hfstarted,
        r->entry.rtc1_counter, r->entry.usbregstatus, r->entry.ficr_130, r->entry.ficr_134);
    out("ZBOOT %s us hook=%u pk1=%u clk=%u pk1end=%u sysclk=%u post=%u app=%u usb=%u applast=%u "
        "commit=%u maindone=%u probed=%u running=%u",
        tag, r->stage_cyc[STG_HOOK] / CYC_PER_US, r->stage_cyc[STG_PK1_EARLY] / CYC_PER_US,
        r->stage_cyc[STG_PK1_AFTER_CLK] / CYC_PER_US, r->stage_cyc[STG_PK1_LAST] / CYC_PER_US,
        r->stage_cyc[STG_PK2_AFTER_SYSCLK] / CYC_PER_US, r->stage_cyc[STG_POST] / CYC_PER_US,
        r->stage_cyc[STG_APP_EARLY] / CYC_PER_US, r->stage_cyc[STG_APP_AFTER_USB] / CYC_PER_US,
        r->stage_cyc[STG_APP_LAST] / CYC_PER_US, r->stage_cyc[STG_SETTINGS_COMMIT] / CYC_PER_US,
        r->stage_cyc[STG_MAIN_DONE] / CYC_PER_US, r->stage_cyc[STG_WQ_PROBED] / CYC_PER_US,
        r->stage_cyc[STG_RUNNING] / CYC_PER_US);
    if (r->fire.exc_return != 0) {
        const struct fire_info *f = &r->fire;
        out("ZBOOT %s fire exc=0x%x msp=0x%x psp=0x%x frame=0x%x pc=0x%x lr=0x%x xpsr=0x%x "
            "handler=%u thread=0x%x at_us=%u",
            tag, f->exc_return, f->msp, f->psp, f->frame_sp, f->pc, f->lr, f->xpsr, f->in_handler,
            f->cur_thread, f->fire_cyc / CYC_PER_US);
        out("ZBOOT %s fire usbd en=%u ec=0x%x pullup=%u usbreg=0x%x lfstat=0x%x lfrun=%u "
            "hfstat=0x%x hfrun=%u cc0=%u",
            tag, f->usbd_enable, f->usbd_eventcause, f->usbd_usbpullup, f->usbregstatus,
            f->lfclkstat, f->lfclkrun, f->hfclkstat, f->hfclkrun, f->timer4_cc0);
    }
}

void diag_boot_print(void (*out)(const char *fmt, ...)) {
    out("ZBOOT ring count=%u dropped=%u invalid=%u addr cur=0x%x last=0x%x ring=0x%x sysq=0x%x "
        "main=0x%x calib=0x%x",
        ring.count, ring.dropped, ring.invalid, (uint32_t)&cur, (uint32_t)&last, (uint32_t)&ring,
        (uint32_t)&k_sys_work_q.thread, (uint32_t)&z_main_thread, (uint32_t)&calib_thread);
    for (uint32_t i = 0; i < ring.count && i < RING_SLOTS; i++) {
        char tag[12];
        snprintk(tag, sizeof(tag), "inc%u", i);
        print_rec(out, tag, &ring.slot[i]);
    }
    if (last_valid) {
        print_rec(out, "last", &last);
    } else {
        out("ZBOOT last none");
    }
    print_rec(out, "cur", &cur);
}

void diag_boot_clear_ring(void) {
    memset(&ring, 0, sizeof(ring));
    ring.magic = RING_MAGIC;
    ring.crc = ring_crc(&ring);
}
