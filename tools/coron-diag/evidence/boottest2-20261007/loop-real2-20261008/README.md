# 無人ループ（書き込み群）2 回目の実機記録（2026-10-08 20:34:57〜21:14:27、右手側 B17318CDBE9A61B1、スクリプト 61823c9）
61823c9 の再レビュー通過（「計画どおり書き込み群 5 試行を最初からやり直してよい」）とリーダーの合図を受けて開始。手動操作なし、立ち会いなし、途中の応答なし。
実行: `calib-loop.ps1 -Mode write -Dwells 13,26,17,21,13 -NoNewTrialAfter "2026-10-08 22:54" -RestoreReserveMin 10`（基準像 bt4 md5 df108d7a…、最適化像 bt4A md5 e1e62efe…、本番像 2725423 md5 889f3a48…）。
リーダーの指示（長時間待機の必要性を見直すため、安全に打ち切る。稼働待ちなら待機を切り上げ、次の命令や書き込みに進まず本番復帰へ。スクリプトは書き換えない）で、試行 2 の稼働中に打ち切った。
このディレクトリは実行のログディレクトリの全ファイル（`summary.log`、`steppre-*.log`、`flash-base-*.log`、`trialN-write-*.log`、交換ごとの `*-ioN.out/.err`、`result-*.json`、`ledger.json`/`ledger.csv`、`flash-prod-*.log`、子の `child-*.out/.err`、`console.txt`）。CR を外した以外は原文。

## 打ち切りの方法
スクリプトは変えず、既存の停止経路を使った: 試行 2 の子プロセス（`calib-trial.ps1`、PID 61952。稼働中で、コンソールの孫プロセスは無し）を 21:13:56 に Windows 側で `Stop-Process` で終了させた。ループは試行 2 を「失敗（rc=-1）」と記録し、試行 3〜5 を not-run にして、必ず走る本番復帰（`flash-prod`）へ進んだ。
試行 2 のログは稼働開始（20:49:50、`dwell start: 26 min`）で終わっていて、`sent` の刻印も `DEVICE-OP` の刻印も無い。命令の送信も書き込みも始まっていない段階で止めた。

## 各段階の実績と事故記録
| 段階 | 時刻 | 結果 | 実測 |
|---|---|---|---|
| 事前確認 | 20:34:57〜20:35:03 | PASS | 3 像の存在と md5 一致。本番像 2725423 から完全な dump |
| 基準像の書き込み | 20:35:03〜20:35:33 | PASS | `b` 受理、E: 1 台（シリアル一致）、bt4 を複写、消失、app。dump: `cur seq=12 tag=bt4-R-10080217 done=1 reinit=0`、`ring count=0 dropped=0 invalid=0 reinit=0`（校正と 1 回目のループから番号が続いている。記録領域は本番像の稼働を挟んでも保持） |
| 基準（試行 0） | 20:35:33〜20:35:39 | PASS | seq=12、count=0、dropped=0、invalid=0、reinit=0、done=1。事故記録なし |
| 試行 1（稼働 13 分、bt4 → bt4A） | 20:35:39〜20:49:44 | 正常完了 | 稼働終了の dump: up_ms 16962 → 818824（進み 801862 ms、許容 [778000, 900000]）、操作直前の稼働 13.65 分、同じ起動で seq/count/dropped/invalid/reinit 不変。`b` 送信（20:49:10.194）、応答行 `ZDIAG bootloader` あり（`seen=True, port lost after the send=False`）、関門「30 秒以内にこのシリアルのブートローダー」PASS、E: 1 台、bt4A を複写（20:49:38）、消失、app。起動後（読み取り 1 回目）: seq=13、tag=bt4A-R-10080217、done=1、reinit=0、count=0、dropped=0、invalid=0、up_ms=5298 |
| 試行 2（稼働 26 分、bt4A → bt4 予定） | 20:49:44〜21:13:56 | 打ち切り（rc=-1。事故ではない） | 稼働開始 20:49:50、USB は app。24 分の稼働中にリーダーの指示で子を終了。命令の送信なし、書き込みなし、稼働終了の dump なし（打ち切ったので起動番号の照合も無し） |
| 試行 3（17 分）、4（21 分）、5（13 分） | — | 未実施 | 試行 2 の打ち切りで停止 |

起動停止の実績: 対象となる書き込み後の起動 1 回（試行 1）、事故記録 0 件。試行開始 2、`b` 送信 1 は別の段階の分母。観測した 2 回の起動（seq 12、13。基準像の書き込み後の 1 回と試行 1 の書き込み後の 1 回）はどちらも done=1、reinit=0、count/dropped/invalid は 0 → 0。1 回で 0 件でも原因候補の否定にはならない。
台帳（`summary.log` 21:14:27.761）: `trials started=1, b sent=1, images written=1 (boots after a write), boots observed=1, RUNNING confirmed=1, completed without event=1, stages unknown=1 (no usable result file; only log stamps counted for those), not sent (child refused)=0, send not attempted=0, op sent unknown=1; stop=trial 2 failed (rc=-1)`。試行 2 は結果ファイルが無い（打ち切り）ので台帳は段階を unknown にし、`trials started` に数えていない。ログの刻印では稼働は始まっていて、送信と複写は無い。
終了: `LOOP FAILED | RESTORE PASS`、`results: pre=0 flash-base=0 baseline=0 t1=0 t2=-1 t3=not-run t4=not-run t5=not-run restore=0 stop=trial_2_failed_(rc=-1)`。

## 本番復帰
21:13:57〜21:14:27、PASS。本番像の md5 一致、初期状態 app（bt4A が動作中）、`b` でブートローダー、E: 1 台（シリアル一致）、複写（21:14:22）、消失、app（21:14:24）。dump: `ZDIAG begin version=prof1 up_ms=3895 boot=1 reset=0x2`、`ZDIAG end`、`#TRUNC` なし、`ZBOOT` 行 0 本（本番像）。右手側は本番像 2725423 で app として動作中。

## 未検証事項
- 書き込み群は 5 試行のうち 1 試行だけ完了（書き込み後の起動 1 回）。残り（稼働 26、17、21、13 分）は未実施。1 回目（`loop-real-20261008/`）の 2 回と合わせても、分母は実行ごとに分ける。
- リセット群（`-Mode reset`）は未実施。
- ピンリセットを挟んだ保持、USB を抜いた起動、本番像での再現、自動復帰で救えない停止は観測していない。
- 修正版 61823c9 の「応答行が届かないときの関門」は、この実行では試されていない（試行 1 は応答行が届いた）。模擬（`calib-sim20-20261008/`）でだけ確かめてある。
