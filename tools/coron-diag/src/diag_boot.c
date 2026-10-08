/*
 * Boot-path instrument, version 4 (test builds only, never for production).
 *
 * RECORDS (RAM that survives soft and pin resets, at the fixed address 0x2002c000 (diagrec.overlay);
 * the bootloader's .data/.bss end at 0x2000ce28 and its stack starts at 0x20040000, the records
 * sit in between, see evidence/bootloader-ram.md):
 *  cur   the boot in progress
 *  last  the previous boot (overwritten every boot; normal-cycle log)
 *  ring  up to RING_SLOTS incident records, never overwritten (new incidents counted in dropped)
 *
 * Each record carries: magic, format version, seq, build tag, boot_done (0/1), reason, phase,
 * entry snapshot (taken in board_early_init_hook: after .bss/.data init, NOT the hand-over
 * instant), stage cycle stamps, monitor counters, fatal-error info, and, when the net fired, the
 * interrupted context.
 *
 * STATE TRANSITIONS (what the next boot files as an incident):
 *   event                          boot_done  reason        filed as incident?
 *   normal boot, then r/b          1          REBOOT_REQ    no
 *   normal boot, then pin reset    1          NONE          no
 *   boot never reached RUNNING,
 *     net fired                    0          BOOT_TIMEOUT  yes
 *     pin reset pressed            0          NONE          yes (INCOMPLETE)
 *     armed stall ('S') + net      0          BOOT_TIMEOUT  yes (calib='S')
 *   RUNNING, monitor timed out     1          WQ_TIMEOUT    yes
 *   RUNNING, h/G then net fired    1          WQ_TIMEOUT    yes (calib='h'/'G')
 *   RUNNING, H (ends, no fire)     1          NONE          no
 *   fatal error: zmk-feature-watchdog's handler records reason/PC/LR/thread in its own pending
 *     record (read through Studio) and reboots at once; this instrument sees only the reboot
 *     (during boot: INCOMPLETE, filed; after RUNNING: done=1/NONE, not filed)
 *   record invalid                 -          -             counted in ring.invalid (only when the
 *                                                           magic matched: fmt_ver or CRC wrong), not filed
 *   ring invalid (magic/CRC)       -          -             ring reinitialised; cur.ring_reinit=1 and
 *                                                           the header line say so; the old counters are lost
 *   Rule: filed iff reason in {BOOT_TIMEOUT, WQ_TIMEOUT} or (boot_done == 0 and reason != REBOOT_REQ).
 *
 * MONITORS (TIMER4, 16 MHz / 2^9, independent of the 32 kHz clock):
 *  boot monitor   hard deadline BOOT_DEADLINE_S from the early hook until RUNNING. RUNNING means
 *                 the main thread has exited (k_thread_join(&z_main_thread) == 0; join does not tell
 *                 how it exited, but in this build no path other than main() returning ends that
 *                 thread, see evidence/fatal-path.md) AND the first probe ran on the system
 *                 workqueue. Stage markers never feed the net during boot.
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
 * OTHER MONITORS IN THE IMAGE: the test .conf turns CONFIG_ZMK_WATCHDOG_FREEZE_DETECT off, so no
 *  timer-driven monitor resets the chip before the net does (the freeze detector would have
 *  rebooted 10 s after its last feed, before the 15 s deadline, without recording a PC).
 *  CONFIG_ZMK_WATCHDOG_FATAL_DETECT stays on: it only reacts to faults, records them with PC/LR,
 *  and reboots; the config repo's own fatal_reboot.c (reboot without a record) is compiled only
 *  when that option is off. The three confirmed stall images predate the watchdog module
 *  (added in 162637f): bbc509c halted on a fatal error (Zephyr default), 8d7cc27 rebooted without
 *  a record (fatal_reboot.c), diag-min3 unknown.
 *
 * CONSISTENCY of cur: every thread-context writer updates the fields and recomputes the CRC
 *  under irq_lock() (rec_lock/rec_unlock), so two threads cannot interleave an update and a seal.
 *  The TIMER4 ISR (NVIC priority 0, above the irq_lock level) is not excluded by that lock; it is
 *  the last writer, re-seals the whole record and never returns. What the CRC then guarantees is
 *  that the bytes read back are the bytes the ISR sealed; it does NOT guarantee that a multi-field
 *  update the ISR interrupted was complete (e.g. probes_run already incremented but STG_WQ_PROBED
 *  not yet stamped, or stage set but stage_cyc[] not yet written). Readers interpret such pairs
 *  accordingly. A pin reset inside the few microseconds of a locked update can still leave a torn
 *  record; that is detected (CRC) and counted in ring.invalid, never read as valid data.
 *
 * CALIBRATION (console commands; test builds only). The console first prints the verdict of
 *  diag_boot_calibrate_check() ("rc=0" accepted, "rc=-16" refused) and only then calls
 *  diag_boot_calibrate_start(): 'h' and 'G' stop the console thread the moment they run, so no
 *  line can follow them; their execution is confirmed by the incident record after the reset.
 *  h  spin forever on the system workqueue (cooperative)      -> WQ_TIMEOUT, PC in diag_spin_forever,
 *                                                                 thread == &k_sys_work_q.thread
 *  H  spin H_SPIN_S seconds in a preemptible thread at K_PRIO_PREEMPT(12) (lower than the feeder,
 *     higher than the console thread at 14: the console is silent while it runs) -> no fire,
 *     the thread exits and can be joined; 'H'/'G' are refused (-EBUSY) until it has
 *  G  spin forever in a preemptible thread at K_PRIO_PREEMPT(0)  (starves the feeder)    -> WQ_TIMEOUT,
 *                                                                 thread == &calib_thread (monitor
 *                                                                 limit, not a workqueue stall)
 *  S  arm a stall for the NEXT boot (SYS_INIT APPLICATION 50 spins) -> BOOT_TIMEOUT at 20 s
 *  c  clear the ring (after the incidents were copied out)
 */

