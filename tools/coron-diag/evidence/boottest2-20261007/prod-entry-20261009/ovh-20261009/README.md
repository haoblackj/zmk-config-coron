# 検査あり（`CONFIG_BT_CTLR_ASSERT_OVERHEAD_START=y`）の試験像での交互書きループ（2026-10-09 08:36〜11:02）

## 仮説と設計
現場の停止 4 件（10/04 20:35、10/05 09:26、10/05 19:47、10/07 16:16）はすべて `CONFIG_BT_CTLR_ASSERT_OVERHEAD_START=y`（Zephyr の既定）の像で起きた。
10/07 16:28 に本番の conf を `=n` にしてから、ラボの起動（10/08〜10/09 の夜通し 252 回を含む）はすべて `=n` で、停止 0。
そこで「検査が `=y` だと、起動直後に無線のイベントの準備が遅れたときに `LL_ASSERT_OVERHEAD` で致命的エラーになる」を仮説にし、本番候補 A（`coron_R-prod-entry.uf2`）に `=y` だけ足した試験像を作って、像 B（検査なし、速度最適化）と交互に書いた。
検査以外の差は無いので、致命的エラーが試験像でだけ出れば、検査が止める側だと分かる。

像（Windows の staging `C:\Users\yagu001\AppData\Local\Temp\coron-flash\`）:

| 名 | ファイル | md5 | 検査 | ビルド |
| --- | --- | --- | --- | --- |
| 試験像 A（右） | `coron_R-prod-entry-ovh.uf2` | `fd65d78cc2e30cc4b4a3e4ab4228102a` | あり | `.build/R-entry-ovh`（`build-prod-entry-ovh.sh`、`prod-entry-ovh.conf`） |
| 像 B（右） | `coron_R-prod-entry-alt.uf2` | `0a61c3e26c3f4597dc459a1c1ad8cded` | なし | `.build/R-entryB` |
| 本番候補 A（右、復帰先） | `coron_R-prod-entry.uf2` | `fedd88a480bdfba476aba4e5cddd2617` | なし | `.build/R-entry` |
| 試験像（左） | `coron_L-prod-entry-ovh.uf2` | `ed1f5756989e01e8835d796878e43459` | あり | `.build/L-entry-ovh`（`build-left.sh`、`left-console.conf`） |
| 本番候補（左、復帰先） | `coron_L-prod-entry.uf2` | `54a8d13268a10c936a0c1b6906863e5b` | なし | `.build/L-entry` |

## 経過
- 08:36 右のループ開始（`prod-loop.ps1 -First A`、100 周）。5 周 PASS。
- 08:44 6 周目: `b` を送ったあと、リーダーがブートローダーに入れて USB につないだ左が「ブートローダーは 1 台だけ」の検査に当たり STOP。右はブートローダーのまま。
- 08:49 左に左用の試験像を書いた（`left/write-0849`。`-AllowOtherBootloaders`）。左は押さずに起動、印は連番 1 で稼働の段。
- 08:50 右のループ再開（`prodloop-1009-ovh2`）。1 周目: 右がブートローダーから書き始めたので記録ファイルが io1 だけになり、スクリプトが印を読めず STOP（実機は正常）。
- 08:51 直して再開（`prodloop-1009-ovh3`、94 周）。80 周 PASS。
- 10:54 81 周目（試験像 A を書く）で STOP: 書き込み PASS、起動は稼働の段、ただし印の連番が 339 → 341 と 2 進んだ。
- 10:57 右の watchdog の記録を Studio RPC で読んだ（`wdlog/`）。致命的エラーが 1 件増えていた。
- 10:59 左の印を読んだ（`left/read-1059`）: 連番 1 のまま、稼働の段、`host_conn=83 host_disc=82`（右の 81 回の再起動を周辺側として受けた）。左は一度も落ちていない。
- 11:01 右を本番候補 A、左を左版の本番候補に戻した（`restore/`）。左右とも PASS、印は連番 +1 で稼働の段。左右の組み合わせ試験（`pair-loop.ps1`）は、右のループが正常に終わらなかったので始めていない。

## 集計（`boots.tsv`）

| 像 | 起動（印が正常） | 致命的エラー |
| --- | --- | --- |
| 試験像 A（検査あり） | 44 | 1（45 回目） |
| 像 B（検査なし） | 42 | 0 |

ほかに 10/07 の T1（検査あり diag-min3、30 回、停止 0）と、10/08〜09 の夜通し（検査なし、252 回、停止 0）がある。

## 81 周目の時系列（`prodloop-1009-ovh3/iter-081/`）
- 10:54:21 `b` の前の dump: 像 B が稼働中、`seq=339 st=10`、`host_conn=1 split_conn=1`。
- 10:54:21 `b` → 10:54:24 ブートローダー → 10:54:43 試験像 A を書いた → 10:54:45 本体が app として USB に戻った（ここまで他の周と同じ）。
- 10:54:47 コンソールを開こうとして「COM5 は存在しません」（他の周ではこの時点で開けている）。
- 10:54:49 開けた。dump: `up_ms=3027`（起動は 10:54:48 ごろ）、`host_conn=0 split_conn=0`、印 `pv=1 pseq=340 pst=10 prst=0x4 pint=0x380 piser1=0x80 seq=341 st=10`。

印の `p` 付きの項目は前回の起動の値（`diag_entry.c` のコメント）。
つまり起動 340（試験像 A の 1 回目、DFU 直後の残留 `0x380` あり）は稼働の段まで進んだあと再起動し、起動 341 が正常に上がった。
11:01 の復帰の起動（342）の印は `pseq=341 prst=0x4 pint=0x0 piser1=0x0` で、起動 341 はソフトリセット経由（USB の残留なし）で入っている。watchdog モジュールの `sys_reboot` の経路と一致する。

## watchdog の記録（`wdlog/list.txt`、`pb-decode.py` で読む）
`cormoran__watchdog` の store に 2 件（`status`: capacity 16、stored 2）。

| id | type | boot_ordinal | uptime_s | reason | pc | lr | thread |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1（以前から） | FATAL | 1 | 489 | 3 | 0x2b3c2 | 0x2b3b3 | `?` |
| 2（今回） | FATAL | 2 | 3 | 3 | 0x2b3c2 | 0x2b3b3 | `?` |

reason 3 は Zephyr の `K_ERR_KERNEL_OOPS`（`k_oops()`）。`LL_ASSERT` は `CONFIG_BT_ASSERT=y` のとき `BT_ASSERT` → `k_oops()` に落ちる。thread `?` は ISR の中（LLL は無線の割り込みで動く）。
id 2 の uptime 3 秒は、起動 340 が 10:54:44〜48 の 3〜4 秒で終わったことと合う。

番地を各ビルドの ELF で引いた（`arm-zephyr-eabi-addr2line -f -i`）:

| ビルド | 0x2b3c2 | 0x2b3b2 |
| --- | --- | --- |
| `R-entry-ovh`（試験像 A） | `prepare_cb` `lll_central.c:252`（`LL_ASSERT_OVERHEAD(overhead)` の行） | `prepare_cb` `lll_central.c:250`（`if (overhead)`） |
| `R-entry`（本番候補 A） | `_powf`（libm） | 同 |
| `R-entryB`（像 B） | `__rem_pio2`（libm） | 同 |

試験像では、致命的エラーの pc は `lll_central.c` の `prepare_cb` にある `LL_ASSERT_OVERHEAD` そのもの。
中央側（右）の接続イベントの準備が、`lll_preempt_calc` の見積もりより遅れたときに通る分岐で、`=y` では `LL_ASSERT_MSG(false, …)` → `k_oops()`、`=n` では `ARG_UNUSED` になって `radio_disable()` と `-ECANCELED` でそのイベントを飛ばす（`hal/debug.h`、Kconfig の help「Disabling this option permits the Controller to gracefully skip radio events that are delayed due to CPU usage latencies」）。
id 1（10/07 16:16 の現場の停止と同じ日に記録。当時の像 2725423 の ELF は手元に無い）も同じ pc と lr で、同じ場所の致命的エラーと見てよい。

## 言えること、言えないこと
- 言えること: 本番候補 A に検査（`=y`）だけ足した像で、DFU 直後の起動の 3 秒目に `lll_central.c:252` の `LL_ASSERT_OVERHEAD` で `k_oops` が起きた（45 回に 1 回）。検査なしの同じ構成では 42 回 + 夜通し 252 回で 0。現場の停止 4 件はすべて `=y` の像で、10/07 の記録と今回の記録は同じ pc。致命的エラーのあとは watchdog モジュールが再起動し、次の起動は正常だった（左は落ちていない）。
- 言えないこと: 準備が遅れる原因（何が CPU を占めて LLL の準備を遅らせたか）。起動 3 秒は host の接続と split の接続と Windows の USB 列挙が重なる時間帯で、現場の「更新直後」と同じ状況だが、計測はしていない。現場では再起動後に復帰せず（10/07 は 6 分間に列挙の失敗が 3 回続き、リセットまで現れなかった）、今回のラボでは 1 回の再起動で復帰した。この差の理由は今回の記録からは分からない。

## ファイル
- `boots.tsv`: 3 つのループの全周（run iter image seq pseq pst st prst pint piser1 elapsed_s crumb_ok）。
- `prodloop-1009-ovh/`、`prodloop-1009-ovh2/`、`prodloop-1009-ovh3/`: `summary.log` と、最初の周、止まった周（ovh3 は 80 周目も）の子プロセスの記録。`loop-stdout.txt` は ovh3 の標準出力。
- `left/write-0849/`: 左への試験像の書き込み。`left/read-1059/`: ループ後の左の印の読み出し（`half-io.ps1`）。
- `restore/R/`、`restore/L/`: 検査なしの像への復帰。
- `wdlog/status.txt`、`wdlog/list.txt`: Studio RPC の生の往復（読み方は `../wdlog/studio-rpc.sh` と `../wdlog/pb-decode.py`）。
- `build-prod-entry-ovh.sh`、`build-left.sh`: 像のビルド手順。
