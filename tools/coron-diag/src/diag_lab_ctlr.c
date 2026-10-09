/*
 * Lab image only: read the Bluetooth controller's per-connection link-layer state through the
 * controller's own (internal, but linkable) accessor ull_conn_lll_get(), plus the ticker clock and
 * the NVMC state, at the moment of a crash. No Zephyr source is changed; this file just includes
 * the controller's headers (see CMakeLists.txt for the include directories) and reads fields.
 * Called from the assert sink (ISR context): plain memory reads only.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include <zephyr/toolchain.h>
#include <zephyr/sys/util.h>
#include <zephyr/sys/byteorder.h>

#include "hal/ccm.h"
#include "hal/radio.h"
#include "hal/ticker.h"

#include "util/util.h"
#include "util/memq.h"
#include "util/dbuf.h"

#include "pdu_df.h"
#include "pdu_vendor.h"
#include "pdu.h"

#include "lll.h"
#include "lll_vendor.h"
#include "lll_clock.h"
#include "lll_df_types.h"
#include "lll_conn.h"

#include "ticker/ticker.h"

#include <nrf.h>

#include "diag_lab.h"

extern struct lll_conn *ull_conn_lll_get(uint16_t handle);

uint32_t diag_lab_ticker_conn_base(void) { return TICKER_ID_CONN_BASE; }

void diag_lab_ctlr_snapshot(struct lab_ctlr_snap *s) {
    memset(s, 0, sizeof(*s));
    s->ticker_now = ticker_ticks_now_get();
    s->rtc0_counter = NRF_RTC0->COUNTER;
    s->nvmc_config = NRF_NVMC->CONFIG;
    s->nvmc_ready = NRF_NVMC->READY;
    for (uint16_t h = 0; h < LAB_CONN_MAX; h++) {
        struct lll_conn *lll = ull_conn_lll_get(h);
        struct lab_conn_snap *c = &s->conn[h];

        if (lll == NULL) {
            continue;
        }
        c->valid = 1;
        c->role = lll->role;
        c->handle = lll->handle;
        c->interval = lll->interval;
        c->latency = lll->latency;
        c->latency_prepare = lll->latency_prepare;
        c->latency_event = lll->latency_event;
        c->event_counter = lll->event_counter;
        c->lazy_prepare = lll->lazy_prepare;
    }
}
