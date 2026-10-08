# 無人ループ（書き込み群）の実機記録（2026-10-08 15:42:32〜16:41:24、右手側 B17318CDBE9A61B1、スクリプト 9191082）
レビュー #19（9191082 を「計画済みの書き込み群 5 試行へ進めてよい」と判断）とリーダーの合図を受けて開始。手動操作なし、立ち会いなし、途中の応答なし。
実行: `calib-loop.ps1 -Mode write -Dwells 13,26,17,21,13 -NoNewTrialAfter "2026-10-08 18:02" -RestoreReserveMin 10`（基準像 bt4 md5 df108d7a…、最適化像 bt4A md5 e1e62efe…、本番像 2725423 md5 889f3a48…）。
このディレクトリは実行のログディレクトリの全ファイル（`summary.log`、`steppre-*.log`、`flash-base-*.log`、`trialN-write-*.log`、交換ごとの `*-ioN.out/.err`、`result-*.json`、`ledger.json`/`ledger.csv`、`flash-prod-*.log`、子の `child-*.out/.err`、`console.txt`）。CR を外した以外は原文。

## 各段階の実績と事故記録
| 段階 | 時刻 | 結果 | 実測 |
|---|---|---|---|
| 事前確認 | 15:42:33〜15:42:38 | PASS | 3 像の存在と md5 一致。本番像 2725423 から完全な dump（`version=prof1`、`ZBOOT` 行なし） |
| 基準像の書き込み | 15:42:38〜15:43:10 | PASS | `b` 受理、E: 1 台（シリアル一致）、bt4 を複写、消失、app。dump: `cur seq=9 tag=bt4-R-10080217 done=1 reinit=0`、`ring count=0 dropped=0 invalid=0 reinit=0` |
| 基準（試行 0） | 15:43:10〜15:43:16 | PASS | seq=9、count=0、dropped=0、invalid=0、reinit=0、done=1、up_ms=10413。事故記録なし |
| 試行 1（稼働 13 分、bt4 → bt4A） | 15:43:16〜15:57:00 | 正常完了 | 稼働中の USB 読み取り 76 回すべて app。稼働終了の dump: up_ms 16197 → 803668（進み 787471 ms、許容 [778000, 900000]）、操作直前の稼働 13.39 分、同じ起動で seq/count/dropped/invalid/reinit 不変。`b` 送信（15:56:32.063）、応答行 `ZDIAG bootloader rc=0` あり、E: 1 台、bt4A を複写（15:56:55）、消失、app。起動後（読み取り 1 回目）: seq=10、tag=bt4A-R-10080217、done=1、reinit=0、count=0、dropped=0、invalid=0、up_ms=4899 |
| 試行 2（稼働 26 分、bt4A → bt4） | 15:57:00〜16:23:46 | 正常完了 | USB 読み取り 152 回すべて app。up_ms 10210 → 1580567（進み 1570357 ms）、操作直前の稼働 26.34 分、同じ起動で不変。`b` 送信（16:23:18.815）、応答行あり、bt4 を複写（16:23:41）、消失、app。起動後: seq=11、tag=bt4-R-10080217、done=1、reinit=0、count=0、dropped=0、invalid=0、up_ms=4832 |
| 試行 3（稼働 17 分、bt4 → bt4A 予定） | 16:23:46〜16:40:59 | FAIL（スクリプトの前提。事故ではない） | USB 読み取り 99 回すべて app。up_ms 10215 → 1034574（進み 1024359 ms）、操作直前の稼働 17.24 分、同じ起動で不変（count=0 dropped=0 invalid=0 reinit=0）。`b` 送信（16:40:58.930、子の `sent` 刻印あり）。送信の 231 ms 後に読み取り例外を観測（`port lost (… ポートは閉じています)` 16:40:59.161。USB 離脱そのものの発生時刻はこのログからは確定しない）、応答行 `ZDIAG bootloader` は届かず、`FAIL b acknowledged` → `STOPPED before: copy the image to the UF2 drive`。像は書いていない。実機は `b` のとおりブートローダーに入っていた（下の復帰が `initial state=boot` を観測） |
| 試行 4（21 分）、5（13 分） | — | 未実施 | 試行 3 の FAIL で停止 |

