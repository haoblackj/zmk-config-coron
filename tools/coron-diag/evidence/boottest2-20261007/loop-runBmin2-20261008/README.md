# 実行 B-min 再実行: 再現の最小増分（書き込み群、稼働 18 分 × 1 試行。2026-10-08 21:59:53〜22:20:03、右手側 B17318CDBE9A61B1、スクリプト 4df2da5）
B-min の初回（`loop-runBmin-20261008/`、基準像の書き込みで `Join-Path` の欠陥により FAIL）への修正 4df2da5 を受けて、リーダーの指示で再実行。Windows 側の写し 9 本の md5 が 4df2da5 と一致することを確認してから起動。手動操作なし、立ち会いなし、稼働中に実機に触れていない。
実行: `calib-loop.ps1 -Mode write -Dwells 18 -NoNewTrialAfter "2026-10-08 22:49" -RestoreReserveMin 10`（像は従来と同じ md5）。このディレクトリは実行のログディレクトリの全ファイル（CR を外した以外は原文）。

## 各段階の実績と事故記録
| 段階 | 時刻 | 結果 | 実測 |
|---|---|---|---|
| 事前確認 | 21:59:54〜22:00:00 | PASS | 3 像の md5 一致、本番像から完全な dump |
| 基準像の書き込み | 22:00:00〜22:00:32 | PASS | `b` 送信 22:00:04.464、応答行あり、ブートローダー、E: 1 台、bt4 を複写 22:00:26.951、**修正した消失確認が 326 ms 後に PASS**（エラーなし）、app 復帰 22:00:28、最初の起動 done=1。dump: `cur seq=18 tag=bt4 done=1 reinit=0`、ring count=0 |
| 基準（試行 0） | 22:00:32〜22:00:38 | PASS | seq=18、count=0、dropped=0、invalid=0、reinit=0、done=1。事故記録なし |
| 試行 1（稼働 18 分、bt4 → bt4A） | 22:00:38〜22:19:29 | 正常完了 | 稼働中の USB 読み取りはすべて app（最初の読み取り 22:00:44、app 以外の状態なし）。稼働終了の dump: up_ms 16796 → 1109782（進み 1092986 ms、許容 [1078000, 1200000]）、操作直前の稼働 18.5 分、同じ起動で seq/count/dropped/invalid/reinit 不変。`b` 送信 22:19:00.313、応答行あり（`seen=True, port lost after the send=False`）、関門「30 秒以内にこのシリアルのブートローダー」PASS（22:19:03）、E: 1 台、bt4A を複写 22:19:23.444、消失確認 PASS（6 ms 後）、app。起動後（読み取り 1 回目）: seq=19、tag=bt4A-R-10080217、done=1、reinit=0、count=0、dropped=0、invalid=0、up_ms=5106 |

台帳（22:20:03.803）: `trials started=1, b sent=1, images written=1 (boots after a write), boots observed=1, RUNNING confirmed=1, completed without event=1, not sent (child refused)=0, send not attempted=0; stop=all-trials-done`。
終了: `LOOP DONE (no event) | RESTORE PASS`、`results: pre=0 flash-base=0 baseline=0 t1=0 restore=0 stop=all-trials-done`、終了コード 0。所要 20 分 10 秒。
事故記録: 0 件（18 分帯の書き込み後の起動 1 回。seq 18、19 はどちらも done=1、reinit=0、count/dropped/invalid は 0 → 0）。1 回 0 件でも原因候補の否定にはならない。

## 本番復帰
22:19:29〜22:20:03、PASS。初期状態 app（bt4A）、`b`（22:19:33.957、応答行あり）、ブートローダー、E: 1 台、本番像の md5 一致、複写 22:19:56.424、消失確認 PASS（197 ms 後）、app 22:19:58、`ZDIAG begin version=prof1 up_ms=5494`、`ZBOOT` 行 0 本。右手側は本番像 2725423 で app として動作中。

## 稼働帯ごとの観測（実行をまたぐ併記。各実行の台帳と分母はそのまま）
| 稼働帯 | 観測 | 出どころ | 事故記録 |
|---|---|---|---|
| 13 分帯 | 2 回（13.39 分、13.65 分、いずれも bt4 → bt4A） | `loop-real-20261008/` 試行 1（9191082）、`loop-real2-20261008/` 試行 1（61823c9） | 0 件 |
| 18 分帯 | 1 回（18.5 分、bt4 → bt4A） | この実行の試行 1（4df2da5） | 0 件 |
| 26 分帯 | 1 回（26.34 分、bt4A → bt4） | `loop-real-20261008/` 試行 2（9191082） | 0 件 |
動作確認 A（稼働 1 分 × 2、`loop-runA-20261008/`）は含めない。像の md5、操作列、観測条件は 4 回とも同じで、スクリプト版の差（9191082 → 61823c9 → 4df2da5）はホスト側の関門、子の読み取り間合い、消失確認のパスの組み方だけ。

## 未検証事項
- 修正した消失確認は、この実行の 3 回の書き込み（基準像、bt4A、本番像）で 6〜326 ms 後に PASS した。ドライブ文字が消えた後に最初の確認が走る順序（初回 B-min の形）は、この実行では起きていない（自己試験の `subst` でだけ再現）。
- 応答行が届かないときの関門は実機では未検証（3 回とも応答行が届き、ポート消失の刻印もなし）。
- 21 分帯は未観測。リセット群、ピンリセットを挟んだ保持、USB を抜いた起動、本番像での再現、自動復帰で救えない停止は未実施か未観測。
