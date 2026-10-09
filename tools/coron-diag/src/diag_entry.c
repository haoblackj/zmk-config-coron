/*
 * Boot-entry normalisation and a boot breadcrumb, for the PRODUCTION image (CONFIG_CORON_DIAG_ENTRY).
 * Not the test instrument (diag_boot.c): no timers, no interrupts, no net, no calibration.
 *
 * 1. Entry clean (board_early_init_hook, before any Zephyr driver): the bootloader's UF2/DFU exit
 *    jumps into the application without a reset and leaves, measured on the device (T1,
 *    2026-10-09, evidence/boottest2-20261007/t1-20261009): POWER.INTEN = 0x380 (the USBDETECTED/
 *    USBREMOVED/USBPWRRDY interrupt enables), the USBD IRQ enabled in NVIC, USBD.EVENTCAUSE =
 *    SUSPEND|RESUME and EVENTS_HFCLKSTARTED. A plain reset path leaves none of these. With the
 *    enables in place, a USB power event before usb_init (POST_KERNEL 50) raises the POWER_CLOCK
 *    line while the kernel still masks interrupts; lfclk_spinwait (PRE_KERNEL_2) then sleeps in
 *    WFE waiting for a pending transition that cannot happen (the driver's own comment,
 *    clock_control_nrf.c), or the ISR calls the still-unregistered USB event handler once
 *    interrupts open (rootcause-plan-20261008/t0-summary.md, conditions A and B). This hook clears
 *    the enables, every NVIC enable and pending bit, the stale HFCLKSTARTED event and SysTick.
 *    Stores only: no waits, no clock operations (LFCLKSRC is never written; the spec forbids it
 *    while the LFCLK runs).
 *
 * 2. Breadcrumb (CONFIG_CORON_DIAG_ENTRY_CRUMB, lab images only): one small record at the fixed
 *    address 0x2002c000 (diagrec.overlay) that the next boot reads back, so a boot that never
 *    reaches the console still tells how far it got. Stage markers are plain stores at the same
 *    init levels the test instrument uses. 'running' is a one-shot work item on the system
 *    workqueue, submitted at APPLICATION 99. No periodic feeding. The console dump prints the
 *    previous and the current crumb (diag_min.c). The production image does not keep it (leader,
 *    2026-10-09: no record inside the chip across resets; records go to the PC), so it needs no
 *    overlay and keeps the full RAM.
 */

#include <string.h>

#include <zephyr/devicetree.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/util.h>
#include <cmsis_core.h>
#include <nrf.h>

#define CRUMB_MAGIC 0x314d5243u /* 'CRM1' */
#define CRUMB_FMT_VER 1
#define CRUMB IS_ENABLED(CONFIG_CORON_DIAG_ENTRY_CRUMB)

enum crumb_stage {
    CS_NONE = 0,
    CS_HOOK = 1,
    CS_PK1_EARLY = 2,
    CS_PK1_AFTER_CLK = 3,
    CS_PK1_LAST = 4,
    CS_PK2_AFTER_SYSCLK = 5,
    CS_POST = 6,
    CS_APP_EARLY = 7,
    CS_APP_AFTER_USB = 8,
    CS_APP_LAST = 9,
    CS_RUNNING = 10,
};

struct crumb {
    uint32_t magic;
    uint32_t fmt_ver;
    uint32_t seq;
    uint32_t stage;
    uint32_t stage_inv; /* ~stage: a torn or stale pair is detected without a CRC */
    uint32_t resetreas;   /* this boot's RESETREAS, read at the hook */
    uint32_t entry_inten; /* POWER/CLOCK INTENSET at the hook, before the clean */
    uint32_t entry_iser1; /* NVIC ISER[1] at the hook, before the clean (bit 7 = USBD) */
};

#if CRUMB
/* The first 32 bytes of the DIAGREC region. The test instrument's diag_area (a different layout,
 * different magic) uses the same region in test builds; the two never coexist in one image. */
struct crumb diag_crumb Z_GENERIC_SECTION(DIAGREC);
BUILD_ASSERT(sizeof(struct crumb) == 32, "crumb is 8 words");
/* The build must carry diagrec.overlay: without the node this fails to compile instead of
 * silently placing the crumb somewhere else (review). */
BUILD_ASSERT(DT_REG_ADDR(DT_NODELABEL(diagrec)) == 0x2002c000 && DT_REG_SIZE(DT_NODELABEL(diagrec)) >= 0x1000,
             "DIAGREC must be the 4 KB region at 0x2002c000 (diagrec.overlay)");

static struct crumb prev;
static bool prev_valid;

static inline void crumb_set(uint32_t s) {
    diag_crumb.stage = s;
    diag_crumb.stage_inv = ~s;
    __DSB();
}
#else
static inline void crumb_set(uint32_t s) { ARG_UNUSED(s); }
#endif

