/*
 * Lab image only (v3, 2026-10-09): read the Bluetooth controller's per-connection link-layer state
 * through the controller's own (internal, but linkable) accessors, and intercept the controller's
 * scheduling functions with the linker's --wrap (CMakeLists.txt) so every step of "a radio event's
 * prepare arrives while another event runs" is in the record:
 *   lll_prepare_resolve     the prepare arrives (run now, or queued behind the running event)
 *   ull_prepare_enqueue     queued
 *   ticker_start/stop       the preempt timeout (TICKER_ID_LLL_PREEMPT) requested / cancelled; its
 *                           op callback (the ticker job's answer) and its timeout callback (it fired)
 *                           are recorded by substituting the callbacks the controller passes
 *   *_is_abort_cb           the running event asked whether it may be aborted (forced = no)
 *   lll_conn_abort_cb       the running event is aborted (or a queued prepare is cancelled)
 *   ull_prepare_dequeue     the pipeline is run (next prepare starts)
 *   lll_preempt_calc        the prepare's lateness check; a late one also takes a record (no reboot)
 *   ticker_update           the controller's own connection-ticker updates (drift, lazy, force)
 * No Zephyr source is changed; this file includes the controller's headers (see CMakeLists.txt for
 * the include directories). Everything here runs in the controller's ISR contexts: memory stores
 * only, no locks, no allocation.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/toolchain.h>
#include <zephyr/sys/util.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/bluetooth/hci_types.h>

#include "hal/ccm.h"
#include "hal/radio.h"
#include "hal/ticker.h"

#include "util/util.h"
#include "util/mem.h"
#include "util/memq.h"
#include "util/mfifo.h"
#include "util/mayfly.h"
#include "util/dbuf.h"

#include "ticker/ticker.h"

#include "pdu_df.h"
#include "pdu_vendor.h"
#include "pdu.h"

#include "lll.h"
#include "lll_vendor.h"
#include "lll_clock.h"
#include "lll_df_types.h"
#include "lll_conn.h"
#include "lll_conn_iso.h"

#include "ull_tx_queue.h"
#include "isoal.h"
#include "ull_iso_types.h"
#include "ull_conn_types.h"
#include "ull_conn_iso_types.h"
#include "ull_conn_internal.h"

#include <nrf.h>

#include "diag_lab.h"

extern struct lll_conn *ull_conn_lll_get(uint16_t handle);

uint32_t diag_lab_ticker_conn_base(void) { return TICKER_ID_CONN_BASE; }

uint8_t diag_lab_handle_of(const void *lll) {
    if (lll == NULL) {
        return 0xff;
    }
    for (uint16_t h = 0; h < LAB_CONN_MAX; h++) {
        if (ull_conn_lll_get(h) == lll) {
            return (uint8_t)h;
        }
    }
    return 0xfe;
}

void diag_lab_preempt_vars(struct lab_preempt_vars *v) {
    memset(v, 0, sizeof(*v));
#if defined(LAB_ADDR_PREEMPT_REQ)
    v->valid = 1;
    v->req = *(volatile uint8_t *)LAB_ADDR_PREEMPT_REQ;
    v->ack = *(volatile uint8_t *)LAB_ADDR_PREEMPT_ACK;
    v->start_req = *(volatile uint8_t *)LAB_ADDR_PREEMPT_START_REQ;
    v->start_ack = *(volatile uint8_t *)LAB_ADDR_PREEMPT_START_ACK;
    v->stop_req = *(volatile uint8_t *)LAB_ADDR_PREEMPT_STOP_REQ;
    v->stop_ack = *(volatile uint8_t *)LAB_ADDR_PREEMPT_STOP_ACK;
    v->ticks_at_preempt = *(volatile uint32_t *)LAB_ADDR_TICKS_AT_PREEMPT;
#endif
}

void diag_lab_ctlr_snapshot(struct lab_ctlr_snap *s) {
    memset(s, 0, sizeof(*s));
    diag_lab_preempt_vars(&s->pre);
    s->ticker_now = ticker_ticks_now_get();
    s->rtc0_counter = NRF_RTC0->COUNTER;
    s->nvmc_config = NRF_NVMC->CONFIG;
    s->nvmc_ready = NRF_NVMC->READY;
    for (uint16_t h = 0; h < LAB_CONN_MAX; h++) {
        struct ll_conn *conn = ll_conn_get(h);
        struct lab_conn_snap *c = &s->conn[h];

        if (conn == NULL) {
            continue;
        }
        c->valid = 1;
        c->connected = (ll_connected_get(h) != NULL);
        c->role = conn->lll.role;
        c->handle = conn->lll.handle;
        c->interval = conn->lll.interval;
        c->latency = conn->lll.latency;
        c->latency_prepare = conn->lll.latency_prepare;
        c->latency_event = conn->lll.latency_event;
        c->event_counter = conn->lll.event_counter;
        c->lazy_prepare = conn->lll.lazy_prepare;
        c->forced = conn->lll.forced;
        c->supervision_expire = conn->supervision_expire;
        c->connect_expire = conn->connect_expire;
        c->supervision_timeout = conn->supervision_timeout;
        c->ticks_prepare_to_start = conn->ull.ticks_prepare_to_start;
        c->ticks_slot = conn->ull.ticks_slot;
    }
}

/* ---- the ticker's list (thread context: ticker_next_slot_get_ext answers through the job) ------- */