#include <errno.h>
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

/* The kernel's main thread object (kernel/init.c); not in a public header. */
extern struct k_thread z_main_thread;

#define REC_MAGIC 0x34544f42u  /* 'BOT4' */
#define RING_MAGIC 0x34474e52u /* 'RNG4' */
#define ARM_MAGIC 0x4c415453u  /* 'STAL' */
#define REC_FMT_VER 4
#define RING_SLOTS 6

#define BOOT_DEADLINE_S 20
#define WQ_DEADLINE_S 15
#define PROBE_PERIOD_S 2
#define H_SPIN_S 30
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
    STG_MAIN_DONE,       /* main thread exited (in this build: main() returned after settings_load) */
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
    uint32_t ring_reinit; /* 1 if this boot found the ring invalid and reinitialised it */
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
    uint32_t invalid; /* previous-boot records whose magic matched but fmt_ver/CRC did not (not filed) */
    struct boot_rec slot[RING_SLOTS];
    uint32_t crc;
};

struct arm_rec {
    uint32_t magic; /* ARM_MAGIC = stall the next boot (consumed by the hook) */
    uint32_t crc;
};

/* T1 (2026-10-09): raw register snapshot at three points of this boot (the hook, after the clock
 * driver, after USB enable), kept OUTSIDE boot_rec so the ring slots do not grow. Reads only, no
 * waits, no locks. The core words are read before the hook enables DWT and arms the net; the
 * peripheral words right after the net is armed. What to measure and why: evidence/
 * boottest2-20261007/rootcause-plan-20261008/t0-spec-snapshot-and-crumb.md and t0-summary.md. */
