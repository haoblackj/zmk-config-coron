# T2: 整え処理の検証（2026-10-09 00:37〜00:49、右手側 B17318CDBE9A61B1、試験像 bt6-R-10090036 / bt6A-R-10090036 = bt5 + `CONFIG_CORON_DIAG_ENTRY_CLEAN`）
T1（`../t1-20261009/`）で DFU 直後の起動にだけ残ると分かった 4 つ（POWER の USB 割り込み許可 0x380、NVIC の USBD、EVENTS_HFCLKSTARTED、USBD の EVENTCAUSE）のうち、起動を止めうる経路（禁止条件 A と B）に関わる前 3 つと SysTick を、フックで網を張った直後に消す処理（`diag_boot.c` の `entry_clean`。待ちなし、クロック操作なし、NVIC は網の TIMER4 だけ残す）を入れ、その直後に 4 点目の写し（`clean`）を取る像で、同じループを回した。手動操作なし、立ち会いなし。
- `loop-1009-003752/`: 書き込み群（`-Mode write -Dwells 1,1,1`）。基準像の書き込みと試行 3 回とも正常完了、事故記録 0 件、本番復帰 PASS。DFU 直後の起動は seq 29、30、31、32。
- `loop-1009-004421/`: リセット群（`-Mode reset -Dwells 1,1,1`）。基準像の書き込み（seq 33、DFU 直後）、`r` の起動 seq 34、35、36、すべて正常完了、事故記録 0 件、本番復帰 PASS。
- `loop-1009-005523/`: 書き込み群の再実施（00:55〜01:02、試験像 bt7-R-10090053 / bt7A-R-10090053 = bt6 + レビュー対応）。基準像の書き込みと試行 3 回とも正常完了、事故記録 0 件、本番復帰 PASS。DFU 直後の起動は seq 37、38、39、40。
- `snap-table.md`: 全起動の全点の値（3 ループ分）。`md5sums.txt`: 像の md5。`build-prod-entry.sh`: 本番候補のビルド手順。

## 結果（各起動の 4 点。経路内は毎回同じ）
| 点 | DFU 直後（seq 29〜33、5 回） | `r` 直後（seq 34〜36、3 回） |
|---|---|---|
| フックの先頭（整え処理の前） | INTEN=0x380、NVIC ISER[1]=0x80（USBD）、HFCLKSTARTED=1、USBDETECTED=0 | INTEN=0、NVIC 0、HFCLKSTARTED=0、USBDETECTED=1 |
| 整え処理の直後（起動から 283〜307 µs） | **INTEN=0、NVIC ISER=TIMER4（網）だけ、保留 0、HFCLKSTARTED=0、SysTick CTRL=0x4（停止）、USBDETECTED=0** | INTEN=0、NVIC は TIMER4 だけ、保留 0、HFCLKSTARTED=0、SysTick 0x4、USBDETECTED=1 |
| クロックドライバの後（約 1.6 ms） | INTEN=0、NVIC ISER[0]=POWER_CLOCK + TIMER4、ISER[1]=0 | 同じ |
| USB 有効化の後（約 24 ms） | INTEN=0x381、USBD ENABLE=1、LFCLK は XTAL で動作 | 同じ |
禁止条件 A と B に関わる項目（POWER/CLOCK の割り込み許可、NVIC の有効と保留、HFCLKSTARTED イベント）について、整え処理の後の DFU 直後の起動は `r` の起動と同じ値になり、以後のドライバ初期化も同じ経路を通った（8/8）。残る経路差は `r` 側の USBDETECTED イベント（整え処理は消さない。ドライバは `usb_dc_attach` でこのイベントか USBREGSTATUS から ATTACHED を作るので、どちらでも USB は有効になる。T2 の 8 回とも USB は列挙された）。

## Codex のレビューと対応（`../rootcause-plan-20261008/codex-review-diag-entry.md`）
`diag_entry.c` のレビューは条件つき採用。「止めるべき」1 件と「直すべき」3 件を直した。
- 印の途中書き込み（止めるべき）: 前回の値を写した直後に、現在の記録の stage 対を崩して無効化し（`stage_inv = stage`）、整え処理と付帯情報の書き込みのあと、最後に `stage` と `~stage` の対を書いて有効化する。途中でリセットされても、前回の段が今回の段として読まれない。
- dump 行が 150 文字を超えうる（直すべき）: キー名を短くし、最長でも 104 文字にした。
- USBD の EVENTCAUSE の残留（直すべき）: フックで SUSPEND と RESUME を W1C で消し、EVENTS_USBEVENT も 0 にする。本番の `diag_entry.c` と試験像の `entry_clean` の両方に入れ、試験像で DFU 起動 4 回を再確認した（下）。
- overlay なしでもビルドが通ってしまう（直すべき）: 記録領域の devicetree ノードの番地と大きさを `BUILD_ASSERT` で確かめる。
- Kconfig と overlay のコメントを本番用途に合わせた。

### 再確認（`loop-1009-005523/`、bt7 / bt7A）
DFU 直後の 4 回（seq 37〜40）とも、フックの先頭では INTEN=0x380、NVIC ISER[1]=0x80、HFCLKSTARTED=1、USBD EVENTCAUSE=0x300 で、整え処理の直後（起動から 299〜308 µs）には INTEN=0、NVIC は TIMER4 だけ、保留 0、HFCLKSTARTED=0、**EVENTCAUSE=0**、SysTick CTRL=0x4。起動ごとに変わる値は RTC1 の CC[0] だけ。

## 本番候補（`.build/R-entry`、`coron_R-prod-entry.uf2`、md5 fedd88a480bdfba476aba4e5cddd2617、`md5sums.txt`。書き込んでいない）
2725423 と同じ構成（snippet `studio-rpc-usb-uart`、設定リポジトリ + `coron-diag` モジュール、freeze と fatal の検出あり）に、`tools/coron-diag/src/diag_entry.c`（`CONFIG_CORON_DIAG_ENTRY`: 同じ整え処理を `board_early_init_hook` で行い（本番には網が無いので NVIC は全部消す）、固定番地 0x2002c000 に 8 語の「起動の進みの印」を置き、次の起動の dump に `ZDIAG crumb …` の 1 行で出す）と `diagrec.overlay` を足したもの。`.config` の差は `CONFIG_BOARD_EARLY_INIT_HOOK=y`、`CONFIG_CORON_DIAG_ENTRY=y`、`CONFIG_DT_HAS_ZEPHYR_MEMORY_REGION_ENABLED=y`、`CONFIG_SRAM_SIZE` 256 → 176 の 4 行。試験用の計測器は入らない。

## 言えること、言えないこと
- 言えること: 整え処理で、DFU 直後の起動が Zephyr のドライバに渡す状態は、禁止条件に関わる項目について `r` の起動と同一になる（再現に頼らない検証）。整え処理入りで 8 回の起動は正常で、本番復帰も通る。
- 言えないこと: 現場の停止がこの残留から起きていたこと。整え処理で停止が無くなること（率の幅 3.4〜28% に対し、観測は 0 件のまま）。印（crumb）は本番に入れてはじめて、次に止まったときの段を教える。
