/*
 * LAB ONLY (CONFIG_CORON_DIAG_LAB, 2026-10-09). One recording image that takes everything the chip
 * can tell about a link-layer crash, so the measurement is done ONCE (leader: no repeated loops, no
 * flash wear, nothing kept inside the chip in production).
 *
 * What is recorded, all into one RAM block at 0x2002d000 (LABREC, 28 KB, above the DIAGREC region,
 * 48 KB below the bootloader's stack top; not described in devicetree, lab image only; survives the
 * fatal-error reboot because nothing initialises it):
 *
 *  1. Latency probe: TIMER4 at 1 MHz, compare every 1000 us (COMPARE0_CLEAR), ISR at the LLL's
 *     IRQ level (IRQ_CONNECT priority 0, masked by irq_lock exactly like the LLL). The counter at
 *     ISR entry is the latency in us. Latencies >= 100 us go to a 16-entry ring with the context
 *     that was interrupted (thread frame PC/LR on PSP, NVIC active bits, thread name).
 *  2. Activity timeline: EVERY tick (1 ms) stores {NVIC IABR[0], thread PC, latency, thread index}
 *     in a 640-entry ring (the last 0.64 s). Which ISRs were running and where the thread was, ms
 *     by ms, right up to the crash.
 *  3. printk capture: __printk_hook_install() diverts printk's characters (this build has no
 *     logging subsystem, so printk is only the Bluetooth assert text, which carries
 *     "Actual EVENT_OVERHEAD_START_US = <n>") into a 2 KB ring.
 *  4. Crash capture: CONFIG_BT_CTLR_ASSERT_HANDLER routes every LL_ASSERT to
 *     bt_ctlr_assert_handle(file, line). It stores a crash record (file/line, uptime, interrupted
 *     context, the tails of the latency ring, the activity ring, the printk ring and the console
 *     module's connection-event list), then k_oops() so the watchdog module records and reboots as
 *     before. Up to 4 crash records are kept (oldest overwritten), so a day's records can be read
 *     in one go; 'c' on the console clears them.
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

#define LAB_MAGIC 0x3142414cu /* 'LAB1' */
#define LAB_ADDR 0x2002d000u
#define LAB_SIZE 0x7000u
#define LAB_PERIOD_US 1000u
#define LAT_THRESH_US 100u
#define LAT_RING 16
#define ACT_RING 640
#define ACT_TAIL 192
#define PK_RING 2048
#define PK_TAIL 384
#define EV_TAIL 24
#define CRASHES 4
#define NAME_LEN 12
#define THR_MAX 16
#define FILE_LEN 20

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
    uint32_t iabr0;   /* NVIC active bits 0..31 (bit 27 = this probe's TIMER4) */
    uint32_t pc;      /* thread frame PC on PSP, 0 if none */
    uint16_t lat_us;  /* probe latency this tick (capped) */
    uint8_t thr;      /* index into labrec.thr_name, 0xff = unknown */
    uint8_t ipsr;     /* 0 when the interrupted context was a thread; else the nested ISR is in iabr0 */
};

struct ev_out {
    uint32_t ms;
    uint8_t type;
    uint16_t a;
    uint16_t b;
};

struct crash_rec {
    uint32_t valid;
    uint32_t seq;        /* breadcrumb seq of the boot that crashed */
    uint32_t line;
    char file[FILE_LEN];
    uint32_t up_ms;
    uint32_t ipsr;
    uint32_t iabr0;
    uint32_t iabr1;
    uint32_t pc;
    uint32_t lr;
    char thr[NAME_LEN];
    uint32_t max_us;
    uint32_t over[4];
    uint32_t n_lat;
    struct lat_ev lat[8];           /* last 8 latency events, oldest first */
    uint32_t act_n;                 /* entries valid in act[] */
    struct act_ev act[ACT_TAIL];    /* last ACT_TAIL ticks, oldest first */
    uint32_t pk_n;
    char pk[PK_TAIL];               /* last printk characters */
    uint32_t ev_n;
    struct ev_out ev[EV_TAIL];      /* last connection events, oldest first */
};