#define SNAP_MAGIC 0x31504e53u /* 'SNP1' */
#define SNAP_FMT_VER 1
enum snap_point { SNAP_HOOK = 0, SNAP_AFTER_CLK = 1, SNAP_AFTER_USB = 2, SNAP_AFTER_CLEAN = 3, SNAP_COUNT };
struct snap_regs {
    uint32_t t0, t1; /* DWT CYCCNT at the start and end of the peripheral reads (0 = DWT off) */
    /* core: not written by Zephyr or SystemInit before the hook in this build (t0-boot-normalization.md) */
    uint32_t primask, faultmask, control, aircr, iser0, iser1, ispr0, ispr1, demcr;
    /* CLOCK */
    uint32_t lfclkstat, lfclkrun, lfclksrc, hfclkstat, hfclkrun, clk_inten, ev_lf, ev_hf, ev_done, ev_ctto;
    /* POWER */
    uint32_t pwr_inten, ev_usbdet, ev_usbrem, ev_usbrdy, usbreg, resetreas;
    /* RTC1 (COUNTER read twice: a change means it is running) */
    uint32_t rtc_cnt_a, rtc_cnt_b, rtc_inten, rtc_evten, rtc_presc, rtc_cc0, rtc_ev_cmp0, rtc_ev_tick, rtc_ev_ovr;
    /* USBD */
    uint32_t usbd_en, usbd_pullup, usbd_inten, usbd_epin, usbd_epout, usbd_ec;
    /* SysTick, SCB, PPI, GPIOTE */
    uint32_t syst_csr, syst_rvr, syst_cvr, scb_icsr, scb_shcsr, ppi_chen, gpiote_inten;
};
struct snap_rec {
    uint32_t magic, fmt_ver, seq, taken; /* taken: one bit per snap_point */
    struct snap_regs at[SNAP_COUNT];
    uint32_t crc;
};

/* All records live in one struct in the DIAGREC section, a 4 KB RAM region that diagrec.overlay
 * carves out of the top of the application RAM at a fixed address (0x2002c000). The address is
 * therefore the same in every image built with the overlay, whatever its .bss/.noinit size; the
 * section is NOLOAD, so nothing initialises it. */
struct diag_area {
    struct arm_rec arm_next;
    struct ring_rec ring;
    struct boot_rec last;
    struct boot_rec cur;
    struct snap_rec snap; /* appended last: the addresses of the records above do not move */
};
struct diag_area diag_area Z_GENERIC_SECTION(DIAGREC); /* global so nm resolves it */
BUILD_ASSERT(sizeof(struct diag_area) <= 0x1000, "diag_area exceeds the 4 KB DIAGREC region");
#define cur (diag_area.cur)
#define last (diag_area.last)
#define ring (diag_area.ring)
#define arm_next (diag_area.arm_next)
#define snap (diag_area.snap)
static bool last_valid;
static bool stall_this_boot;
static bool ring_reinit_this_boot;

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

/* Thread-context writers: fields are changed and the CRC recomputed with interrupts at or below
 * the irq_lock level masked. Nestable (the key restores the previous state). */
static inline unsigned int rec_lock(void) { return irq_lock(); }
static inline void rec_unlock(unsigned int key) {
    rec_seal();
    irq_unlock(key);
}

/* ---- TIMER4 net ---------------------------------------------------------------------------- */

static void net_feed_locked(void) {
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

/* Reached from the naked vector with EXC_RETURN, MSP and PSP as at exception entry. Never returns.
 * Not under rec_lock: this ISR runs above the lock level, re-seals the whole record last, and
 * resets. */
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
    unsigned int key = rec_lock();

    cur.stage = s;
    cur.stage_cyc[s] = cyc();
    rec_unlock(key);
}

static void maybe_running(void) {
    unsigned int key = rec_lock();

    if (cur.phase != PH_RUNNING && cur.stage_cyc[STG_MAIN_DONE] != 0 &&
        cur.stage_cyc[STG_WQ_PROBED] != 0) {
        cur.stage = STG_RUNNING;
        cur.stage_cyc[STG_RUNNING] = cyc();
        cur.phase = PH_RUNNING;
        cur.boot_done = 1;
        net_set_deadline(WQ_DEADLINE_S);
    }
    rec_unlock(key);
}

/* ---- T1 snapshot (reads only) --------------------------------------------------------------- */

static void snap_seal(void) {
    snap.crc = crc32_ieee((const uint8_t *)&snap, offsetof(struct snap_rec, crc));
}