台帳（`summary.log` 16:41:24.409）: `ledger: mode=write trials started=3, b sent=3, images written=2 (boots after a write), boots observed=2, RUNNING confirmed=2, completed without event=2, not sent (child refused)=0, send not attempted=0; stop=trial 3 failed (rc=1)`。
終了: `LOOP FAILED | RESTORE PASS`、`results: pre=0 flash-base=0 baseline=0 t1=0 t2=0 t3=1 t4=not-run t5=not-run restore=0 stop=trial_3_failed_(rc=1)`、終了コード 1。
起動停止の実績: 対象となる書き込み後の起動 2 回（試行 1、2）、事故記録 0 件。試行開始 3、`b` 送信 3 は別の段階の分母（試行 3 は複写の前に止まり、書き込み後の起動は無い）。観測した 3 回の起動（seq 9、10、11。基準像の書き込み後の 1 回と試行の書き込み後の 2 回）はすべて done=1（RUNNING 到達）、reinit=0 で、count/dropped/invalid はどの読み取りでも 0 → 0。接続の計数は全読み取りで `host_conn=1 host_disc=0 split_conn=1 split_disc=0`。

## 本番復帰
16:40:59〜16:41:24、PASS。本番像の md5 一致（最初と複写の直前）、初期状態 boot（ブートローダー）、E: 1 台（シリアル一致）、ブートローダー 1 台、複写（16:41:19）、消失、app（16:41:21）。dump: `ZDIAG begin version=prof1 up_ms=3688 boot=1 reset=0x2`、`ZDIAG end`、`#TRUNC` なし、`ZBOOT` 行 0 本（本番像）。右手側は本番像 2725423 で app として動作中。

## 試行 3 が止まった理由
`b` を受けたファームは応答行 `ZDIAG bootloader rc=N` を出し、100 ms 待ってから再起動する（`diag_min.c`）。コンソールの子 `calib-io.ps1` は送信後 200 ms 眠ってから最初に読んでいたので、応答行を拾えるかはこの 100 ms の間合いと USB の切断の順序次第だった。試行 1、2 では拾え、試行 3 では最初の読み取りが例外（ポートは閉じています）になった。USB 離脱そのものの発生時刻と、応答行が失われた機構（デバイスから出る前に再起動したのか、ホストのドライバのバッファに届いた後にポートごと捨てられたのか）は、ホスト側からは確定できない。試行の子は `Require 'b acknowledged'` でこの応答行を前提にしていたため、実機がブートローダーに入っていたにもかかわらず FAIL にした。
修正（次の版。実機では未実施）: 応答行は証拠として記録し（`'b' reply: ack line … seen=…, port lost after the send=…`）、関門にしない。`b` の関門はその後の USB 状態（30 秒以内にこのシリアルのブートローダーが現れること）、`r` の関門は再起動の直接の証拠（応答行、送信後のポート消失、10 秒以内の USB 離脱のどれか）。子は送信直後に読み、以後 20 ms ごとに読む。同じ前提は校正スクリプトの基準像の書き込み、第 6 段の `r`、第 7 段の `b` と、本番復帰にもあったので同じ変更で直した。模擬 7 場面を追加（`review6-fixes.md`「実機ループ初回」）。

## 未検証事項
- 書き込み群は 5 試行のうち 3 試行で止まり、書き込み後の起動を観測したのは 2 回（13.39 分、26.34 分の稼働の後）。残り（21 分、13 分の稼働）は未実施。3 試行で事故 0 件でも原因候補の否定にはならない。
- リセット群（`-Mode reset`）は未実施。
- ピンリセットを挟んだ保持、USB を抜いた起動、本番像での再現、自動復帰で救えない停止（NVIC 優先度 0 まで抑止、TIMER4 準備前、ブートローダー内）は、この実行では観測していない。
- 気づき（判定には影響なし）: 基準像の書き込み後の最初の dump が `seq=9 reinit=0` で、校正の最後（seq 8、第 8 段で `c` 済み）から番号が続いた。本番像 2725423 の稼働（11:04〜15:42）を挟んでも 0x2002c000 の記録領域は保持されていた（本番像はこの領域に触れない）。計画書と模擬は「基準像を書いた後の最初の起動は reinit=1」としていたが、ファームは領域が有効なら再初期化しないので、これは模擬の前提が狭かっただけで、判定（基準で確定した値との一致）はそのまま成立する。
