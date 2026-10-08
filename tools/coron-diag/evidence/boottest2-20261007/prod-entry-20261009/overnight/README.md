# 本番像どうしの交互書きループ（2026-10-09 01:43〜08:04、右手側 B17318CDBE9A61B1）
リーダーの決定（issue zmk-workspace#1、01:41 の状態コメント「1はいいよ」）で、整え処理と印入りの本番像を 2 種類にして交互に書き、書き込み直後の起動（ブートローダーの DFU 出口からの起動）を一晩で積んだ。立ち会いなし、ボタン操作なし。

- 像 A: `coron_R-prod-entry.uf2`（md5 `fedd88a480bdfba476aba4e5cddd2617`、`6386a6d`、01:18 に投入した本番候補そのもの）。
- 像 B: `coron_R-prod-entry-alt.uf2`（md5 `0a61c3e26c3f4597dc459a1c1ad8cded`、同じソースと同じ Kconfig に `CONFIG_SPEED_OPTIMIZATIONS=y` を足したもの。`../../../prod-entry-alt.conf`）。ブートローダーは中身が同じページを書き飛ばすので、毎回が本当の書き込みになるように全ページが違う像を相手にした。
- ループ: `tools/coron-diag/calib/prod-loop.ps1`。1 周は `calib-flash.ps1 -Expect prod`（コンソールの `b`、UF2 複写、ドライブ消失、90 秒以内の app 復帰、dump 完了、version=prof1、ZBOOT 無し）に加えて、dump の `ZDIAG crumb` が「前回の印が有効で稼働の段（pv=1 pst=10）、今回も稼働の段（st=10）、連番が 1 進む」を満たすことを要求し、60 秒置いて次の像を書く。検査が 1 つでも落ちたらその場で止まり、実機には触らない。

## 結果
| 走行 | 時刻 | 周回 | 印の連番 | 停止 | 1 周の所要（書き込み〜復帰〜dump） |
|---|---|---|---|---|---|
| loop-0144 | 01:43〜01:44 | 1 | 2 | 検査は全部通過。`$p.ExitCode` が空で rc 無しのまま STOP（スクリプトの不具合、下記） | 31 s |
| loop-0148 | 01:44〜02:30 | 31 | 3〜33 | 検査は全部通過。32 周目の記録の書き出しで `Add-Content` が例外（WSL 側の見張りの読み取りと重なった）を出してループが落ちた。実機の操作は無し | 28〜32 s |
| loop-0235 | 02:32〜08:04 | 220 | 34〜253 | 無し。220 周すべて通過して正常終了 | 29〜33 s |

合計 252 回の DFU 出口からの起動（像 A 126 回、像 B 126 回）がすべて稼働の段（st=10）に達し、前回の印（pst）も 252 回すべて 10。停止 0 回。`boots.tsv` に 1 行 1 起動で載せた（`run iter image seq pst st prst pint piser1 elapsed_s crumb_ok`）。

印に残った「入口の状態」は 252 回とも同じ: `prst=0x4`（RESETREAS の SREQ。ブートローダーが DFU の終わりにソフトリセットした）、`pint=0x380`（POWER の INTEN に USBDETECTED/USBREMOVED/USBPWRRDY の 3 ビットが残っている）、`piser1=0x80`（NVIC ISER1 のビット 7 = USBD の割り込みが有効のまま）。T2 で見た DFU 経路の残留と一致し、整え処理が毎回この残留を受け取って消している。

## 言えること、言えないこと
- 言えること: 整え処理入りの本番像は、DFU 出口からの起動を 252 回（T1、T2 と合わせて 300 回以上）繰り返しても止まらない。書き込みの道具（`calib-flash.ps1` と `prod-loop.ps1`）は一晩無人で回る。
- 言えないこと: 現場の停止の原因。ラボの条件（USB 給電で PC につながったまま、左手側は接続済み、キー操作なし）では整え処理の前も後も再現しておらず、「整え処理が止まらなくした」とは言えない。現場の停止は使用中の条件（キー操作、BLE の接続状態の変化、電池駆動など）が絡む可能性が残る。

## スクリプトの不具合と直し（ループ本体のみ。実機の挙動とは無関係）
- PowerShell 5.1 の `Start-Process -PassThru` は、終了前に `$p.Handle` に触らないと `ExitCode` が空になる。空を失敗として止めていたので 1 周で止まった（loop-0144）。`$null = $p.Handle` を足し、空は -1（失敗）として扱う。
- `Add-Content` は、WSL 側の見張り（`prod-loop-watch.sh`）が drvfs 越しに同じファイルを読んでいる瞬間に例外を出す（loop-0148 の 02:30）。記録の書き出しは 200 ms 置いて 10 回まで再試行し、見張りは 60 秒に 1 回しか読まない。
- `-First A|B` を足し、いま載っている像と違う方から書き始められるようにした。

## 置いたもの
- `loop-*/summary.log`: ループの記録（1 周ごとの書き込み開始、結果、待ち）。`loop-*/loop-stdout.txt`: 同じ内容の標準出力（loop-0148 は末尾に `Add-Content` の例外）。
- `loop-*/iter-NNN/`: 各走行の最初と最後の周（loop-0148 は 1 と 31、loop-0235 は 1 と 220）の `calib-flash.ps1` の記録一式（`child.out`、`flash-prod-*.log`、コンソールの入出力）。ほかの周は PC の `%TEMP%\coron-flash\prodloop-1009-*\` にある。
- `boots.tsv`: 252 起動の表。`prod-loop-watch.sh`: WSL 側の見張り。
- 終了時の実機は像 A（220 周目が A の書き込み。`loop-0235/iter-220/flash-prod-1009-080314.log` の md5 検査）。書き戻しは不要。