static void snap_core(struct snap_regs *s) {
    s->primask = __get_PRIMASK();
    s->faultmask = __get_FAULTMASK();
    s->control = __get_CONTROL();
    s->aircr = SCB->AIRCR;
    s->iser0 = NVIC->ISER[0];
    s->iser1 = NVIC->ISER[1];
    s->ispr0 = NVIC->ISPR[0];
    s->ispr1 = NVIC->ISPR[1];
    s->demcr = CoreDebug->DEMCR;
}

static void snap_periph(struct snap_regs *s) {
    bool dwt = (DWT->CTRL & DWT_CTRL_CYCCNTENA_Msk) != 0;

    s->t0 = dwt ? cyc() : 0;
    s->lfclkstat = NRF_CLOCK->LFCLKSTAT;
    s->lfclkrun = NRF_CLOCK->LFCLKRUN;
    s->lfclksrc = NRF_CLOCK->LFCLKSRC;
    s->hfclkstat = NRF_CLOCK->HFCLKSTAT;
    s->hfclkrun = NRF_CLOCK->HFCLKRUN;
    s->clk_inten = NRF_CLOCK->INTENSET;
    s->ev_lf = NRF_CLOCK->EVENTS_LFCLKSTARTED;
    s->ev_hf = NRF_CLOCK->EVENTS_HFCLKSTARTED;
    s->ev_done = NRF_CLOCK->EVENTS_DONE;
    s->ev_ctto = NRF_CLOCK->EVENTS_CTTO;
    s->pwr_inten = NRF_POWER->INTENSET;
    s->ev_usbdet = NRF_POWER->EVENTS_USBDETECTED;
    s->ev_usbrem = NRF_POWER->EVENTS_USBREMOVED;
    s->ev_usbrdy = NRF_POWER->EVENTS_USBPWRRDY;
    s->usbreg = NRF_POWER->USBREGSTATUS;
    s->resetreas = NRF_POWER->RESETREAS;
    s->rtc_cnt_a = NRF_RTC1->COUNTER;
    s->rtc_inten = NRF_RTC1->INTENSET;
    s->rtc_evten = NRF_RTC1->EVTEN;
    s->rtc_presc = NRF_RTC1->PRESCALER;
    s->rtc_cc0 = NRF_RTC1->CC[0];
    s->rtc_ev_cmp0 = NRF_RTC1->EVENTS_COMPARE[0];
    s->rtc_ev_tick = NRF_RTC1->EVENTS_TICK;
    s->rtc_ev_ovr = NRF_RTC1->EVENTS_OVRFLW;
    s->rtc_cnt_b = NRF_RTC1->COUNTER;
    s->usbd_en = NRF_USBD->ENABLE;
    s->usbd_pullup = NRF_USBD->USBPULLUP;
    s->usbd_inten = NRF_USBD->INTEN;
    s->usbd_epin = NRF_USBD->EPINEN;
    s->usbd_epout = NRF_USBD->EPOUTEN;
    s->usbd_ec = NRF_USBD->EVENTCAUSE;
    s->syst_csr = SysTick->CTRL;
    s->syst_rvr = SysTick->LOAD;
    s->syst_cvr = SysTick->VAL;
    s->scb_icsr = SCB->ICSR;
    s->scb_shcsr = SCB->SHCSR;
    s->ppi_chen = NRF_PPI->CHEN;
    s->gpiote_inten = NRF_GPIOTE->INTENSET;
    s->t1 = dwt ? cyc() : 0;
}

/* The two later points: core and peripherals in one go. */
static void snap_take(enum snap_point p) {
    snap_core(&snap.at[p]);
    snap_periph(&snap.at[p]);
    snap.taken |= BIT(p);
    snap_seal();
}

static bool snap_valid(void) {
    return snap.magic == SNAP_MAGIC && snap.fmt_ver == SNAP_FMT_VER &&
           snap.crc == crc32_ieee((const uint8_t *)&snap, offsetof(struct snap_rec, crc));
}

