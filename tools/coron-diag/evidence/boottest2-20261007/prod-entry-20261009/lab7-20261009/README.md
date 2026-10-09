# v4〜v7: 横取りが止まる原因の特定（2026-10-09 19:48〜21:13）

## 流れ
- v4（`lab4-20261009/`）: 遅れた瞬間の ticker 一覧を追加。遅れの記録 1 件（30 周で 1 回）。その瞬間の ticker 一覧に横取りタイマー（id 0）は無い。つまりコントローラの `preempt_ticker_start` が「登録済み」と誤認しているのは、ticker に残った登録のせいではない。
- v5（`lab5-20261009/`）: 「待ち行列に入れた準備に横取りタイマーが登録されるか」を周ごとに判定し、変わった瞬間に記録。誤認の期間は 52→323 秒、407→672 秒、734 秒→…。どれも約 260 秒で、24 bit の時刻比較が逆転する 256 秒と一致。誤認に入る瞬間は毎回 PC の切断（`ticker_stop conn0`）の直後、戻る瞬間は「停止 → ticker に無い（status=1）→ カウンタが揃い直す → 登録 → 発火」。
- v6（`lab6-20261009/`）: `lll.c` の静的変数（`preempt_req` ほか 6 個と `ticks_at_preempt`）を 2 段ビルドで番地指定して直読み。誤認中は `req=0 ack=132`（戻ると 133/133）。`preempt_req` だけがゼロに書き換えられている。`lll.c` に `preempt_req = 0` を書く場所は無い。
- v7（このディレクトリ）: Cortex-M4 の DWT（データ監視点）で `preempt_req` への書き込みに DebugMonitor 例外を掛け、書いた直後の PC を記録。正規の `req++`（`ticker_start_op_cb`、RTC0 割り込み内）は毎回精密に捕まる。値 0 を書いたのは `raise_zmk_peripheral_battery_state_changed`（`battery_state_changed.c:12`、監視点の性質で実際のストアの数命令あと）で、呼び元は `zmk_split_transport_central_peripheral_event_handler`（`zmk/app/src/split/central.c:63`）。スレッド文脈。PC の切断のたび（約 43 秒おきの周回に一致）。

## 原因（ZMK、cormoran 版 main+dya、コミット e5c9b691）
`zmk/app/src/split/bluetooth/central.c` の切断コールバック（1197 行付近）は、`CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=y` のとき、切れた接続が何であれ「電池残量 0」のイベントを作る。その `source` は `peripheral_slot_index_for_conn(conn)`（int、見つからなければ -EINVAL）を `uint8_t` に入れたもので、PC の接続（周辺側の枠に無い）では -22 → 234 になる。受け取る `zmk/app/src/split/central.c:62` は `peripheral_battery_levels[source] = level` を範囲検査なしで実行する（読み出し側の 208 行には検査がある）。配列は `CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS=1` で 1 バイト（0x2001f080）なので、234 バイト先の 0x2001f16a、この構成では Bluetooth コントローラの `preempt_req` に 0 を書く。

結果: PC が切れるたびにコントローラの横取り（進行中のイベントを次のイベントの時刻で中断する仕組み）が最長 256 秒止まる。その間に長いイベント（PC の接続直後の受信窓、Windows のデータのやり取り）の下に左右間のイベントの予定時刻が入ると、準備が遅れ、`CONFIG_BT_CTLR_ASSERT_OVERHEAD_START=y` なら `lll_central.c:250` で落ちる（10/05、10/07 の現場、10/09 朝と夕のラボ）。無効なら左右間のイベントが 1 回飛ぶだけ。

## 直し方
- 本来の直しは ZMK 側（`source` の検査、または切断コールバックで周辺側の接続だけを対象にする）。
- 設定リポジトリの範囲で経路を消す: 右手側の `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=n`（`_PROXY` も連動して外れる）。代償は左手側の電池残量が右手側や PC から見えなくなること。v8（`prod-entry-lab-fix.conf`）で、同じ刺激のもと DWT の 0 書き込みが 0 回、誤認の出入りが 0 回、遅れ 0 回になることを確かめる。

## ファイル
- `recon/recon-io10-cycle1-record.out`: 1 周目の dump（誤認へ入った記録、DWT の記録 4 件の 0 書き込み）。`recon-io10-decoded.txt`: 読んだもの。
- `R-lab7.config`、`campaign*.out`。ELF は `firmware-archive/R-lab7-6b7ba5d6…/`。
