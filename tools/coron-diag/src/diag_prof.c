/*
 * Why does ZMK think the active profile's host is not connected while the host is?
 *
 * 300 ms after every host connection, and on the 'p' command, write down what ZMK compares:
 * every profile's stored address (with its type), every bond the host stack holds, every
 * connection object in the pool (index, role, state, id, dst), and which object
 * bt_conn_lookup_addr_le() returns for the active profile's address. Snapshots stay in RAM and
 * are printed by diag_prof_print(), which diag_min.c calls from its dump and from 'p'.
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/sys/printk.h>
#include <stdarg.h>
#include <string.h>

#include <zmk/ble.h>

#define SNAP_BYTES 1536
#define SNAP_COUNT 3

static char snaps[SNAP_COUNT][SNAP_BYTES];
static size_t snap_len[SNAP_COUNT];
static uint32_t snap_head;
static int cur;

static void put(const char *fmt, ...) {
    va_list ap;
    size_t room = SNAP_BYTES - snap_len[cur];

    if (room < 2) {
        return;
    }
    va_start(ap, fmt);
    int n = vsnprintk(snaps[cur] + snap_len[cur], room - 1, fmt, ap);
    va_end(ap);
    if (n < 0) {
        return;
    }
    snap_len[cur] += MIN((size_t)n, room - 2);
    snaps[cur][snap_len[cur]++] = '\n';
    snaps[cur][snap_len[cur]] = '\0';
}

static const char *state_name(enum bt_conn_state s) {
    switch (s) {
    case BT_CONN_STATE_DISCONNECTED:
        return "DISCONNECTED";
    case BT_CONN_STATE_CONNECTING:
        return "CONNECTING";
    case BT_CONN_STATE_CONNECTED:
        return "CONNECTED";
    case BT_CONN_STATE_DISCONNECTING:
        return "DISCONNECTING";
    default:
        return "?";
    }
}

static void put_conn(struct bt_conn *conn, void *data) {
    struct bt_conn_info info;
    char dst[BT_ADDR_LE_STR_LEN];
    char gdst[BT_ADDR_LE_STR_LEN];

    if (bt_conn_get_info(conn, &info)) {
        put("ZPROF conn idx=%u info-error", bt_conn_index(conn));
        return;
    }
    bt_addr_le_to_str(info.le.dst, dst, sizeof(dst));
    bt_addr_le_to_str(bt_conn_get_dst(conn), gdst, sizeof(gdst));
    put("ZPROF conn idx=%u role=%s state=%s id=%u dst=%s get_dst=%s sec=%u",
        bt_conn_index(conn), info.role == BT_CONN_ROLE_PERIPHERAL ? "periph" : "central",
        state_name(info.state), info.id, dst, gdst, bt_conn_get_security(conn));
}

static void put_bond(const struct bt_bond_info *info, void *data) {
    char a[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(&info->addr, a, sizeof(a));
    put("ZPROF bond %s", a);
}

static void snapshot(const char *why) {
    cur = snap_head % SNAP_COUNT;
    snap_len[cur] = 0;
    snap_head++;

    put("ZPROF snap #%u why=%s up_ms=%u", snap_head, why, k_uptime_get_32());

    int active = zmk_ble_active_profile_index();

    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        char a[BT_ADDR_LE_STR_LEN];

        bt_addr_le_to_str(zmk_ble_profile_address(i), a, sizeof(a));
        put("ZPROF profile %d%s addr=%s open=%d connected=%d", i, i == active ? "*" : "", a,
            zmk_ble_profile_is_open(i), zmk_ble_profile_is_connected(i));
    }
    bt_foreach_bond(BT_ID_DEFAULT, put_bond, NULL);
    bt_conn_foreach(BT_CONN_TYPE_LE, put_conn, NULL);

    struct bt_conn *found = bt_conn_lookup_addr_le(BT_ID_DEFAULT, zmk_ble_active_profile_addr());

    if (found) {
        struct bt_conn_info info;

        bt_conn_get_info(found, &info);
        put("ZPROF lookup(active) -> idx=%u state=%s", bt_conn_index(found),
            state_name(info.state));
        bt_conn_unref(found);
    } else {
        put("ZPROF lookup(active) -> none");
    }
    put("ZPROF active_is_connected=%d", zmk_ble_active_profile_is_connected());
}

static void snap_work_cb(struct k_work *work) { snapshot("host-conn"); }
static K_WORK_DELAYABLE_DEFINE(snap_work, snap_work_cb);

static void on_connected(struct bt_conn *conn, uint8_t err) {
    struct bt_conn_info info;

    if (!err && !bt_conn_get_info(conn, &info) && info.role == BT_CONN_ROLE_PERIPHERAL) {
        k_work_reschedule(&snap_work, K_MSEC(300));
    }
}

BT_CONN_CB_DEFINE(diag_prof_conn_cb) = {
    .connected = on_connected,
};

void diag_prof_take(void) { snapshot("cmd"); }

void diag_prof_print(void (*out)(const char *fmt, ...)) {
    uint32_t n = MIN(snap_head, SNAP_COUNT);

    for (uint32_t k = 0; k < n; k++) {
        char *s = snaps[(snap_head - n + k) % SNAP_COUNT];

        while (*s) {
            char *nl = strchr(s, '\n');

            if (!nl) {
                break;
            }
            *nl = '\0';
            out("%s", s);
            *nl = '\n';
            s = nl + 1;
        }
    }
}
