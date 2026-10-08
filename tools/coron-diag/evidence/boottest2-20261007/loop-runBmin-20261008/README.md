# 実行 B-min: 再現の最小増分（書き込み群、稼働 18 分 × 1 試行の予定。2026-10-08 21:35:34〜21:36:35、右手側 B17318CDBE9A61B1、スクリプト 61823c9）
A の正常完了を受けて、既存の書き込み後の起動 3 回（13.39、26.34、13.65 分。像の md5、操作列、観測条件が同一で、9191082 と 61823c9 の差はホスト側の関門と子の読み取り間合いだけ）と比較可能と判断し、未観測の 18 分帯に 1 試行を足す実行。手動操作なし、立ち会いなし。
実行: `calib-loop.ps1 -Mode write -Dwells 18 -NoNewTrialAfter "2026-10-08 22:25" -RestoreReserveMin 10`。このディレクトリは実行のログディレクトリの全ファイル（CR を外した以外は原文）。

## 結果: 基準像の書き込みでスクリプトの欠陥により FAIL、試行なし、本番復帰もスクリプトの判定は FAIL（実機は本番像で動作中）
| 段階 | 時刻 | 結果 | 実測 |
|---|---|---|---|
| 事前確認 | 21:35:34〜21:35:39 | PASS | 3 像の md5 一致、本番像から完全な dump |
| 基準像の書き込み | 21:35:39〜21:36:08 | FAIL（スクリプトの欠陥） | `b` 送信 21:35:44.196、応答行あり、送信後にポート消失（`seen=True, port lost after the send=True`。この組み合わせの初観測）、ブートローダー 21:35:45.6、E: 1 台、md5 一致、bt4 を複写 21:36:07.930（エラーなし）。直後の「UF2 ドライブ消失」の確認で `Join-Path` が DriveNotFound（`名前 'E' のドライブが存在しません`、`child-flash-base.err`）を出して null を返し、`Test-Path` の引数束縛エラー（`calib-lib.ps1:261`）で `ERROR` → `FLASH base RESULT FAIL` |
| 試行 1（18 分） | — | 未実施 | 基準像の書き込みの FAIL で `stop=flash-base-failed` |
| 本番復帰 | 21:36:08〜21:36:35 | FAIL（同じ欠陥） | 初期状態 app（bt4。復帰の交換の dump: `cur seq=17 tag=bt4 done=1 reinit=0`、ring count=0。基準像の書き込み後の起動は RUNNING に到達していた）、`b` 送信 21:36:13.896、応答行あり、送信後にポート消失、ブートローダー、E: 1 台、md5 一致、本番像を複写 21:36:35.027（エラーなし）、同じ `Join-Path` のエラーで `FLASH prod RESULT FAIL`。app への復帰と dump の確認には進んでいない |

終了: `LOOP FAILED | RESTORE FAIL`、`results: pre=0 flash-base=1 t1=not-run restore=1 stop=flash-base-failed`、終了コード 3。台帳: `trials started=0, b sent=0, images written=0`（試行なし）。
実機の状態（スクリプトの外から、読み取りだけで確認。21:37:23 と 21:38:13）: USB に app として存在（`USB\VID_1D50&PID_615E\B17318CDBE9A61B1`）、ブートローダーも UF2 ドライブも無し。送信なしのコンソール読み（`calib-io.ps1 -Com COM5 -ReadSeconds 0`）で `ZDIAG begin version=prof1 up_ms=99520 boot=1 reset=0x2`、`ZDIAG end`、`ZBOOT` 行なし。本番像 2725423 が、復帰の複写（21:36:35）直後の起動から動いている。右手側はこの状態のまま。
事故記録: 試行は無い。基準像の書き込み後の起動（seq 17）は done=1、count=0 で、事故記録なし（復帰の交換の dump から）。

## 欠陥と修正（レビュー待ち。この版は実機では動かしていない）
`Wait-Uf2Gone`（と `Get-Uf2DrivesOfSerial`、`Get-AllUf2Drives`、`Copy-Uf2` の宛先）が `Join-Path ($letter + ':\') …` でパスを組んでいた。Windows PowerShell 5.1 の `Join-Path` はドライブ修飾子をセッションのドライブ表と照合し、セッションが一度見たドライブ（`Get-AllUf2Drives` の `Get-PSDrive` で登録される）が消えた後は DriveNotFound の非終了エラーを出して何も返す（`$ErrorActionPreference = 'Continue'`）。null を受けた `Test-Path` が引数束縛で終了エラーになり、スクリプトの `catch` が `ERROR` として FAIL にする。UF2 書き込み直後はまさにドライブが消える瞬間で、今日の先の 7 回（校正 1 回、ループ 3 回の基準像と復帰）は最初の確認がドライブの消える前に走って「印なし」で PASS になっていただけ。
再現（実機なし）: `subst` で一時ドライブを作り、`Get-PSDrive` で登録させてから `subst /D` で消すと、同じ DriveNotFound と null 束縛が出る。一度も見ていないドライブ文字では出ない（最初の再現の試みが失敗した理由）。
修正: `Test-Uf2Marker $letter`（`Test-Path -LiteralPath ($letter + ':\INFO_UF2.TXT')` を `try/catch` で包み、どんなエラーも「印なし」）に置き換え、`Copy-Uf2` の宛先も文字列連結にした。`calib-selftest.ps1` に `subst` による再現 7 件（未登録の文字、登録済みで印あり、消した後に `Join-Path` が何も返さない、`Test-Uf2Marker` が例外を出さず偽）を足した（22 件 PASS）。模擬 83 場面は `calib-sim21-20261008/`。

## 未検証事項
- 18 分帯の試行は未実施。13 分帯 2 回と 26 分帯 1 回の既存結果はそのまま。
- 修正版の `Wait-Uf2Gone` は実機の UF2 書き込みでは未確認（自己試験の `subst` と模擬だけ）。
- リセット群は未実施。応答行が届かないときの関門は実機では未検証（今回は応答行が届いた上でポートが消えた）。