static K_SEM_DEFINE(tk_sem, 0, 1);

static void tk_op(uint32_t status, void *op_context) {
    ARG_UNUSED(status);
    ARG_UNUSED(op_context);
    k_sem_give(&tk_sem);
}

static bool tk_match_all(uint8_t ticker_id, uint32_t ticks_slot, uint32_t ticks_to_expire, void *op_context) {
    ARG_UNUSED(ticker_id);
    ARG_UNUSED(ticks_slot);
    ARG_UNUSED(ticks_to_expire);
    ARG_UNUSED(op_context);
    return true; /* every node, including the slot-less preempt ticker */
}

void diag_lab_ticker_snapshot(struct lab_ticker_snap *s) {
    uint8_t id = TICKER_NULL;
    uint32_t cur = 0, to = 0;

    memset(s, 0, sizeof(*s));
    if (k_is_in_isr()) {
        return;
    }
    k_sem_reset(&tk_sem);
    for (uint32_t i = 0; i < LAB_TICKERS; i++) {
        uint32_t ret = ticker_next_slot_get_ext(TICKER_INSTANCE_ID_CTLR, TICKER_USER_ID_THREAD, &id, &cur, &to, NULL,
                                                NULL, tk_match_all, NULL, tk_op, NULL);

        if (ret == TICKER_STATUS_FAILURE) {
            break;
        }
        if (k_sem_take(&tk_sem, K_MSEC(100)) != 0) {
            break;
        }
        if (id == TICKER_NULL) {
            break;
        }
        s->t[s->n].id = id;
        s->t[s->n].ticks_to_expire = to;
        s->n++;
    }
    s->ticks_current = cur;
}

/* ---- lll_preempt_calc: the prepare's lateness check -------------------------------------------- */

uint32_t __real_lll_preempt_calc(struct ull_hdr *ull, uint8_t ticker_id, uint32_t ticks_at_event);

uint32_t __wrap_lll_preempt_calc(struct ull_hdr *ull, uint8_t ticker_id, uint32_t ticks_at_event) {
    uint32_t now = ticker_ticks_now_get();
    uint32_t res = __real_lll_preempt_calc(ull, ticker_id, ticks_at_event);
    uint32_t late = (now - ticks_at_event) & HAL_TICKER_CNTR_MASK;

    diag_lab_prep_put(ticker_id, ticks_at_event, now, res);
    diag_lab_ctl_put(CT_PREPCALC, ticker_id, (uint16_t)res, ticks_at_event, now);
    if (res != 0u) {
        diag_lab_mark(ticker_id, late);
    }
    return res;
}

/* ---- lll_prepare_resolve: a prepare (or resume) arrives ---------------------------------------- */

int __real_lll_prepare_resolve(lll_is_abort_cb_t is_abort_cb, lll_abort_cb_t abort_cb, lll_prepare_cb_t prepare_cb,
                               struct lll_prepare_param *prepare_param, uint8_t is_resume, uint8_t is_dequeue);

int __wrap_lll_prepare_resolve(lll_is_abort_cb_t is_abort_cb, lll_abort_cb_t abort_cb, lll_prepare_cb_t prepare_cb,
                               struct lll_prepare_param *prepare_param, uint8_t is_resume, uint8_t is_dequeue) {
    uint8_t h = diag_lab_handle_of(prepare_param->param);
    uint16_t b = (is_resume ? 1u : 0u) | (is_dequeue ? 2u : 0u) | ((uint16_t)MIN(prepare_param->lazy, 0x3fffu) << 2);
    int ret = __real_lll_prepare_resolve(is_abort_cb, abort_cb, prepare_cb, prepare_param, is_resume, is_dequeue);

    diag_lab_ctl_put(CT_PREP, h, b, prepare_param->ticks_at_expire, (uint32_t)ret);
    return ret;
}

