/*
 * Minimal measurement aid for the Coron central half.
 *
 * It only listens to Bluetooth connection callbacks and keeps the last events in RAM. It starts
 * no timer, sends nothing over the air, reads nothing from the controller and writes nothing to
 * flash, so the radio scheduling is the same as in the production firmware.
 *
 * Commands on the console serial port (USB): 'd' dump, 'x' drop the host connection once,
 * 'b' reboot into the UF2 bootloader. A dump is also printed when the port is opened.
 *
 * On the peripheral half the only connection is the one to the central half; it has the
 * peripheral role there, so it shows up under the "host-" names.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/init.h>
#include <zephyr/sys/reboot.h>
#if IS_ENABLED(CONFIG_RETENTION_BOOT_MODE)
#include <zephyr/retention/bootmode.h>
#endif
#include <zephyr/sys/printk.h>
#include <zephyr/sys/util.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/hci.h>
#include <stdarg.h>

#define EVENT_COUNT 256
/* The value the Adafruit nRF52 bootloader looks for in GPREGRET to stay in UF2 mode. */
#define REBOOT_TO_UF2 0x57

enum { EV_HOST_CONN = 1, EV_HOST_DISC, EV_SPLIT_CONN, EV_SPLIT_DISC, EV_SPLIT_PARAM, EV_HOST_PARAM };

static const char *const ev_names[] = {
    [EV_HOST_CONN] = "host-conn",
    [EV_HOST_DISC] = "host-disc",
    [EV_SPLIT_CONN] = "split-conn",
    [EV_SPLIT_DISC] = "split-disc",
    [EV_SPLIT_PARAM] = "split-param",
    [EV_HOST_PARAM] = "host-param",
};

struct rec_event {
    uint32_t ms;
    uint8_t type;
    uint16_t a;
    uint16_t b;
};

static struct rec_event events[EVENT_COUNT];
static uint32_t event_head;
static uint32_t counts[7];
static struct k_spinlock lock;

static void add_event(uint8_t type, uint16_t a, uint16_t b) {
    k_spinlock_key_t key = k_spin_lock(&lock);

    events[event_head % EVENT_COUNT] = (struct rec_event){.ms = k_uptime_get_32(), .type = type, .a = a, .b = b};
    event_head++;
    counts[type]++;
    k_spin_unlock(&lock, key);
}

static void on_connected(struct bt_conn *conn, uint8_t err) {
    struct bt_conn_info info;

    if (err || bt_conn_get_info(conn, &info)) {
        return;
    }
    /* a = connection interval in 1.25 ms units */
    add_event(info.role == BT_CONN_ROLE_PERIPHERAL ? EV_HOST_CONN : EV_SPLIT_CONN, info.le.interval,
              info.le.latency);
}

static void on_disconnected(struct bt_conn *conn, uint8_t reason) {
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info)) {
        return;
    }
    add_event(info.role == BT_CONN_ROLE_PERIPHERAL ? EV_HOST_DISC : EV_SPLIT_DISC, reason, 0);
}

static void on_param_updated(struct bt_conn *conn, uint16_t interval, uint16_t latency,
                             uint16_t timeout) {
    struct bt_conn_info info;

    if (!bt_conn_get_info(conn, &info)) {
        /* a = interval in 1.25 ms units, b = peripheral latency */
        add_event(info.role == BT_CONN_ROLE_PERIPHERAL ? EV_HOST_PARAM : EV_SPLIT_PARAM, interval,
                  latency);
    }
}

BT_CONN_CB_DEFINE(diag_min_conn_cb) = {
    .connected = on_connected,
    .disconnected = on_disconnected,
    .le_param_updated = on_param_updated,
};

static const struct device *const out_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

static void out(const char *fmt, ...) {
    char line[160];
    va_list ap;

    va_start(ap, fmt);
    int n = vsnprintk(line, sizeof(line) - 2, fmt, ap);
    va_end(ap);
    if (n < 0) {
        return;
    }
    n = MIN(n, (int)sizeof(line) - 3);
    line[n++] = '\r';
    line[n++] = '\n';
    for (int i = 0; i < n; i++) {
        uart_poll_out(out_dev, line[i]);
    }
    k_msleep(5);
}

/* Why the chip last reset (RESET_SOFTWARE after a fatal error or the 'b' command). */
static uint32_t reset_cause;

static int read_reset_cause(void) {
    hwinfo_get_reset_cause(&reset_cause);
    hwinfo_clear_reset_cause();
    return 0;
}

SYS_INIT(read_reset_cause, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);

static void dump(void) {
    out("ZDIAG begin version=check1 up_ms=%u boot=1 reset=0x%x", k_uptime_get_32(), reset_cause);
    out("ZDIAG now count host_conn=%u host_disc=%u split_conn=%u split_disc=%u", counts[EV_HOST_CONN],
        counts[EV_HOST_DISC], counts[EV_SPLIT_CONN], counts[EV_SPLIT_DISC]);

    uint32_t head = event_head;
    uint32_t n = MIN(head, EVENT_COUNT);

    for (uint32_t i = 0; i < n; i++) {
        struct rec_event e = events[(head - n + i) % EVENT_COUNT];

        out("ZDIAG ev boot=1 ms=%u type=%s a=%u b=%u", e.ms, ev_names[e.type], e.a, e.b);
    }
    out("ZDIAG end");
}

static void drop_host_conn(struct bt_conn *conn, void *data) {
    struct bt_conn_info info;

    if (!bt_conn_get_info(conn, &info) && info.role == BT_CONN_ROLE_PERIPHERAL &&
        info.state == BT_CONN_STATE_CONNECTED) {
        int err = bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);

        out("ZDIAG drop-host rc=%d up_ms=%u", err, k_uptime_get_32());
    }
}

static void diag_min_thread(void *p1, void *p2, void *p3) {
    bool dtr_was = false;

    while (true) {
        k_msleep(200);
        if (!device_is_ready(out_dev)) {
            continue;
        }

        uint32_t dtr = 0;

        /* Without line control there is no way to tell that the port was opened: keep listening
         * for commands, and dump only when asked.
         */
        bool no_line_ctrl = uart_line_ctrl_get(out_dev, UART_LINE_CTRL_DTR, &dtr) != 0;

        if (no_line_ctrl) {
            dtr = 1;
            dtr_was = true;
        }
        if (dtr && !dtr_was) {
            k_msleep(400);
            dump();
        }
        dtr_was = dtr;

        unsigned char ch;

        while (dtr && uart_poll_in(out_dev, &ch) == 0) {
            if (ch == 'd') {
                dump();
            } else if (ch == 'x') {
                bt_conn_foreach(BT_CONN_TYPE_LE, drop_host_conn, NULL);
            } else if (ch == 'b') {
                /* Same two paths as ZMK's &bootloader behavior. */
#if IS_ENABLED(CONFIG_RETENTION_BOOT_MODE)
                int ret = bootmode_set(BOOT_MODE_TYPE_BOOTLOADER);

                out("ZDIAG bootloader rc=%d", ret);
                k_msleep(100);
                if (ret >= 0) {
                    sys_reboot(SYS_REBOOT_WARM);
                }
#else
                out("ZDIAG bootloader");
                k_msleep(100);
                sys_reboot(REBOOT_TO_UF2);
#endif
            }
        }
    }
}

K_THREAD_DEFINE(diag_min_tid, 1536, diag_min_thread, NULL, NULL, NULL,
                K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);