struct labrec {
    uint32_t magic;
    uint32_t magic_inv;
    /* live (reset every boot) */
    uint32_t base_ms;
    uint32_t ticks;
    uint32_t max_us;
    uint32_t max_at_ms;
    uint32_t over[4];
    uint32_t n_lat;
    struct lat_ev lat[LAT_RING];
    uint32_t act_head;
    struct act_ev act[ACT_RING];
    uint32_t thr_n;
    char thr_name[THR_MAX][NAME_LEN];
    struct k_thread *thr_ptr[THR_MAX];
    uint32_t pk_head;
    char pk[PK_RING];
    /* kept across boots until cleared */
    uint32_t crash_n;               /* total crashes recorded (slot = n % CRASHES) */
    struct crash_rec crash[CRASHES];
};
BUILD_ASSERT(sizeof(struct labrec) <= LAB_SIZE, "labrec must fit in the 28 KB LABREC block");
BUILD_ASSERT(DT_REG_ADDR(DT_NODELABEL(diagrec)) == 0x2002c000 && DT_REG_SIZE(DT_NODELABEL(diagrec)) == 0x1000,
             "LABREC sits right above the 4 KB DIAGREC region at 0x2002c000 (diagrec.overlay)");

#define REC ((struct labrec *)LAB_ADDR)

uint32_t diag_entry_seq(void);
uint32_t diag_min_events_tail(struct ev_out *dst, uint32_t max);
const char *diag_min_ev_name(uint8_t type);

/* ---- helpers usable from the probe ISR and the assert handler --------------------------------- */

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

static void fill_lat(struct lat_ev *ev, uint32_t lat) {
    struct labrec *r = REC;
    uint8_t ti = thr_index();

    ev->up_ms = r->base_ms + r->ticks;
    ev->lat_us = lat;
    ev->iabr0 = NVIC->IABR[0];
    ev->iabr1 = NVIC->IABR[1];
    thread_frame(&ev->pc, &ev->lr);
    memset(ev->thr, 0, NAME_LEN);
    if (ti != 0xff) {
        memcpy(ev->thr, r->thr_name[ti], NAME_LEN);
    }
}

/* ---- 1 kHz probe ------------------------------------------------------------------------------ */

/* Self-test of the whole crash path (console 'A'): the next probe tick, i.e. from ISR context like
 * a real link-layer assert, calls the assert sink with a recognisable file/line. The device then
 * reboots through k_oops exactly as it would for a real crash, and the next boot's dump must show
 * 'crashN ... line=4242 file=selftest' with the activity, printk and event tails. */
static volatile bool selftest_armed;
void bt_ctlr_assert_handle(char *file, uint32_t line);