#if IS_ENABLED(CONFIG_CORON_DIAG_ENTRY_CLEAN)
/* What the bootloader's DFU exit leaves behind and a plain reset does not (T1, 2026-10-09):
 * POWER.INTEN 0x380, the USBD IRQ enabled in NVIC, EVENTS_HFCLKSTARTED. Stores only. The net's
 * TIMER4 (IRQ 27), armed just before this runs, is the one NVIC bit kept. */
static void entry_clean(void) {
    NRF_POWER->INTENCLR = 0xFFFFFFFFu; /* POWER and CLOCK share this register */
    NVIC->ICER[0] = ~(1u << TIMER4_IRQn);
    NVIC->ICPR[0] = ~(1u << TIMER4_IRQn);
    NVIC->ICER[1] = 0xFFFFFFFFu;
    NVIC->ICPR[1] = 0xFFFFFFFFu;
    NRF_CLOCK->EVENTS_HFCLKSTARTED = 0;
    /* the USBD's leftover SUSPEND/RESUME causes and USBEVENT (review of diag_entry.c; same here) */
    NRF_USBD->EVENTCAUSE = USBD_EVENTCAUSE_SUSPEND_Msk | USBD_EVENTCAUSE_RESUME_Msk; /* W1C */
    NRF_USBD->EVENTS_USBEVENT = 0;
    SysTick->CTRL = 0;
    __DSB();
    __ISB();
}
#endif

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

/* Returns true when the ring had to be reinitialised (its counters, including invalid and
 * dropped, are lost; the event itself is kept in cur.ring_reinit and printed in the header). */
