# v8: 直した版の確認（2026-10-09 21:23〜21:51）

v7（DWT の監視点つき）に `prod-entry-lab-fix.conf`（右手側の `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_FETCHING=n`、`_PROXY` も連動して外れる）を足した像（md5 `3c13f6ad4745b0dcadeb6c23e7288c64`、ELF は `firmware-archive/R-lab8-<md5>/`）を右に 1 回書き、PC の切断とつなぎ直しを 30 周（`recon/summary.log`）。

結果（`recon/per-dump.txt`、`recon-end-R/decoded.txt`）:
- 準備の遅れ 0 回（左右間 id 6: over=0、最大 4 tick。PC id 5: over=0）。記録 0 件、再起動 0。
- 横取りの誤認の出入り 0 回（`flips` は起動直後の 1 回のまま、`stale_runs` は起動直後の 2 のまま）。カウンタは終始 `req == ack`（最後 70/70）。
- DWT が捕まえた `preempt_req` への書き込み 1,094 件は全部コントローラ自身の `ticker_start_op_cb`（`req++`）。値 0 のものは 4 件で、どれも `ack=255`（8 bit の桁あふれで 0 に回っただけ、正常）。ZMK 側からの書き込みは 0 件。
- 左（v3）は変化なし。

v7（同じ刺激、直す前）は 7 周で誤認 3 回、遅れ 2 回、ZMK 側からの 0 の書き込みが周ごとに 1 回。

本家 zmkfirmware/zmk の `main` にも同じ行がある（`app/src/split/central.c` 62 行、`app/src/split/bluetooth/central.c` 961〜964 行、`source` は `uint8_t`）ので、報告先は本家。
