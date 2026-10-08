# 実行 A: 動作確認（書き込み群、稼働 1 分 × 2 試行。2026-10-08 21:30:21〜21:35:11、右手側 B17318CDBE9A61B1、スクリプト 61823c9）
待機の棚卸し（issue の 21:31 の状態コメント）で採用された「動作確認と再現を分ける」案の A。目的は 61823c9 の操作経路、書き込み後の起動、実績の記録、本番復帰の確認。稼働 1 分は既知の稼働帯（13〜26 分）の再現ではないので、再現の実績には含めない。手動操作なし、立ち会いなし。
実行: `calib-loop.ps1 -Mode write -Dwells 1,1 -NoNewTrialAfter "2026-10-08 22:30" -RestoreReserveMin 10`（像は 1 回目、2 回目と同じ md5）。このディレクトリは実行のログディレクトリの全ファイル（CR を外した以外は原文）。

## 各段階の実績と事故記録
| 段階 | 時刻 | 結果 | 実測 |
|---|---|---|---|
| 事前確認 | 21:30:22〜21:30:27 | PASS | 3 像の md5 一致、本番像から完全な dump |
| 基準像の書き込み | 21:30:27〜21:31:00 | PASS | `b`、応答行あり、ブートローダー、E: 1 台、bt4 を複写、消失、app。dump: `cur seq=14 tag=bt4 done=1 reinit=0`、ring count=0 |
| 基準（試行 0） | 21:31:00〜21:31:05 | PASS | seq=14、count=0、dropped=0、invalid=0、reinit=0。事故記録なし |
| 試行 1（稼働 1 分、bt4 → bt4A） | 21:31:05〜21:32:55 | 正常完了 | up_ms 17803 → 86809（進み 69006 ms、許容 [58000, 180000]）、操作直前の稼働 1.45 分、同じ起動で不変。`b` 送信 21:32:25.281、応答行あり（`seen=True, port lost after the send=False`）、関門 PASS、bt4A を複写 21:32:49、消失、app。起動後: seq=15、tag=bt4A、done=1、reinit=0、count=0、dropped=0、invalid=0、up_ms=5097 |
| 試行 2（稼働 1 分、bt4A → bt4） | 21:32:55〜21:34:39 | 正常完了 | up_ms 10878 → 77281（進み 66403 ms）、稼働 1.29 分。`b` 送信 21:34:10.679、応答行あり、関門 PASS、bt4 を複写 21:34:33、消失、app。起動後: seq=16、tag=bt4、done=1、reinit=0、count=0、dropped=0、invalid=0、up_ms=5035 |

台帳（21:35:11.456）: `trials started=2, b sent=2, images written=2 (boots after a write), boots observed=2, RUNNING confirmed=2, completed without event=2, not sent (child refused)=0, send not attempted=0; stop=all-trials-done`。
終了: `LOOP DONE (no event) | RESTORE PASS`、`results: pre=0 flash-base=0 baseline=0 t1=0 t2=0 restore=0 stop=all-trials-done`、終了コード 0。所要 4 分 50 秒。
事故記録: 0 件（書き込み後の起動 2 回。seq 14、15、16 はすべて done=1、reinit=0、count/dropped/invalid は 0 → 0）。短時間稼働なので、既知の稼働帯を再現した実績には数えない。

## 本番復帰
21:34:39〜21:35:11、PASS。初期状態 app（bt4）、`b`、ブートローダー、E: 1 台、本番像の md5 一致、複写、消失、app、`ZDIAG begin version=prof1 up_ms=3895`、`ZBOOT` 行 0 本。

## 確認できたこと、できなかったこと
- 61823c9 の操作経路（`Ack-Evidence` の記録、USB 状態の関門、複写、起動の観測、台帳、本番復帰）は実機で 2 往復とも通った。
- 応答行が届かないときの関門は、この実行では試されていない（4 回の `b` すべてで応答行が届いた）。直後の B-min では、基準像の書き込みと復帰の `b` で「応答行あり、送信後にポート消失」が初めて観測された（`loop-runBmin-20261008/`）。
