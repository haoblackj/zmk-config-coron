# Draft: bug report for zmkfirmware/zmk (not yet posted)

Posting rules agreed with the leader (2026-10-09): post only when the usage quota allows, follow
the project's contribution norms (issue template, Discord-first rules if any), do not post if the
project does not accept AI-written reports. The report would go out under the leader's GitHub
account (`env -u GH_TOKEN`, the bot's token cannot write to other repositories), so the leader
reads and approves this text first. Disclose that it was written by an AI assistant from real
measurements.

---

**Title:** Split BLE central: out-of-bounds write to `peripheral_battery_levels[]` on a non-peripheral disconnect (`source` = `(uint8_t)-EINVAL` = 234)

**Describe the bug**

With `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=y`, the split BLE central's
`split_central_disconnected()` callback (`app/src/split/bluetooth/central.c`) queues a
"battery level 0" peripheral event for *every* disconnected connection, including the host
(central-role) connection:

```c
struct peripheral_event_wrapper ev = {
    .source = peripheral_slot_index_for_conn(conn),   // int: -EINVAL for a non-peripheral conn
    .event = {.type = ZMK_SPLIT_TRANSPORT_PERIPHERAL_EVENT_TYPE_BATTERY_EVENT,
              .data = {.battery_event = {.level = 0}}}};
```

`peripheral_event_wrapper.source` is `uint8_t`, so `-EINVAL` (-22) becomes 234. The event is then
handled by `zmk_split_transport_central_peripheral_event_handler()` in `app/src/split/central.c`:

```c
case ZMK_SPLIT_TRANSPORT_PERIPHERAL_EVENT_TYPE_BATTERY_EVENT: {
    ...
    peripheral_battery_levels[source] = ev.data.battery_event.level;   // no bounds check
```

`peripheral_battery_levels` has `ZMK_SPLIT_CENTRAL_PERIPHERAL_COUNT` entries (1 on a two-half
keyboard), so every host disconnect writes a 0 byte 234 bytes past the array. The getter below it
(`zmk_split_central_get_peripheral_battery_level`) does check `source >= ARRAY_SIZE(...)`; the setter
does not.

**What the stray byte hit here, and the consequence**

On our build (nRF52840, Zephyr 4.1 split controller, `CONFIG_BT_CTLR_SCHED_ADVANCED=y`) the byte at
`peripheral_battery_levels + 234` is the Bluetooth controller's `preempt_req` (static in
`subsys/bluetooth/controller/ll_sw/nordic/lll/lll.c`). Zeroing it makes `preempt_ticker_start()`
believe a preempt timeout is pending, so no preempt timeout is started for queued prepares until the
24-bit tick comparison wraps (~256 s). During that window a radio event queued under a long event
(e.g. the first connection events of the host after reconnect) runs late; with
`CONFIG_BT_CTLR_ASSERT_OVERHEAD_START=y` (the default) that is a fatal
`LL_ASSERT_OVERHEAD` in `lll_central.c` (`.prepare_cb: Actual EVENT_OVERHEAD_START_US = ...`),
with it off the event is skipped. Which variable gets hit is build-dependent, so other builds may see
different symptoms or none.

**To Reproduce**

1. Two-half BLE split, `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=y` on the central.
2. Connect the central to a host, then disconnect the host (we used
   `bt_conn_disconnect()` on the host connection from a console command; unpairing from the host
   should do the same).
3. Observe `peripheral_event_handler` receiving a battery event with `source == 234`
   (e.g. a `LOG_DBG` of `source`), or watch the byte at `&peripheral_battery_levels[234]`.

We confirmed the write site with a DWT data watchpoint + DebugMonitor on the corrupted byte: the
trap fires in thread context right after `peripheral_battery_levels[source] = ...` (imprecise by a
few instructions), caller `zmk_split_transport_central_peripheral_event_handler`, once per host
disconnect. Compiling the feature out (`..._FETCHING=n`) removes the write and the late radio
events (30 host reconnects: 0 late prepares, versus 3 stale periods in 7 reconnects before).

**Expected behavior**

No write outside the array. Either the disconnected callback only queues the battery event when
`peripheral_slot_index_for_conn()` succeeds (the connection was a peripheral), or the handler rejects
`source >= ZMK_SPLIT_CENTRAL_PERIPHERAL_COUNT` like the getter does (both would be sensible).

**Environment**

- ZMK `main` (the lines above are present at the current `main`: `app/src/split/central.c` line 62,
  `app/src/split/bluetooth/central.c` lines 961-964), also in the `cormoran/zmk` `main+dya` branch we run.
- Board: Seeed XIAO nRF52840 Sense (`xiao_ble`), custom shield `coron` (split, central = right half),
  Zephyr `v4.1.0+zmk-fixes`.
- `CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS=1`, battery proxy on.

**Additional context**

Full measurement notes (controller scheduling trace, the DWT trap records, counters read before and
after the fix) are in our config repository: https://github.com/haoblackj/zmk-config-coron (branch
`feat/dya-diagnostics`, `tools/coron-diag/evidence/.../lab7-20261009/README.md` and `lab8-20261009/`).
This report was drafted by an AI assistant (Claude) from those measurements and reviewed by the
repository owner before posting.