void board_early_init_hook(void) {
#if CRUMB
    uint32_t inten = NRF_POWER->INTENSET;
    uint32_t iser1 = NVIC->ISER[1];

    /* the previous boot's crumb, before anything here overwrites it */
    prev = diag_crumb;
    prev_valid = (prev.magic == CRUMB_MAGIC && prev.fmt_ver == CRUMB_FMT_VER &&
                  prev.stage == ~prev.stage_inv && prev.stage >= CS_HOOK && prev.stage <= CS_RUNNING);

    /* Invalidate the record NOW: a reset anywhere between here and crumb_set(CS_HOOK) below must
     * not leave the previous boot's valid stage pair next to this boot's metadata (review). The
     * pair stage/~stage written last is the commit point; no CRC needed. */
    diag_crumb.stage_inv = diag_crumb.stage;
    __DSB();
#endif

    /* entry clean (see the header). The USBD is disabled here and every IRQ is masked, so the
     * leftover SUSPEND/RESUME causes and the USBEVENT event are cleared with plain stores. */
    NRF_POWER->INTENCLR = 0xFFFFFFFFu; /* POWER and CLOCK share this register */
    NVIC->ICER[0] = 0xFFFFFFFFu;
    NVIC->ICPR[0] = 0xFFFFFFFFu;
    NVIC->ICER[1] = 0xFFFFFFFFu;
    NVIC->ICPR[1] = 0xFFFFFFFFu;
    NRF_CLOCK->EVENTS_HFCLKSTARTED = 0;
    NRF_USBD->EVENTCAUSE = USBD_EVENTCAUSE_SUSPEND_Msk | USBD_EVENTCAUSE_RESUME_Msk; /* W1C */
    NRF_USBD->EVENTS_USBEVENT = 0;
    SysTick->CTRL = 0;
    __DSB();
    __ISB();

#if CRUMB
    /* this boot's crumb; the stage pair last */
    diag_crumb.magic = CRUMB_MAGIC;
    diag_crumb.fmt_ver = CRUMB_FMT_VER;
    diag_crumb.seq = prev_valid ? prev.seq + 1 : 1;
    diag_crumb.resetreas = NRF_POWER->RESETREAS;
    diag_crumb.entry_inten = inten;
    diag_crumb.entry_iser1 = iser1;
    __DSB();
    crumb_set(CS_HOOK);
#endif
}

#if CRUMB
static int cs_pk1_early(void) { crumb_set(CS_PK1_EARLY); return 0; }
SYS_INIT(cs_pk1_early, PRE_KERNEL_1, 1);
static int cs_pk1_after_clk(void) { crumb_set(CS_PK1_AFTER_CLK); return 0; }
SYS_INIT(cs_pk1_after_clk, PRE_KERNEL_1, 31);
static int cs_pk1_last(void) { crumb_set(CS_PK1_LAST); return 0; }
SYS_INIT(cs_pk1_last, PRE_KERNEL_1, 99);
static int cs_pk2_after_sysclk(void) { crumb_set(CS_PK2_AFTER_SYSCLK); return 0; }
SYS_INIT(cs_pk2_after_sysclk, PRE_KERNEL_2, 2);
static int cs_post(void) { crumb_set(CS_POST); return 0; }
SYS_INIT(cs_post, POST_KERNEL, 0);
static int cs_app_early(void) { crumb_set(CS_APP_EARLY); return 0; }
SYS_INIT(cs_app_early, APPLICATION, 1);
static int cs_app_after_usb(void) { crumb_set(CS_APP_AFTER_USB); return 0; }
SYS_INIT(cs_app_after_usb, APPLICATION, 97);

/* CS_RUNNING means exactly: APPLICATION 99 was reached and the system workqueue processed this
 * work once (it runs at priority -1, so possibly right at submit). It does not say that main(),
 * settings_load(), BLE, USB enumeration or Studio got anywhere. */
static void running_fn(struct k_work *w) {
    ARG_UNUSED(w);
    crumb_set(CS_RUNNING);
}
K_WORK_DEFINE(running_work, running_fn);

static int cs_app_last(void) {
    crumb_set(CS_APP_LAST);
    k_work_submit(&running_work); /* runs once the system workqueue gets to it */
    return 0;
}
SYS_INIT(cs_app_last, APPLICATION, 99);

/* This boot's breadcrumb seq, for the lab crash record (diag_lab.c). */
uint32_t diag_entry_seq(void) { return diag_crumb.seq; }

/* One line in the console dump (diag_min.c): pv = previous crumb valid, pseq/pst/prst/pint/
 * piser1 = the previous boot's seq, stage, RESETREAS, POWER/CLOCK INTEN and NVIC ISER[1] at its
 * hook, seq/st = this boot. Longest possible line: 104 characters (under the 150 limit). */
void diag_entry_print(void (*out)(const char *fmt, ...)) {
    out("ZDIAG crumb pv=%u pseq=%u pst=%u prst=0x%x pint=0x%x piser1=0x%x seq=%u st=%u",
        prev_valid ? 1 : 0, prev_valid ? prev.seq : 0, prev_valid ? prev.stage : 0,
        prev_valid ? prev.resetreas : 0, prev_valid ? prev.entry_inten : 0,
        prev_valid ? prev.entry_iser1 : 0, diag_crumb.seq, diag_crumb.stage);
}
#endif /* CRUMB */
