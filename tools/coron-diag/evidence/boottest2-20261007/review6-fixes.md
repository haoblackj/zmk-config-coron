# レビュー #6（2026-10-08、校正実装の 5 点）への対応（2026-10-08 01:47）

各指摘を、公開したソースと最終 `.config` と依存のソースで確かめた結果と、直した場所。ソースの差分は `haoblackj/zmk-config-coron` の `feat/dya-diagnostics` で、c85ace3 と この文書を含むコミットの比較（issue のコメントにリンク）。

## 1. 既存の 10 秒の freeze 検出が、15 秒の仕掛けより先に再起動する
確認: そのとおり。`.config` に `CONFIG_ZMK_WATCHDOG_FREEZE_DETECT=y`、`FREEZE_TIMEOUT_MS=10000`、`FREEZE_FEED_DIVISOR=2`、`FREEZE_MONITOR_LOWPRIO_QUEUE=y`。`zmk-feature-watchdog/src/watchdog_freeze.c`（84ad14c6）は system と lowprio（`CONFIG_ZMK_LOW_PRIORITY_THREAD_PRIORITY=10`）の 2 キューにそれぞれ `k_work_delayable` で 5 秒ごとに `task_wdt_feed` し、期限切れの callback（タイマー ISR 文脈）で記録して `zmk_watchdog_reboot()` → `sys_reboot`。初期化は `SYS_INIT(..., APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY)`（90）、`STARTUP_DELAY_MS=0`。
- `h`: system キューが止まる → 最後の給餌から 10 秒で再起動。仕掛けは最後の給餌から 15 秒なので負ける。
- `G`: 優先度 0 の preemptible が feeder（10）と lowprio キュー（10）を飢えさせる → 同じく 10 秒で再起動。
- そのとき `cur` は done=1、reason=0、calib=h/G で、`is_incident()` は保存しない（レビューの指摘どおり）。
対応: 試験像の `boottest*.conf` に `CONFIG_ZMK_WATCHDOG_FREEZE_DETECT=n`。時間で発火してリセットする監視が TIMER4 の仕掛けだけになる。fatal 検出は残す（フォルトにだけ反応する。切ると設定リポジトリの `src/fatal_reboot.c`（10c183c、10/05）が同じ関数を定義して記録なしで再起動する側に入り、最初の試みはこの 2 つの定義の衝突でリンクに失敗した）。`S` は APPLICATION 50 で止まるので、90 の freeze 検出の初期化前。h/G とは別に扱う（README の表）。
自然発生の試験の条件として記録: 試験像は「freeze 検出なし、fatal は watchdog の記録つき再起動」。停止 3 件の像は watchdog モジュール（162637f、10/07）より前なので freeze 検出は無く、fatal の扱いは bbc509c が Zephyr 既定の halt、8d7cc27 が `fatal_reboot.c` の記録なし再起動、diag-min3 は不明。

## 2. `H` を実行すると、次のコマンドを受け付けられない
確認: そのとおり。`diag_min.c` のコンソールスレッドは `K_LOWEST_APPLICATION_THREAD_PRIO`（`CONFIG_NUM_PREEMPT_PRIORITIES=15` なので 14）。`H` の優先度 12 の無限ループは 14 を永久に止める（feeder の 10 は動く）。
対応: `H` は `H_SPIN_S`（30 秒）回って終了する（`diag_spin_bounded`）。コンソールは `ZDIAG calibrate H` を出してから約 30 秒黙り、スピナーの終了後に `ZDIAG calibrate H rc=0` を出す。校正の第 4 段をこの観測に合わせた。

## 3. `H` と `G` が生きている同じスレッドオブジェクトとスタックを再利用する
確認: そのとおり（旧 498〜518 行）。
対応: `diag_boot_calibrate()` は `int` を返す。`H`/`G` は、前に作ったスレッドがあれば `k_thread_join(&calib_thread, K_NO_WAIT)==0`（完全に終了）のときだけ `k_thread_create` し、そうでなければ `-EBUSY`（コンソールに `rc=-16`）。`h` は 1 回だけ受け付ける（2 回目は `-EBUSY`）。`G` は発火でリセットされるので再利用は起きない。ヘッダ行に `calib_live=` を出す。