/* ---- the prepare pipeline ------------------------------------------------------------------------ */

struct lll_event *__real_ull_prepare_enqueue(lll_is_abort_cb_t is_abort_cb, lll_abort_cb_t abort_cb,
                                             struct lll_prepare_param *prepare_param, lll_prepare_cb_t prepare_cb,
                                             uint8_t is_resume);
void __real_ull_prepare_dequeue(uint8_t caller_id);

struct lll_event *__wrap_ull_prepare_enqueue(lll_is_abort_cb_t is_abort_cb, lll_abort_cb_t abort_cb,
                                             struct lll_prepare_param *prepare_param, lll_prepare_cb_t prepare_cb,
                                             uint8_t is_resume) {
    struct lll_event *e = __real_ull_prepare_enqueue(is_abort_cb, abort_cb, prepare_param, prepare_cb, is_resume);

    diag_lab_ctl_put(CT_ENQ, diag_lab_handle_of(prepare_param->param), is_resume, prepare_param->ticks_at_expire,
                     e != NULL);
    return e;
}

void __wrap_ull_prepare_dequeue(uint8_t caller_id) {
    diag_lab_ctl_put(CT_DEQ, caller_id, 0, ticker_ticks_now_get(), 0);
    __real_ull_prepare_dequeue(caller_id);
}

/* ---- the preempt timeout: ticker_start / ticker_stop on TICKER_ID_LLL_PREEMPT, and its callbacks - */

uint8_t __real_ticker_start(uint8_t instance_index, uint8_t user_id, uint8_t ticker_id, uint32_t ticks_anchor,
                            uint32_t ticks_first, uint32_t ticks_periodic, uint32_t remainder_periodic, uint16_t lazy,
                            uint32_t ticks_slot, ticker_timeout_func fp_timeout_func, void *context,
                            ticker_op_func fp_op_func, void *op_context);
uint8_t __real_ticker_stop(uint8_t instance_index, uint8_t user_id, uint8_t ticker_id, ticker_op_func fp_op_func,
                           void *op_context);
uint8_t __real_ticker_update(uint8_t instance_index, uint8_t user_id, uint8_t ticker_id, uint32_t ticks_drift_plus,
                             uint32_t ticks_drift_minus, uint32_t ticks_slot_plus, uint32_t ticks_slot_minus,
                             uint16_t lazy, uint8_t force, ticker_op_func fp_op_func, void *op_context);

/* the controller always passes the same three callbacks for the preempt ticker (lll.c:
 * preempt_ticker_cb, ticker_start_op_cb, ticker_stop_op_cb); keep whatever was passed last */
static ticker_timeout_func orig_preempt_timeout;
static ticker_op_func orig_preempt_start_op;
static ticker_op_func orig_preempt_stop_op;

static void lab_preempt_timeout(uint32_t ticks_at_expire, uint32_t ticks_drift, uint32_t remainder, uint16_t lazy,
                                uint8_t force, void *context) {
    diag_lab_ctl_put(CT_PREEMPT, diag_lab_handle_of(context), (uint16_t)(lazy | ((uint16_t)force << 8)),
                     ticks_at_expire, ticker_ticks_now_get());
    if (orig_preempt_timeout != NULL) {
        orig_preempt_timeout(ticks_at_expire, ticks_drift, remainder, lazy, force, context);
    }
}

static void lab_preempt_start_op(uint32_t status, void *op_context) {
    diag_lab_ctl_put(CT_TSTART_OP, TICKER_ID_LLL_PREEMPT, (uint16_t)status, ticker_ticks_now_get(), 0);
    if (orig_preempt_start_op != NULL) {
        orig_preempt_start_op(status, op_context);
    }
}

static void lab_preempt_stop_op(uint32_t status, void *op_context) {
    diag_lab_ctl_put(CT_TSTOP_OP, TICKER_ID_LLL_PREEMPT, (uint16_t)status, ticker_ticks_now_get(), 0);
    if (orig_preempt_stop_op != NULL) {
        orig_preempt_stop_op(status, op_context);
    }
}