static bool ring_init_if_needed(void) {
    if (ring.magic == RING_MAGIC && ring.count <= RING_SLOTS && ring.crc == ring_crc(&ring)) {
        return false;
    }
    memset(&ring, 0, sizeof(ring));
    ring.magic = RING_MAGIC;
    ring.crc = ring_crc(&ring);
    return true;
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
    /* T1: the core words first, before this hook touches DWT/DEMCR and before the net is armed */
    snap.magic = SNAP_MAGIC;
    snap.fmt_ver = SNAP_FMT_VER;
    snap.seq = 0;
    snap.taken = 0;
    snap_core(&snap.at[SNAP_HOOK]);

    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;

    /* The net first (it does not depend on the records), then the peripheral words. Until T1 the
     * net was armed after the record handling below; moving it up adds nothing before it. */
    net_arm();
    snap_periph(&snap.at[SNAP_HOOK]);
    snap.taken |= BIT(SNAP_HOOK);
    snap_seal();
#if IS_ENABLED(CONFIG_CORON_DIAG_ENTRY_CLEAN)
    entry_clean();
    snap_take(SNAP_AFTER_CLEAN);
#endif

    ring_reinit_this_boot = ring_init_if_needed();

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
        if (cur.magic == REC_MAGIC) { /* a record of ours that failed fmt_ver or CRC */
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
    cur.ring_reinit = ring_reinit_this_boot ? 1 : 0;

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

    snap.seq = seq;
    snap_seal();

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

__attribute__((noinline)) void diag_spin_bounded(uint32_t seconds) {
    uint32_t t0 = cyc();
    uint32_t span = seconds * (CYC_PER_US * 1000000u); /* 30 s = 1.92e9 cycles, fits */

    while ((cyc() - t0) < span) {
        __asm volatile("nop");
    }
}

static int st_pk1_early(void) { stage(STG_PK1_EARLY); return 0; }
SYS_INIT(st_pk1_early, PRE_KERNEL_1, 1);
static int st_pk1_after_clk(void) { snap_take(SNAP_AFTER_CLK); stage(STG_PK1_AFTER_CLK); return 0; }
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

static int st_app_after_usb(void) { snap_take(SNAP_AFTER_USB); stage(STG_APP_AFTER_USB); return 0; }
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
    unsigned int key = rec_lock();

    cur.probes_run++;
    if (cur.stage_cyc[STG_WQ_PROBED] == 0) {
        cur.stage = STG_WQ_PROBED;
        cur.stage_cyc[STG_WQ_PROBED] = cyc();
    }
    rec_unlock(key);
}
K_WORK_DEFINE(probe_work, probe_fn);

static void feeder_fn(void *a, void *b, void *c) {
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
    uint32_t seen = 0;

    for (;;) {
        bool main_exited = (cur.stage_cyc[STG_MAIN_DONE] == 0) &&
                           (k_thread_join(&z_main_thread, K_NO_WAIT) == 0);
        unsigned int key = rec_lock();

        cur.feeder_loops++;
        if (main_exited) {
            cur.stage = STG_MAIN_DONE;
            cur.stage_cyc[STG_MAIN_DONE] = cyc();
        }
        rec_unlock(key);
        maybe_running();

        key = rec_lock();
        if (cur.phase == PH_RUNNING && cur.probes_run != seen) {
            seen = cur.probes_run;
            net_feed_locked();
        }
        cur.probes_submitted++;
        rec_unlock(key);
        k_work_submit(&probe_work);
        k_sleep(K_SECONDS(PROBE_PERIOD_S));
    }
}
K_THREAD_DEFINE(diag_feeder, 768, feeder_fn, NULL, NULL, NULL, K_PRIO_PREEMPT(10), 0, 500);

/* ---- console hooks -------------------------------------------------------------------------- */

void diag_boot_reboot(void) {
    unsigned int key = rec_lock();

    cur.reason = R_REBOOT_REQ;
    rec_unlock(key);
    sys_reboot(SYS_REBOOT_WARM);
}

void diag_boot_mark_reboot(void) {
    unsigned int key = rec_lock();

    cur.reason = R_REBOOT_REQ;
    rec_unlock(key);
}

static void calib_coop_fn(struct k_work *w) {
    ARG_UNUSED(w);
    diag_spin_forever();
}
K_WORK_DEFINE(calib_coop_work, calib_coop_fn);

/* a == NULL: spin forever ('G'); else spin the given number of seconds and exit ('H'). */
static void calib_thread_fn(void *a, void *b, void *c) {
    ARG_UNUSED(b); ARG_UNUSED(c);
    if (a == NULL) {
        diag_spin_forever();
    }
    diag_spin_bounded((uint32_t)(uintptr_t)a);
}
static K_THREAD_STACK_DEFINE(calib_stack, 512);
struct k_thread calib_thread; /* global so nm resolves the thread pointer */
static bool calib_thread_started;
static bool calib_coop_submitted;

/* Two steps so the console can print the verdict BEFORE anything starts: 'h' and 'G' stop the
 * console thread (priority 14) as soon as they run ('h': the cooperative workqueue at -1 runs at
 * once; 'G': the priority-0 spinner runs at once) and only the net's reset ends them, so no line
 * can be printed after them. check() has no side effects; start() is called only after a 0 from
 * check(), on the same (single) console thread, so nothing can slip in between.
 * The thread object and stack are reused only after the previous calibration thread has fully
 * terminated (k_thread_join == 0); otherwise the command is refused. 'h' is accepted once. */
int diag_boot_calibrate_check(char which) {
    switch (which) {
    case 'h':
        return calib_coop_submitted ? -EBUSY : 0;
    case 'H':
    case 'G':
        if (calib_thread_started && k_thread_join(&calib_thread, K_NO_WAIT) != 0) {
            return -EBUSY;
        }
        return 0;
    case 'S':
        return 0;
    default:
        return -EINVAL;
    }
}

void diag_boot_calibrate_start(char which) {
    unsigned int key = rec_lock();

    cur.calib = (uint32_t)which;
    rec_unlock(key);

    switch (which) {
    case 'h':
        calib_coop_submitted = true;
        k_work_submit(&calib_coop_work);
        break;
    case 'H':
        calib_thread_started = true;
        k_thread_create(&calib_thread, calib_stack, K_THREAD_STACK_SIZEOF(calib_stack),
                        calib_thread_fn, (void *)(uintptr_t)H_SPIN_S, NULL, NULL,
                        K_PRIO_PREEMPT(12), 0, K_NO_WAIT);
        break;
    case 'G':
        calib_thread_started = true;
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

/* Every line stays under 150 characters with the longest possible values (39-character tag, ten-
 * digit counters), inside the console's 256-byte line buffer (253 usable); the console marks a
 * line it had to cut with " #TRUNC" so a cut value is never read as complete. */
static void print_rec(void (*out)(const char *fmt, ...), const char *tag, const struct boot_rec *r) {
    out("ZBOOT %s a seq=%u tag=%s done=%u reason=%u phase=%u calib=%c stage=%u reset=0x%x reinit=%u",
        tag, r->seq, r->build_tag, r->boot_done, r->reason, r->phase, r->calib ? (char)r->calib : '-',
        r->stage, r->entry.resetreas, r->ring_reinit);
    out("ZBOOT %s b fix=%u/%u/%u probes=%u/%u feeds=%u loops=%u lastfeed_us=%u",
        tag, r->fix_action, r->fix_us, r->hf_action, r->probes_submitted, r->probes_run, r->feeds,
        r->feeder_loops, r->last_feed_cyc / CYC_PER_US);
    out("ZBOOT %s entry1 lfstat=0x%x lfrun=%u lfsrc=0x%x lfcopy=0x%x lfev=%u",
        tag, r->entry.lfclkstat, r->entry.lfclkrun, r->entry.lfclksrc, r->entry.lfclksrccopy,
        r->entry.ev_lfstarted);
    out("ZBOOT %s entry2 hfstat=0x%x hfrun=%u hfev=%u rtc1=%u usbreg=0x%x ficr130=0x%x ficr134=0x%x",
        tag, r->entry.hfclkstat, r->entry.hfclkrun, r->entry.ev_hfstarted, r->entry.rtc1_counter,
        r->entry.usbregstatus, r->entry.ficr_130, r->entry.ficr_134);
    out("ZBOOT %s us1 hook=%u pk1=%u clk=%u pk1end=%u sysclk=%u post=%u app=%u",
        tag, r->stage_cyc[STG_HOOK] / CYC_PER_US, r->stage_cyc[STG_PK1_EARLY] / CYC_PER_US,
        r->stage_cyc[STG_PK1_AFTER_CLK] / CYC_PER_US, r->stage_cyc[STG_PK1_LAST] / CYC_PER_US,
        r->stage_cyc[STG_PK2_AFTER_SYSCLK] / CYC_PER_US, r->stage_cyc[STG_POST] / CYC_PER_US,
        r->stage_cyc[STG_APP_EARLY] / CYC_PER_US);
    out("ZBOOT %s us2 usb=%u applast=%u commit=%u mainexit=%u probed=%u running=%u",
        tag, r->stage_cyc[STG_APP_AFTER_USB] / CYC_PER_US, r->stage_cyc[STG_APP_LAST] / CYC_PER_US,
        r->stage_cyc[STG_SETTINGS_COMMIT] / CYC_PER_US, r->stage_cyc[STG_MAIN_DONE] / CYC_PER_US,
        r->stage_cyc[STG_WQ_PROBED] / CYC_PER_US, r->stage_cyc[STG_RUNNING] / CYC_PER_US);
    if (r->fire.exc_return != 0) {
        const struct fire_info *f = &r->fire;
        out("ZBOOT %s fire1 exc=0x%x msp=0x%x psp=0x%x frame=0x%x pc=0x%x lr=0x%x",
            tag, f->exc_return, f->msp, f->psp, f->frame_sp, f->pc, f->lr);
        out("ZBOOT %s fire2 xpsr=0x%x handler=%u thread=0x%x at_us=%u",
            tag, f->xpsr, f->in_handler, f->cur_thread, f->fire_cyc / CYC_PER_US);
        out("ZBOOT %s fire3 usbd en=%u ec=0x%x pullup=%u usbreg=0x%x",
            tag, f->usbd_enable, f->usbd_eventcause, f->usbd_usbpullup, f->usbregstatus);
        out("ZBOOT %s fire4 lfstat=0x%x lfrun=%u hfstat=0x%x hfrun=%u cc0=%u",
            tag, f->lfclkstat, f->lfclkrun, f->hfclkstat, f->hfclkrun, f->timer4_cc0);
    }
}

void diag_boot_print(void (*out)(const char *fmt, ...)) {
    bool calib_live = calib_thread_started && k_thread_join(&calib_thread, K_NO_WAIT) != 0;

    out("ZBOOT ring count=%u slots=%u dropped=%u invalid=%u reinit=%u calib_live=%u",
        ring.count, RING_SLOTS, ring.dropped, ring.invalid, ring_reinit_this_boot ? 1 : 0,
        calib_live ? 1 : 0);
    out("ZBOOT addr cur=0x%x last=0x%x ring=0x%x sysq=0x%x main=0x%x calib=0x%x",
        (uint32_t)&cur, (uint32_t)&last, (uint32_t)&ring, (uint32_t)&k_sys_work_q.thread,
        (uint32_t)&z_main_thread, (uint32_t)&calib_thread);
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

    /* T1 snapshot of this boot: 6 lines per point taken, every line under 150 characters. */
    if (snap_valid()) {
        static const char *const pt[SNAP_COUNT] = {"hook", "clk", "usb", "clean"};

        out("ZBOOT snap hdr seq=%u taken=0x%x", snap.seq, snap.taken);
        for (int p = 0; p < SNAP_COUNT; p++) {
            const struct snap_regs *s = &snap.at[p];

            if (!(snap.taken & BIT(p))) {
                continue;
            }
            out("ZBOOT snap %sk primask=%u faultmask=%u control=0x%x aircr=0x%x iser=0x%x/0x%x ispr=0x%x/0x%x demcr=0x%x",
                pt[p], s->primask, s->faultmask, s->control, s->aircr, s->iser0, s->iser1, s->ispr0,
                s->ispr1, s->demcr);
            out("ZBOOT snap %sc t=%u/%u lfstat=0x%x lfrun=%u lfsrc=0x%x hfstat=0x%x hfrun=%u inten=0x%x lfev=%u hfev=%u done=%u ctto=%u",
                pt[p], s->t0 / CYC_PER_US, s->t1 / CYC_PER_US, s->lfclkstat, s->lfclkrun, s->lfclksrc,
                s->hfclkstat, s->hfclkrun, s->clk_inten, s->ev_lf, s->ev_hf, s->ev_done, s->ev_ctto);
            out("ZBOOT snap %sp inten=0x%x det=%u rem=%u rdy=%u reg=0x%x reset=0x%x", pt[p], s->pwr_inten,
                s->ev_usbdet, s->ev_usbrem, s->ev_usbrdy, s->usbreg, s->resetreas);
            out("ZBOOT snap %sr cnt=%u/%u inten=0x%x evten=0x%x presc=%u cc0=%u cmp0=%u tick=%u ovr=%u",
                pt[p], s->rtc_cnt_a, s->rtc_cnt_b, s->rtc_inten, s->rtc_evten, s->rtc_presc, s->rtc_cc0,
                s->rtc_ev_cmp0, s->rtc_ev_tick, s->rtc_ev_ovr);
            out("ZBOOT snap %su en=%u pullup=%u inten=0x%x epin=0x%x epout=0x%x ec=0x%x", pt[p], s->usbd_en,
                s->usbd_pullup, s->usbd_inten, s->usbd_epin, s->usbd_epout, s->usbd_ec);
            out("ZBOOT snap %ss csr=0x%x rvr=%u cvr=%u icsr=0x%x shcsr=0x%x chen=0x%x gpiote=0x%x", pt[p],
                s->syst_csr, s->syst_rvr, s->syst_cvr, s->scb_icsr, s->scb_shcsr, s->ppi_chen,
                s->gpiote_inten);
        }
    } else {
        out("ZBOOT snap none");
    }
}

void diag_boot_clear_ring(void) {
    memset(&ring, 0, sizeof(ring));
    ring.magic = RING_MAGIC;
    ring.crc = ring_crc(&ring);
}