## 4. `cur` の更新と CRC の確定が複数の文脈で競合する
確認: そのとおり。書き手は hook、SYS_INIT の段（main スレッド）、feeder（10）、probe（system キュー、-1）、コンソール（14）、TIMER4 の ISR。旧版は各自が `rec_seal()` を呼ぶだけで、更新と CRC の計算を一組として守っていなかった。feeder の CRC 計算中に probe が割り込んで更新と封印をし、feeder が古い内容の CRC を書き戻す順序が可能だった。
対応: スレッド文脈の書き手はすべて `rec_lock()`（`irq_lock`）の下で項目を更新し、`rec_unlock()` が CRC を計算してから解除する（`stage`、`maybe_running`、`probe_fn`、`feeder_fn`、`diag_boot_reboot`、`diag_boot_mark_reboot`、`diag_boot_calibrate`）。TIMER4 の ISR（NVIC 優先度 0、`irq_lock` の外）は排除しない。最後の書き手として記録全体を封印してからリセットし、戻らないので、割り込んだ相手の途中状態は問題にならない。残るのは「ロック中の数マイクロ秒にピンリセットが入る」場合で、CRC 不一致として検出され `invalid` に数えられる。確定済みスナップショットを別に公開する方式は採らなかった（コピーの途中でピンリセットが入れば同じ問題が残り、複雑さだけ増える）。

## 5. 記録喪失の扱いと校正の開始条件
確認: そのとおり。`ring_init_if_needed()` は ring の CRC 不正で count/dropped/invalid を黙って 0 に戻していた。`invalid` に数えるのは magic が一致した記録だけで、README の「magic/CRC 不正」と食い違っていた。枠 4 件に対し校正で 4 件作るのに、第 1 段は「count は直前の値」だった。
対応:
- ring の再初期化を `cur.ring_reinit=1`（記録として残る）とヘッダ行の `reinit=1` に出す。失われるもの（count/dropped/invalid）を README に明記。
- `invalid` の定義を「magic が一致し、fmt_ver か CRC が違った記録」と README と `ring_rec` のコメントに明記。magic 不一致（別の像、初回、RAM 不定）は数えない。
- 枠を 6 件にした（`RING_SLOTS 6`、記録形式 v4）。校正に第 0 段「`d` で読み出して保存 → `c` → `d` で count=0 を確認」を置いた。

## 6.（レビュー外。ビルドで見つかった）像ごとに記録領域のアドレスがずれる
確認: v3 の 2 像は `.noinit` の配置が偶然一致していた（0x20027400）。v4 の最初のビルドでは基準像 0x20027280、最適化像 0x20027300 と 0x80 ずれた。`.noinit` の先頭は `.bss` の大きさで決まるので、像が変われば動く。
対応: `diagrec.overlay`（`-DEXTRA_DTC_OVERLAY_FILE`）で `sram0` を 176 KB に縮め、0x2002c000〜0x2002d000 を `zephyr,memory-region`（`DIAGREC`、NOLOAD）として切り、4 つの記録を 1 つの構造体 `diag_area` にまとめてそこへ置く。像の `.bss` の大きさに関係なく同じアドレスになり、RAM が足りない像はリンクで失敗する（黙って動かない）。0x2002c000 はブートローダーの `.bss` 上端（0x2000ce28）の約 124 KB 上、スタック上端（0x20040000）の 80 KB 下。

## 像の識別
| 像 | タグ | ELF md5 | UF2 md5 | ベクタ表 27 番 | `diag_spin_forever` | USB READY 待ち |
|---|---|---|---|---|---|---|
| 基準 `coron_R-bt4` | `bt4-R-10080143` | ef0524695a8f010d24869932b2bb6f04 | 42467852c15942b81af08b8df1972fd1 | 0x00066229 | 0x662a2〜 | 0x57ef4〜0x57efb |
| 最適化 `coron_R-bt4-alt` | `bt4A-R-10080143` | bc4738657a03cda312697b14f158fac1 | 556a08fab5991e7ff7fe7756df545edd | 0x00037ff9 | 0x389d0〜 | 0x6c484〜0x6c48b |
両像とも `diag_area` = 0x2002c000（大きさ 0x93c、NOBITS）、`CONFIG_SRAM_SIZE=176`、`CONFIG_ZMK_WATCHDOG_FREEZE_DETECT` 無効、`CONFIG_ZMK_WATCHDOG_FATAL_DETECT=y`（`k_sys_fatal_error_handler` は `watchdog_fatal.c:65` のもの。`fatal_reboot.c` は build.ninja に無い）。ソースの md5 は `md5sums.txt`。
ビルドログの注意: `west build` の初回は nanopb の生成（`protoc-gen-nanopb`）が `google.protobuf` 不在で失敗し、続けて実行する `ninja` で完了する（v3 の像も同じ手順。`build-boottest2.sh`）。
