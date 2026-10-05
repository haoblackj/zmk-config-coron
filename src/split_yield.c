/*
 * PC とつながっていないあいだだけ、左手側との通信をゆっくりにする。
 *
 * 右手側は、左手側へのセントラル（7.5 ms 間隔）と PC へのペリフェラルを同じ無線で兼ねている。
 * Zephyr のコントローラは、確立中のペリフェラル接続を優先しない。最初の6回のイベントで開く
 * 受信窓は、その途中で始まる自分のセントラルのイベントに打ち切られる。PC が左手側の間隔の
 * 倍数（15 ms）でつなぎに来ると、6回とも同じ位置で打ち切られ、確立の失敗（0x3e）が
 * PC とキーボードの時計がずれるまで数十回続く（2026-10-05 の実測で、つなぎ直し 24 回中 4〜6 回）。
 * PC とつながっていないあいだは、左手のキーを打っても届け先が無い。そのあいだだけ左手側との
 * 間隔を広げて場所を空ければ、打鍵中の遅延を増やさずに済む。
 *
 * 前提と外しどき（docs/bluetooth-stability.md に詳細）:
 * - Zephyr に「接続パラメータ更新時にペリフェラルが落ちる」修正（zmkfirmware/zephyr の
 *   v4.1.0+zmk-fixes にある b2aee46d）が入っていること。無い版では、切り替えの瞬間に左手側が落ちる。
 * - Zephyr が確立中の接続を優先するようになるか、ZMK が左右間の通信条件を自分で動かすように
 *   なったら、このファイルは外す。
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

/*
 * 28.75 ms（1.25 ms 単位）。23 は素数なので、ホストが選ぶ接続間隔がこの倍数になることはまず無く、
 * ホスト側の最初の6回が全部左手側のイベントに重なることがない。
 */
#define YIELD_INTERVAL 23
/* 待機中の左手側が起きる頻度を、ZMK の設定（31 * 7.5 ms）とほぼ同じに保つ。 */
#define YIELD_LATENCY 7
/* 確立の失敗はホスト側の6回ぶんの間隔のうちに分かる。速い設定へ戻すのはそのあと。 */
#define SETTLE_DELAY K_MSEC(150)
#define RETRY_DELAY K_SECONDS(1)

static void evaluate(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(evaluate_work, evaluate);

static void apply(struct bt_conn *conn, void *data) {
    const struct bt_le_conn_param *want = data;
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) || info.role != BT_CONN_ROLE_CENTRAL ||
        info.state != BT_CONN_STATE_CONNECTED) {
        return;
    }
    if (info.le.interval == want->interval_max && info.le.latency == want->latency) {
        return;
    }

    int err = bt_conn_le_param_update(conn, want);

    if (err && err != -EALREADY) {
        k_work_reschedule(&evaluate_work, RETRY_DELAY);
    }
}

static void evaluate(struct k_work *work) {
    static const struct bt_le_conn_param fast =
        BT_LE_CONN_PARAM_INIT(CONFIG_ZMK_SPLIT_BLE_PREF_INT, CONFIG_ZMK_SPLIT_BLE_PREF_INT,
                              CONFIG_ZMK_SPLIT_BLE_PREF_LATENCY, CONFIG_ZMK_SPLIT_BLE_PREF_TIMEOUT);
    static const struct bt_le_conn_param yield = BT_LE_CONN_PARAM_INIT(
        YIELD_INTERVAL, YIELD_INTERVAL, YIELD_LATENCY, CONFIG_ZMK_SPLIT_BLE_PREF_TIMEOUT);

    bt_conn_foreach(BT_CONN_TYPE_LE, apply,
                    (void *)(zmk_ble_active_profile_is_connected() ? &fast : &yield));
}

static void on_connected(struct bt_conn *conn, uint8_t err) {
    if (!err) {
        k_work_reschedule(&evaluate_work, SETTLE_DELAY);
    }
}

static void on_disconnected(struct bt_conn *conn, uint8_t reason) {
    k_work_reschedule(&evaluate_work, K_NO_WAIT);
}

/* 望む状態が変わったときに進行中だった更新は、ここで終わる。もう一度確かめる。 */
static void on_param_updated(struct bt_conn *conn, uint16_t interval, uint16_t latency,
                             uint16_t timeout) {
    k_work_reschedule(&evaluate_work, SETTLE_DELAY);
}

BT_CONN_CB_DEFINE(split_yield_conn_cb) = {
    .connected = on_connected,
    .disconnected = on_disconnected,
    .le_param_updated = on_param_updated,
};

static int on_profile_changed(const zmk_event_t *eh) {
    k_work_reschedule(&evaluate_work, SETTLE_DELAY);
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(split_yield, on_profile_changed);
ZMK_SUBSCRIPTION(split_yield, zmk_ble_active_profile_changed);
