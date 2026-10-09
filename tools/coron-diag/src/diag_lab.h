/* Shared between diag_lab.c (recorder) and diag_lab_ctlr.c (controller snapshot + the --wrap
 * interceptors of the controller's scheduling functions). Lab image only. */
#pragma once
#include <stdint.h>

#define LAB_CONN_MAX 2

struct lab_conn_snap {
    uint8_t valid;     /* 1 = a connection object exists for this handle */
    uint8_t role;      /* 0 = central, 1 = peripheral (lll_conn.role) */
    uint16_t handle;
    uint16_t interval; /* 1.25 ms units */
    uint16_t latency;
    uint16_t latency_prepare;
    uint16_t latency_event;
    uint16_t event_counter;
    uint16_t lazy_prepare;
    uint8_t forced;            /* lll_conn.forced: set near the supervision timeout; blocks preemption */
    uint8_t connected;         /* ll_connected_get() != NULL */
    uint16_t supervision_expire; /* ll_conn: events left before the supervision timeout (0 = synced) */
    uint16_t connect_expire;     /* ll_conn: events left to establish the connection (0 = established) */
    uint16_t supervision_timeout; /* 10 ms units */
    uint32_t ticks_prepare_to_start; /* ull_hdr (bit 31 = XON: the crystal was kept on) */
    uint32_t ticks_slot;
};

struct lab_ctlr_snap {
    uint32_t ticker_now;   /* ticker_ticks_now_get(): RTC0 ticks (30.517 us) */
    uint32_t rtc0_counter; /* NRF_RTC0->COUNTER */
    uint32_t nvmc_config;  /* NRF_NVMC->CONFIG: 1 = write enabled, 2 = erase enabled */
    uint32_t nvmc_ready;
    struct lab_conn_snap conn[LAB_CONN_MAX];
};

void diag_lab_ctlr_snapshot(struct lab_ctlr_snap *s);
/* TICKER_ID_CONN_BASE of this build: a prepare's ticker_id minus this is the connection handle */
uint32_t diag_lab_ticker_conn_base(void);

/* ---- controller scheduling trace (written by the wrappers in diag_lab_ctlr.c) ---------------- */
enum lab_ctl_type {
    CT_NONE = 0,
    CT_PREPCALC = 1,  /* lll_preempt_calc: a = ticker_id, b = result, c = ticks_at_event, d = ticks_now */
    CT_PREP = 2,      /* lll_prepare_resolve: a = handle, b = is_resume | is_dequeue<<1 | lazy<<2, c = ticks_at_expire, d = ret */
    CT_TSTART = 3,    /* ticker_start: a = ticker_id, b = user_id | ret<<8, c = ticks_anchor, d = ticks_first */
    CT_TSTOP = 4,     /* ticker_stop: a = ticker_id, b = user_id | ret<<8, c = ticks_now */
    CT_TSTART_OP = 5, /* the preempt ticker's start op callback: b = status, c = ticks_now */
    CT_TSTOP_OP = 6,  /* the preempt ticker's stop op callback: b = status, c = ticks_now */
    CT_PREEMPT = 7,   /* the preempt ticker fired: b = lazy | force<<8, c = ticks_at_expire, d = ticks_now */
    CT_ISABORT = 8,   /* *_is_abort_cb: a = curr handle, b = next handle | curr role<<8 | forced<<9, c = ret */
    CT_ABORT = 9,     /* lll_conn_abort_cb: a = handle, b = 1 if a pipeline prepare is cancelled (0 = the running event is aborted), c = ticks_at_expire */
    CT_ENQ = 10,      /* ull_prepare_enqueue: a = handle, b = is_resume, c = ticks_at_expire, d = 0 if the pipeline was full */
    CT_DEQ = 11,      /* ull_prepare_dequeue: a = caller_id */
    CT_TUPD = 12,     /* ticker_update: a = ticker_id, b = lazy | force<<15, c = drift_plus, d = drift_minus */
    CT_MARK = 13,     /* a late prepare was seen (assert off): a = ticker_id, c = late ticks */
};

void diag_lab_ctl_put(uint8_t type, uint8_t a, uint16_t b, uint32_t c, uint32_t d);
void diag_lab_prep_put(uint8_t ticker_id, uint32_t ticks_at_event, uint32_t ticks_now, uint32_t result);
/* a late prepare (the controller computed an overhead): take a record of the rings, no reboot */
void diag_lab_mark(uint8_t ticker_id, uint32_t late_ticks);
uint32_t diag_lab_now_us(void);
/* connection handle of a lll_conn pointer, 0xfe = not a connection, 0xff = NULL */
uint8_t diag_lab_handle_of(const void *lll);