uint8_t __wrap_ticker_start(uint8_t instance_index, uint8_t user_id, uint8_t ticker_id, uint32_t ticks_anchor,
                            uint32_t ticks_first, uint32_t ticks_periodic, uint32_t remainder_periodic, uint16_t lazy,
                            uint32_t ticks_slot, ticker_timeout_func fp_timeout_func, void *context,
                            ticker_op_func fp_op_func, void *op_context) {
    uint8_t ret;

    if (instance_index == TICKER_INSTANCE_ID_CTLR && ticker_id == TICKER_ID_LLL_PREEMPT) {
        orig_preempt_timeout = fp_timeout_func;
        fp_timeout_func = lab_preempt_timeout;
        if (fp_op_func != NULL) {
            orig_preempt_start_op = fp_op_func;
            fp_op_func = lab_preempt_start_op;
        }
    }
    ret = __real_ticker_start(instance_index, user_id, ticker_id, ticks_anchor, ticks_first, ticks_periodic,
                              remainder_periodic, lazy, ticks_slot, fp_timeout_func, context, fp_op_func, op_context);
    diag_lab_ctl_put(CT_TSTART, ticker_id, (uint16_t)(user_id | ((uint16_t)ret << 8)), ticks_anchor, ticks_first);
    return ret;
}

uint8_t __wrap_ticker_stop(uint8_t instance_index, uint8_t user_id, uint8_t ticker_id, ticker_op_func fp_op_func,
                           void *op_context) {
    uint8_t ret;

    if (instance_index == TICKER_INSTANCE_ID_CTLR && ticker_id == TICKER_ID_LLL_PREEMPT && fp_op_func != NULL) {
        orig_preempt_stop_op = fp_op_func;
        fp_op_func = lab_preempt_stop_op;
    }
    ret = __real_ticker_stop(instance_index, user_id, ticker_id, fp_op_func, op_context);
    diag_lab_ctl_put(CT_TSTOP, ticker_id, (uint16_t)(user_id | ((uint16_t)ret << 8)), ticker_ticks_now_get(), 0);
    return ret;
}

uint8_t __wrap_ticker_update(uint8_t instance_index, uint8_t user_id, uint8_t ticker_id, uint32_t ticks_drift_plus,
                             uint32_t ticks_drift_minus, uint32_t ticks_slot_plus, uint32_t ticks_slot_minus,
                             uint16_t lazy, uint8_t force, ticker_op_func fp_op_func, void *op_context) {
    uint8_t ret = __real_ticker_update(instance_index, user_id, ticker_id, ticks_drift_plus, ticks_drift_minus,
                                       ticks_slot_plus, ticks_slot_minus, lazy, force, fp_op_func, op_context);

    diag_lab_ctl_put(CT_TUPD, ticker_id, (uint16_t)(MIN(lazy, 0x7fffu) | (force ? 0x8000u : 0u)), ticks_drift_plus,
                     ticks_drift_minus);
    return ret;
}

/* ---- abort decisions and aborts of connection events ------------------------------------------- */

static void put_is_abort(void *next, void *curr, int ret) {
    const struct lll_conn *lll = curr;
    uint16_t b = diag_lab_handle_of(next) | ((uint16_t)(lll ? lll->role : 0) << 8) |
                 ((uint16_t)(lll ? lll->forced : 0) << 9);

    diag_lab_ctl_put(CT_ISABORT, diag_lab_handle_of(curr), b, (uint32_t)ret, ticker_ticks_now_get());
}

#if defined(CONFIG_BT_CENTRAL)
int __real_lll_conn_central_is_abort_cb(void *next, void *curr, lll_prepare_cb_t *resume_cb);
int __wrap_lll_conn_central_is_abort_cb(void *next, void *curr, lll_prepare_cb_t *resume_cb) {
    int ret = __real_lll_conn_central_is_abort_cb(next, curr, resume_cb);

    put_is_abort(next, curr, ret);
    return ret;
}
#endif

#if defined(CONFIG_BT_PERIPHERAL)
int __real_lll_conn_peripheral_is_abort_cb(void *next, void *curr, lll_prepare_cb_t *resume_cb);
int __wrap_lll_conn_peripheral_is_abort_cb(void *next, void *curr, lll_prepare_cb_t *resume_cb) {
    int ret = __real_lll_conn_peripheral_is_abort_cb(next, curr, resume_cb);

    put_is_abort(next, curr, ret);
    return ret;
}
#endif

void __real_lll_conn_abort_cb(struct lll_prepare_param *prepare_param, void *param);
void __wrap_lll_conn_abort_cb(struct lll_prepare_param *prepare_param, void *param) {
    diag_lab_ctl_put(CT_ABORT, diag_lab_handle_of(param), prepare_param != NULL,
                     prepare_param ? prepare_param->ticks_at_expire : ticker_ticks_now_get(), 0);
    __real_lll_conn_abort_cb(prepare_param, param);
}
