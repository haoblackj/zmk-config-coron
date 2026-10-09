# 記録用ファームウェア 1 回分の計測（2026-10-09 18:19〜18:30）

## 何をしたか
右手側に記録用のファームウェア（`prod-entry-lab.conf`、md5 `68065d6832afcbaeab1e60b861ba010e`、ELF は `firmware-archive/R-lab-68065d68…/`）を 1 回書き、左手側にも同じ構成のもの（md5 `b89d33111d2d2e26535f440639e069d8`）を 1 回書いた。
両方で自己試験（`A`）が 2 段とも PASS（再起動をまたいで記録が残る、ブートローダー経由の同じファイルの書き直しでも残る。`selftest/`）。
そのあと刺激 1（PC との切断とつなぎ直し、`recon/`）を始め、2 周目で右手側が 2 回落ちた（`recon/summary.log`）。刺激は止め、左右の dump、watchdog の記録、Windows の USB の記録を取った（`recon-stop-R/`、`recon-stop-L/`）。
`campaign.out` が全体の経過、`lab-campaign.sh` が手順。

記録用のファームウェアの構成（`R-lab.config`）は本番と 2 点違う: `CONFIG_BT_CTLR_ASSERT_OVERHEAD_START=y`（本番は n。準備の遅れを記録つきの停止にするため）と `CONFIG_ZERO_LATENCY_IRQS=y`（割り込み禁止区間の検出のため。これに連動して `CONFIG_BT_CTLR_ZLI=y` になり、無線の割り込みが `irq_lock` で止まらなくなる。本番は両方 n）。

## 落ちた記録 2 件（`recon-stop-R/decoded.txt`）
どちらも `lll_central.c:250`（左右間の接続の中央側の準備で、`lll_preempt_calc` が「予定より遅い」と返した）。無線の割り込みの中（ipsr=17）で、中断された側は idle。

| | crash0（seq 376） | crash1（seq 377） |
|---|---|---|
| 起動からの時刻 | 78.0 s | 5.0 s |
| PC とつながってから | 205 ms（イベント 14 回目） | 410 ms（イベント 17 回目） |
| 左右間の接続 | interval 23（28.75 ms、split_yield の譲り）、latency 7 | 同じ |
| PC との接続 | interval 12（15 ms）、latency 10 | 同じ |
| 準備の遅れ | 7 tick（214 µs。画面には 305 µs） | 13 tick（397 µs。画面には 488 µs） |
| 直前の PC のイベント | 1.0 ms（受信 5 回） | 16.9 ms 以上（記録の尻尾いっぱい。受信 68 回、約 250 µs おき） |

時系列（`decoded.txt` の timeline、0 = 落ちた時刻）から読めること:
- 左右間のイベントの ticker は予定の 49 tick（1.5 ms）前に発火している（crash0 は -3.39 ms、crash1 は -3.58 ms の RTC0）。その直後の 10 µs の RTC0 が ticker の job（横取り用タイマーの登録）と見える。
- 左右間のイベントの予定時刻（crash0 は -1.89 ms、crash1 は -2.08 ms）に RTC0 の割り込みが無い。つまり横取り用タイマー（`TICKER_ID_LLL_PREEMPT`、`lll.c` の `preempt_ticker_start`）が発火していない。
- 準備は PC のイベントが終わった直後（-1.73 ms に入った無線の割り込みの中、-1.68 ms）に走り、そこで遅れが判定された。落ちるまでの 1.7 ms はアサートの文面の UART 出力（約 150 文字）。
- `forced`（監視タイムアウト間際のときだけ立つ）は記録に入れていないので、横取りが働かなかった理由はまだ確定しない。

ZLI 構成では SWI4（LLL の mayfly）が `ISR_DIRECT_CONNECT` で直結され、trace に載らない。RTC0 と無線の割り込みは載る。

## 1 kHz の遅れの計測（落ちていない時間帯）
PC の 15 ms 周期のイベントのたびに 100〜250 µs（同じ優先度の無線の割り込みの尻尾）。最大 246 µs。1 つの起動で `skipped=83 max=83964@2529`（起動 2.5 s に 84 ms の空白）があり、未解析。

## 次
横取り用タイマーの登録（`ticker_start` / `ticker_stop` と、その応答と発火）、準備の到着（`lll_prepare_resolve`）、中断の判定（`*_is_abort_cb`）と実行（`lll_conn_abort_cb`）を `--wrap` で記録し、本番と同じ割り込み優先度（ZLI なし）、アサート無効（本番と同じ。遅れたら左右間のイベントを 1 回飛ばす）の版で、PC との切断とつなぎ直しを 50 回回して、飛ぶ回数と理由を取る。
