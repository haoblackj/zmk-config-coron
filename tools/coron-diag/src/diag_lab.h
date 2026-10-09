/* Shared between diag_lab.c (recorder) and diag_lab_ctlr.c (controller snapshot). Lab image only. */
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
};

struct lab_ctlr_snap {
    uint32_t ticker_now;   /* ticker_ticks_now_get(): RTC0 ticks (30.517 us) */
    uint32_t rtc0_counter; /* NRF_RTC0->COUNTER */
    uint32_t nvmc_config;  /* NRF_NVMC->CONFIG: 1 = write enabled, 2 = erase enabled */
    uint32_t nvmc_ready;
    struct lab_conn_snap conn[LAB_CONN_MAX];
};

void diag_lab_ctlr_snapshot(struct lab_ctlr_snap *s);