ISR_DIRECT_DECLARE(lab_isr) {
    struct labrec *r = REC;
    uint32_t lat;
    struct act_ev a;

    NRF_TIMER4->EVENTS_COMPARE[0] = 0;
    NRF_TIMER4->TASKS_CAPTURE[1] = 1;
    lat = NRF_TIMER4->CC[1];
    r->ticks++;
    if (selftest_armed) {
        selftest_armed = false;
        bt_ctlr_assert_handle("selftest", 4242); /* does not return */
    }
    if (lat > r->max_us) {
        r->max_us = lat;
        r->max_at_ms = r->base_ms + r->ticks;
    }
    a.iabr0 = NVIC->IABR[0];
    a.lat_us = (lat > 0xffffu) ? 0xffffu : (uint16_t)lat;
    a.thr = thr_index();
    a.ipsr = 0; /* only this ISR is in IPSR here; nested lower ISRs show in iabr0 */
    {
        uint32_t lr;
        thread_frame(&a.pc, &lr);
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

/* ---- printk capture --------------------------------------------------------------------------- */

static int lab_printk_char(int c) {
    struct labrec *r = REC;

    r->pk[r->pk_head % PK_RING] = (char)c;
    r->pk_head++;
    return c;
}

/* ---- init ------------------------------------------------------------------------------------- */

static int lab_init(void) {
    struct labrec *r = REC;
    bool keep = (r->magic == LAB_MAGIC && r->magic_inv == ~LAB_MAGIC);
    uint32_t crash_n = keep ? r->crash_n : 0;
    struct crash_rec saved[CRASHES];

    if (keep) {
        memcpy(saved, r->crash, sizeof(saved));
    }
    memset(r, 0, sizeof(*r));
    if (keep) {
        memcpy(r->crash, saved, sizeof(saved));
        r->crash_n = crash_n;
    }
    r->magic = LAB_MAGIC;
    r->magic_inv = ~LAB_MAGIC;
    r->base_ms = k_uptime_get_32();
    __DSB();

    __printk_hook_install(lab_printk_char);

    NRF_TIMER4->TASKS_STOP = 1;
    NRF_TIMER4->MODE = TIMER_MODE_MODE_Timer;
    NRF_TIMER4->BITMODE = TIMER_BITMODE_BITMODE_32Bit;
    NRF_TIMER4->PRESCALER = 4; /* 16 MHz / 16 = 1 MHz */
    NRF_TIMER4->CC[0] = LAB_PERIOD_US;
    NRF_TIMER4->SHORTS = TIMER_SHORTS_COMPARE0_CLEAR_Msk;
    NRF_TIMER4->EVENTS_COMPARE[0] = 0;
    NRF_TIMER4->INTENSET = TIMER_INTENSET_COMPARE0_Msk;
    IRQ_DIRECT_CONNECT(TIMER4_IRQn, 0, lab_isr, 0); /* the LLL's level; NOT NVIC priority 0 */
    NVIC_ClearPendingIRQ(TIMER4_IRQn);
    irq_enable(TIMER4_IRQn);
    NRF_TIMER4->TASKS_CLEAR = 1;
    NRF_TIMER4->TASKS_START = 1;
    return 0;
}
SYS_INIT(lab_init, POST_KERNEL, 0);

/* ---- crash capture ---------------------------------------------------------------------------- */

void bt_ctlr_assert_handle(char *file, uint32_t line) {
    struct labrec *r = REC;
    struct crash_rec *c = &r->crash[r->crash_n % CRASHES];
    size_t len = file ? strlen(file) : 0;
    uint8_t ti;

    /* a few ms for the assert text that printk is emitting right now: it is already in pk[] */
    memset(c, 0, sizeof(*c));
    c->seq = diag_entry_seq();
    c->line = line;
    if (len > 0) {
        const char *tail = (len > FILE_LEN - 1) ? file + len - (FILE_LEN - 1) : file;
        strncpy(c->file, tail, FILE_LEN - 1);
    }
    c->up_ms = r->base_ms + r->ticks;
    c->ipsr = __get_IPSR();
    c->iabr0 = NVIC->IABR[0];
    c->iabr1 = NVIC->IABR[1];
    thread_frame(&c->pc, &c->lr);
    ti = thr_index();
    if (ti != 0xff) {
        memcpy(c->thr, r->thr_name[ti], NAME_LEN);
    }
    c->max_us = r->max_us;
    memcpy(c->over, r->over, sizeof(c->over));
    c->n_lat = r->n_lat;
    {
        uint32_t cnt = MIN(r->n_lat, 8u);
        uint32_t first = r->n_lat - cnt;

        for (uint32_t i = 0; i < cnt; i++) {
            c->lat[i] = r->lat[(first + i) % LAT_RING];
        }
    }
    {
        uint32_t cnt = MIN(r->act_head, (uint32_t)ACT_TAIL);
        uint32_t first = r->act_head - cnt;

        for (uint32_t i = 0; i < cnt; i++) {
            c->act[i] = r->act[(first + i) % ACT_RING];
        }
        c->act_n = cnt;
    }
    {
        uint32_t cnt = MIN(r->pk_head, (uint32_t)PK_TAIL);
        uint32_t first = r->pk_head - cnt;

        for (uint32_t i = 0; i < cnt; i++) {
            c->pk[i] = r->pk[(first + i) % PK_RING];
        }
        c->pk_n = cnt;
    }
    c->ev_n = diag_min_events_tail(c->ev, EV_TAIL);
    c->valid = 1;
    r->crash_n++;
    __DSB();
    k_oops();
}

/* ---- console output --------------------------------------------------------------------------- */

static const char *thr_of(const struct labrec *r, uint8_t i) {
    return (i < THR_MAX && i < r->thr_n) ? r->thr_name[i] : "?";
}

static void print_lat(void (*out)(const char *fmt, ...), const char *tag, const struct lat_ev *ev) {
    out("ZDIAG lab %s up=%u lat=%u iabr=%x/%x pc=%x lr=%x thr=%s", tag, ev->up_ms, ev->lat_us, ev->iabr0,
        ev->iabr1, ev->pc, ev->lr, ev->thr);
}

/* run-length: consecutive ticks with the same ISR set and thread are one line */
static void print_act(void (*out)(const char *fmt, ...), const char *tag, const struct labrec *r,
                      const struct act_ev *a, uint32_t n, uint32_t last_up_ms) {
    uint32_t i = 0;

    while (i < n) {
        uint32_t j = i + 1;
        uint16_t maxlat = a[i].lat_us;
        uint32_t isr = a[i].iabr0 & ~(1u << TIMER4_IRQn);

        while (j < n && (a[j].iabr0 & ~(1u << TIMER4_IRQn)) == isr && a[j].thr == a[i].thr) {
            if (a[j].lat_us > maxlat) { maxlat = a[j].lat_us; }
            j++;
        }
        /* t = ms before the last tick of the tail (0 = the last tick) */
        out("ZDIAG lab %s t=-%u..-%u isr=%x thr=%s pc=%x..%x maxlat=%u", tag, n - i, n - j + 1, isr,
            thr_of(r, a[i].thr), a[i].pc, a[j - 1].pc, maxlat);
        i = j;
    }
    ARG_UNUSED(last_up_ms);
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

static void print_crash(void (*out)(const char *fmt, ...), uint32_t idx, const struct crash_rec *c,
                        const struct labrec *r) {
    char tag[16];

    snprintk(tag, sizeof(tag), "crash%u", idx);
    out("ZDIAG lab %s seq=%u line=%u file=%s up=%u ipsr=%u iabr=%x/%x pc=%x lr=%x thr=%s max=%u over=%u/%u/%u/%u nlat=%u",
        tag, c->seq, c->line, c->file, c->up_ms, c->ipsr, c->iabr0, c->iabr1, c->pc, c->lr, c->thr, c->max_us,
        c->over[0], c->over[1], c->over[2], c->over[3], c->n_lat);
    for (uint32_t i = 0; i < MIN(c->n_lat, 8u); i++) {
        char t2[24];

        snprintk(t2, sizeof(t2), "%slat", tag);
        print_lat(out, t2, &c->lat[i]);
    }
    for (uint32_t i = 0; i < c->ev_n; i++) {
        out("ZDIAG lab %sev ms=%u type=%s a=%u b=%u", tag, c->ev[i].ms, diag_min_ev_name(c->ev[i].type),
            c->ev[i].a, c->ev[i].b);
    }
    {
        char t2[24];

        snprintk(t2, sizeof(t2), "%sact", tag);
        print_act(out, t2, r, c->act, c->act_n, c->up_ms);
        snprintk(t2, sizeof(t2), "%spk", tag);
        print_text(out, t2, c->pk, c->pk_n);
    }
}

void diag_lab_print(void (*out)(const char *fmt, ...)) {
    const struct labrec *r = REC;

    if (r->magic != LAB_MAGIC || r->magic_inv != ~LAB_MAGIC) {
        out("ZDIAG lab invalid");
        return;
    }
    out("ZDIAG lab live ticks=%u max=%u@%u over=%u/%u/%u/%u nlat=%u thr=%u crashes=%u", r->ticks, r->max_us,
        r->max_at_ms, r->over[0], r->over[1], r->over[2], r->over[3], r->n_lat, r->thr_n, r->crash_n);
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
        uint32_t cnt = MIN(r->crash_n, (uint32_t)CRASHES);

        for (uint32_t k = 0; k < cnt; k++) {
            uint32_t idx = r->crash_n - cnt + k;
            const struct crash_rec *c = &r->crash[idx % CRASHES];

            if (c->valid) {
                print_crash(out, idx, c, r);
            }
        }
    }
    out("ZDIAG lab end");
}

void diag_lab_selftest(void) {
    printk("ZDIAG lab selftest armed up_ms=%u\n", k_uptime_get_32()); /* lands in the printk ring */
    selftest_armed = true;
}

void diag_lab_clear(void) {
    struct labrec *r = REC;

    memset(r->crash, 0, sizeof(r->crash));
    r->crash_n = 0;
    __DSB();
}
