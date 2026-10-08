# レビュー #6（2026-10-08、校正実装の 5 点）への対応（2026-10-08 01:47）

各指摘を、公開したソースと最終 `.config` と依存のソースで確かめた結果と、直した場所。ソースの差分は `haoblackj/zmk-config-coron` の `feat/dya-diagnostics` で、c85ace3 と この文書を含むコミットの比較（issue のコメントにリンク）。

## 1. 既存の 10 秒の freeze 検出が、15 秒の仕掛けより先に再起動する
確認: そのとおり。`.config` に `CONFIG_ZMK_WATCHDOG_FREEZE_DETECT=y`、`FREEZE_TIMEOUT_MS=10000`、`FREEZE_FEED_DIVISOR=2`、`FREEZE_MONITOR_LOWPRIO_QUEUE=y`。`zmk-feature-watchdog/src/watchdog_freeze.c`（84ad14c6）は system と lowprio（`CONFIG_ZMK_LOW_PRIORITY_THREAD_PRIORITY=10`）の 2 キューにそれぞれ `k_work_delayable` で 5 秒ごとに `task_wdt_feed` し、期限切れの callback（タイマー ISR 文脈）で記録して `zmk_watchdog_reboot()` → `sys_reboot`。初期化は `SYS_INIT(..., APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY)`（90）、`STARTUP_DELAY_MS=0`。
- `h`: system キューが止まる → 最後の給餌から 10 秒で再起動。仕掛けは最後の給餌から 15 秒なので負ける。
- `G`: 優先度 0 の preemptible が feeder（10）と lowprio キュー（10）を飢えさせる → 同じく 10 秒で再起動。
- そのとき `cur` は done=1、reason=0、calib=h/G で、`is_incident()` は保存しない（レビューの指摘どおり）。
対応: 試験像の `boottest*.conf` に `CONFIG_ZMK_WATCHDOG_FREEZE_DETECT=n`。時間で発火してリセットする監視が TIMER4 の仕掛けだけになる。fatal 検出は残す（フォルトにだけ反応する。切ると設定リポジトリの `src/fatal_reboot.c`（10c183c、10/05）が同じ関数を定義して記録なしで再起動する側に入り、最初の試みはこの 2 つの定義の衝突でリンクに失敗した）。`S` は APPLICATION 50 で止まるので、90 の freeze 検出の初期化前。h/G とは別に扱う（README の表）。
自然発生の試験の条件として記録: 試験像は「freeze 検出なし、fatal は watchdog の記録つき再起動」。停止 3 件の像は watchdog モジュール（162637f、10/07）より前なので freeze 検出は無く、fatal の扱いは bbc509c が Zephyr 既定の halt、8d7cc27 が `fatal_reboot.c` の記録なし再起動、diag-min3 は不明。

## 2. `H` を実行すると、次のコマンドを受け付けられない
確認: そのとおり。`diag_min.c` のコンソールスレッドは `K_LOWEST_APPLICATION_THREAD_PRIO`（`CONFIG_NUM_PREEMPT_PRIORITIES=15` なので 14）。`H` の優先度 12 の無限ループは 14 を永久に止める（feeder の 10 は動く）。
対応: `H` は `H_SPIN_S`（30 秒）回って終了する（`diag_spin_bounded`）。コンソールは `ZDIAG calibrate H` を出してから約 30 秒黙り、スピナーの終了後に `ZDIAG calibrate H rc=0` を出す。校正の第 4 段をこの観測に合わせた。

## 3. `H` と `G` が生きている同じスレッドオブジェクトとスタックを再利用する
確認: そのとおり（旧 498〜518 行）。
対応: `diag_boot_calibrate()` は `int` を返す。`H`/`G` は、前に作ったスレッドがあれば `k_thread_join(&calib_thread, K_NO_WAIT)==0`（完全に終了）のときだけ `k_thread_create` し、そうでなければ `-EBUSY`（コンソールに `rc=-16`）。`h` は 1 回だけ受け付ける（2 回目は `-EBUSY`）。`G` は発火でリセットされるので再利用は起きない。ヘッダ行に `calib_live=` を出す。

## 4. `cur` の更新と CRC の確定が複数の文脈で競合する
確認: そのとおり。書き手は hook、SYS_INIT の段（main スレッド）、feeder（10）、probe（system キュー、-1）、コンソール（14）、TIMER4 の ISR。旧版は各自が `rec_seal()` を呼ぶだけで、更新と CRC の計算を一組として守っていなかった。feeder の CRC 計算中に probe が割り込んで更新と封印をし、feeder が古い内容の CRC を書き戻す順序が可能だった。
対応: スレッド文脈の書き手はすべて `rec_lock()`（`irq_lock`）の下で項目を更新し、`rec_unlock()` が CRC を計算してから解除する（`stage`、`maybe_running`、`probe_fn`、`feeder_fn`、`diag_boot_reboot`、`diag_boot_mark_reboot`、`diag_boot_calibrate`）。TIMER4 の ISR（NVIC 優先度 0、`irq_lock` の外）は排除しない。最後の書き手として記録全体を封印してからリセットし、戻らないので、割り込んだ相手の途中状態は問題にならない。残るのは「ロック中の数マイクロ秒にピンリセットが入る」場合で、CRC 不一致として検出され `invalid` に数えられる。確定済みスナップショットを別に公開する方式は採らなかった（コピーの途中でピンリセットが入れば同じ問題が残り、複雑さだけ増える）。

## 5. 記録喪失の扱いと校正の開始条件
確認: そのとおり。`ring_init_if_needed()` は ring の CRC 不正で count/dropped/invalid を黙って 0 に戻していた。`invalid` に数えるのは magic が一致した記録だけで、README の「magic/CRC 不正」と食い違っていた。枠 4 件に対し校正で 4 件作るのに、第 1 段は「count は直前の値」だった。
対応:
- ring の再初期化を `cur.ring_reinit=1`（記録として残る）とヘッダ行の `reinit=1` に出す。失われるもの（count/dropped/invalid）を README に明記。
- `invalid` の定義を「magic が一致し、fmt_ver か CRC が違った記録」と README と `ring_rec` のコメントに明記。magic 不一致（別の像、初回、RAM 不定）は数えない。
- 枠を 6 件にした（`RING_SLOTS 6`、記録形式 v4）。校正に第 0 段「`d` で読み出して保存 → `c` → `d` で count=0 を確認」を置いた。

## 6.（レビュー外。ビルドで見つかった）像ごとに記録領域のアドレスがずれる
確認: v3 の 2 像は `.noinit` の配置が偶然一致していた（0x20027400）。v4 の最初のビルドでは基準像 0x20027280、最適化像 0x20027300 と 0x80 ずれた。`.noinit` の先頭は `.bss` の大きさで決まるので、像が変われば動く。
対応: `diagrec.overlay`（`-DEXTRA_DTC_OVERLAY_FILE`）で `sram0` を 176 KB に縮め、0x2002c000〜0x2002d000 を `zephyr,memory-region`（`DIAGREC`、NOLOAD）として切り、4 つの記録を 1 つの構造体 `diag_area` にまとめてそこへ置く。像の `.bss` の大きさに関係なく同じアドレスになり、RAM が足りない像はリンクで失敗する（黙って動かない）。0x2002c000 はブートローダーの `.bss` 上端（0x2000ce28）の約 124 KB 上、スタック上端（0x20040000）の 80 KB 下。

## レビュー #7（2026-10-08、校正前の 2 点）への対応
### 7-1. `G` と `h` の `rc=0` は出力できない
確認: そのとおり。`G` は優先度 0 の無限ループを `K_NO_WAIT` で始めるので、呼び出しが戻った直後からコンソール（14）は動けず、仕掛けのリセットまで戻り値を表示できない。`h` も協調ワークが走り始めた時点で同じ。
対応: `diag_boot_calibrate()` を副作用の無い `diag_boot_calibrate_check()`（0 か `-EBUSY`/`-EINVAL`）と `diag_boot_calibrate_start()` に分け、コンソールは判定を `ZDIAG calibrate X rc=N` と出してから、0 のときだけ開始する。拒否した命令に成功を表示することはない（判定と開始は同じコンソールスレッドで連続して行い、間に別の命令は入らない）。開始が戻った後の `ZDIAG calibrate X returned` は `S`（すぐ）と `H`（約 30 秒後）だけに出る。README の手順を「`H` は `returned` と `calib_live=0` を確認してから `G`。`G` と `h` は復帰後の事故記録で実行を確認」に直した。
### 7-2. 出力が 157 文字で切られ、照合に要るアドレスが失われる
確認: そのとおり。旧ヘッダ行は基準像のアドレスで 169 文字になり、`calib=0x…` が切れていた。記録の他の行も、タグ 39 文字と 10 桁のカウンターでは 180〜200 文字になりえた。
対応: ヘッダを「状態」（`ZBOOT ring …`）と「アドレス」（`ZBOOT addr …`）の 2 行に、記録を a/b、entry1/2、us1/2、fire1〜4 の各行に分けた。最長値でも各行 150 文字以内。`out()` のバッファを 256 にし、253 文字を超える行は末尾を ` #TRUNC` に置き換えて切り詰めを明示する（`vsnprintk` の戻り値で検出）。コンソールスレッドのスタックを 2048 にした。
### 7-3. 文書
- README の監視表の「致命的エラーが halt（v4）か sys_reboot（v3）」を「v3、v4 とも watchdog の記録つき sys_reboot」に訂正。
- `cur` の整合性: CRC が保証するのは「読み出した内容が ISR の封印したとおり」まで。複数項目の更新の途中で ISR が割り込めば途中の値が CRC つきで残りうる（`probes_run` と `STG_WQ_PROBED`、`stage` と `stage_cyc[]` の組）。README と `diag_boot.c` の説明をそう改めた。

## レビュー #8（2026-10-08、校正スクリプト aea8f2c の 8 点）への対応（2026-10-08 03:02）
ファームウェアの校正可は維持。スクリプトを作り直し、実機なしの模擬試験で各経路を確かめた（README「模擬試験」）。
1. 手動押下を外す: 第 3 段は実施せず SKIP と記録（PASS にしない）。ピンリセットの保持は未検証のまま。`calib-all.ps1` が事前確認から本番復帰まで人の操作なしで通す。手動復旧が要る状態は成功扱いにせず、到達した状態とログを保存して止まる。
2. FAIL で止める: 前提条件は `Require`（失敗で `Abort`）、以後の確認は `Check`。`Abort` は次のデバイス操作を行わずに終了し、`STOPPED before: <操作>` を残す。校正の中止と本番復帰は別スクリプトで、復帰は結果にかかわらず最後に走り、別に判定する。
3. UF2 ドライブとシリアルの結び付け: `Win32_DiskDrive` の `PNPDeviceID`（`USBSTOR\DISK&…\<シリアル>&0`）→ `Win32_DiskPartition` → `Win32_LogicalDisk` の連鎖で、シリアルに属し `INFO_UF2.TXT` を持つドライブ文字を求める。1 つに定まらなければ複写しない。USB 上のブートローダーが 1 台であることも併せて要求。試験像と本番像の両方に同じ確認。
4. リセットの観測: 子プロセスが「送信」「ポート消失」の時刻を出力に刻み、親は USB の app 離脱を見て、起動番号の増分を照合する。直接観測が無い場合は「未観測」と記録し、起動番号と事故記録で判定する。第 1、4 段は seq 不変、第 2、5 段は +1、第 6、7 段は +2 を要求。
5. 第 7 段: 既存事故記録の全行を書き込み前に保存し、書き込み後に全行が同一であること（行の欠落も不一致）を要求。
6. 本番復帰を必須に: 3 ファイルの存在と md5 を最初の実機操作の前に確認し、複写の直前に再確認。複写は `-ErrorAction Stop` で失敗を記録。復帰の合格条件（ドライブ消失、app 復帰、`version=prof1` かつ `ZBOOT` 行 0 本）を README に明記。校正と復帰の結果は分けて報告（`calib-all.ps1` の終了コード 0/1/2/3）。
7. 読み取り失敗の保存: すべての交換の標準出力、標準エラー、終了コードを保存。dump は開始、終了、必須行の存在を要求。欠落は `FAIL field present` で止め、0 に置き換えない。` #TRUNC` は保存するが判定に使わない。
8. 模擬試験: `-Mock` でデバイス入出力を差し替え、正常 1 場面と異常 15 場面を通した。結果は README の表と `calib-sim-20261008/` のログ。

## レビュー #9（2026-10-08、校正スクリプト 1b32020 の 6 点）への対応
ファームウェアの校正可は維持。スクリプトの 6 点をすべて直し、模擬試験を「期待結果を機械照合する全体実行」に作り直した（README「模擬試験」）。レビューが挙げた 2 つの技術的前提は Microsoft の文書で確認した: `SerialPort.ReadExisting()` は "This method does not use a time-out"（learn.microsoft.com の API 説明）、PowerShell の比較演算子は既定で大文字小文字を区別せず `-c` 付きで区別する（about_Comparison_Operators）。
1. モックの欠落で実機モードへ進む: `calib-all.ps1` は `-MockDir` が指定されたら、起動の前に全段の場面ファイル（pre、flash-base、0〜8（3 を除く）、flash-prod）の存在と JSON の解釈を確かめ、1 つでも欠けるか壊れていれば何も起動せず終了コード 4 で止まる（`MOCK FILE MISSING/INVALID: …`）。子スクリプト側も `-Mock` のファイルが読めなければ終了コード 4 で何もしない。模擬試験の `mock-missing`（flash-prod.json 欠落）と `mock-badjson`（flash-base.json が JSON でない）で、子の起動がゼロ（`STEP`/`FLASH` の開始行も `[calib-io]` の刻印も無い）ことを照合する。
2. 事前確認が試験像の出力を要求: `Step-Pre` は完全な dump（begin/end、`#TRUNC` なし）だけを要求し、`ZBOOT` 行は任意にした（`Read-Dump -ZbootOptional`）。あれば構造を検証して事故記録を含む全行を保存する。試験像固有の確認（タグ、固定アドレス、done=1）は基準像の書き込み後の `calib-flash.ps1 -Expect base` に残した。正常場面 `normal` は本番像（`ZBOOT` なし）から始めて基準像の書き込み、校正、本番復帰まで通す。試験像に古い記録が残った状態から始める `normal-from-test` も別に置いた。
3. 送信直前の壊れた dump で命令を送る: 関門を子プロセス `calib-io.ps1` に移した。子は送信直前に読んだ dump が完全で `#TRUNC` を含まないときだけ書き、`[calib-io] sent 'X'` を刻む。そうでなければ書かずに `NOT sent 'X': <理由>` を刻み終了コード 2。親の `Send-Cmd` は子の `sent` の刻印を `Require` し、無ければ命令の前で FAIL（`STOPPED before: send 'X'`）。場面 `gate-c`/`gate-h`/`gate-r`/`gate-b` は最初の読み取りを正常、送信のための読み取りだけを `#TRUNC` か `ZDIAG end` 欠落にし、`sent` の刻印が無いことと `DEVICE-OP copy` が無いことを照合する。模擬でも子は実物を動かす（ポートだけ `-MockFile` の缶詰に置き換える）ので、関門の論理そのものが試験対象になる。
4. 保証が実装より広い: `Validate-Dump` を入れ、判定に使う dump 全体の構造を要求する（`ring`/`addr` の全キー、`count` ぶんの `inc` がそれぞれ `a/b/entry1/entry2/us1/us2/fire1〜fire4` の全行と全キーを持つこと、`count` を超える `inc` が無いこと、`last`/`cur` の全行、`fire` 行は全部か無しか）。消去（`c`）の前の読み取りも同じ検証を通るので、`count=1` なのに `inc0` が無ければ `c` を送らない（場面 `ring-count-mismatch`）。新しい事故記録に `fire3`/`fire4` が無ければ FAIL（`inc-no-regs`）。`Check-Incident` は `fire1`/`fire3`/`fire4` の行を証拠としてログに写す。コンソール文字列の比較を全部 `-ceq`/`-cne`/`-cmatch`/`-cnotmatch`/`-clike` にした（第 7 段の全行比較、命令応答 `ZDIAG calibrate h rc=0`、`calib=` の値、模擬の送信順の照合）。場面 `inc-case`（既存記録の `calib=h` が `H` に変わる）で `inc0 kept verbatim` が FAIL になることを照合する。Windows の PnP の InstanceId の照合だけは大文字小文字を区別しない `-match` のまま（Windows 側の表記の問題で、コンソール文字列ではない）。
5. 子が戻らないと復帰に到達しない: 子の起動を `Invoke-Child`（`Start-Process` + `WaitForExit(期限)`、超過で `taskkill /T /F` によるプロセスツリーの終了）に統一した。交換は `ReadSeconds + 20` 秒、各段と復帰は README の表の期限。子の標準出力と標準エラーはリダイレクトで書かれた端からファイルに落ち、強制終了しても残る（`calib-io.ps1` も 1 区切りごとに flush する）。期限超過は交換なら `FAIL console child returned within Ns (timed out; killed …; sent stamp PRESENT/absent)`、段なら `TIMEOUT` として校正を不合格にし、復帰は必ず試みて別に判定する。場面 `io-hang`（子がポートを開いたまま戻らない。期限 3 秒）、`step-hang`（段が戻らない。期限 8 秒）、`restore-hang`（復帰が戻らない。期限 8 秒）で、期限内に止まり、復帰が試みられ、その結果が確定することを照合する。手動押下もユーザーへの応答待ちも足していない。
6. 模擬試験が期待結果を自動検証しない: `calib-sim.sh` を `calib-sim.py` に置き換えた。各場面は `expect.json`（終了コード、`results:` 行の全段の値、ログに必ず現れる正規表現と現れてはならない正規表現（ファイル名の glob で段を限定できる））を持ち、全場面を `calib-all.ps1` の全体実行として流して照合し、1 つでも不一致なら非ゼロで終わる。異常場面も全体実行なので、「失敗後に後続段が走らない（`not-run`）」「それでも復帰だけは走る」が各場面の `results:` 行で照合される。結果は `report.txt`（判定表と決め手の行）と `results.json`。記録は `calib-sim9-20261008/`（README「模擬試験」に 29 場面の表）。この版の初回実行が、旧版では見えなかった欠陥を捕まえた（子の刻印 `… (no ZDIAG end within 4 s)` が親の `ZDIAG end` の判定に当たる。行頭アンカーと刻印の文言の変更で修正）。

## 像の識別
| 像 | タグ | ELF md5 | UF2 md5 | ベクタ表 27 番 | `diag_spin_forever` | USB READY 待ち |
|---|---|---|---|---|---|---|
| 基準 `coron_R-bt4` | `bt4-R-10080217` | b32956d62f1dd6fb3af6be0b5ba5b6c9 | df108d7ad2009afccfbfbba66b6ad093 | 0x00066271 | 0x662ea〜 | 0x57f3c〜0x57f43 |
| 最適化 `coron_R-bt4-alt` | `bt4A-R-10080217` | a4dced604ea9e67fc16810481c1983f2 | e1e62efeeda0f87a1678a3d53f8151cf | 0x00038029 | 0x38a08〜 | 0x6c4d4〜0x6c4db |
（レビュー #7 の前の像 `bt4-R-10080143` / `bt4A-R-10080143`（ELF md5 ef0524695a8f… / bc4738657a03…）は出力の切り詰めがあるので校正に使わない）
両像とも `diag_area` = 0x2002c000（大きさ 0x93c、NOBITS）、`CONFIG_SRAM_SIZE=176`、`CONFIG_ZMK_WATCHDOG_FREEZE_DETECT` 無効、`CONFIG_ZMK_WATCHDOG_FATAL_DETECT=y`（`k_sys_fatal_error_handler` は `watchdog_fatal.c:65` のもの。`fatal_reboot.c` は build.ninja に無い）。ソースの md5 は `md5sums.txt`。
ビルドログの注意: `west build` の初回は nanopb の生成（`protoc-gen-nanopb`）が `google.protobuf` 不在で失敗し、続けて実行する `ninja` で完了する（v3 の像も同じ手順。`build-boottest2.sh`）。

## レビュー #10（2026-10-08、校正スクリプト 16e92f0 の 3 点）への対応
ファームウェアの校正可と第 3 段の SKIP は維持。29 場面の記録（`calib-sim9-20261008/`）はレビューが証拠として認めたのでそのまま残し、修正後の 37 場面を `calib-sim10-20261008/` に置いた。
1. 全事故記録に `fire1`〜`4` を要求するのはファームの保存規則と合わない（レビュー側も前回の要求を訂正）: `diag_boot.c` の `is_incident()` は reason=1/2 に加えて `boot_done==0 && reason != R_REBOOT_REQ`（reason=0 の起動中断）も事故として保存し、`print_rec` は `fire.exc_return != 0` のときだけ `fire` 行を出す。`Validate-Record` を reason で分けた: 基本 6 行と全キーは全記録に要求、reason=1/2 には `fire` 4 行と全キーを要求、それ以外は `fire` 行なしを許容、一部だけある記録はどの reason でも拒否。校正の h/G/S の事故は reason が 1/2 なので従来どおり 4 行が要る（`Check-Incident` も `fire1`/`fire3`/`fire4` を `Need` する）。追加場面 `inc-boot-abort`（done=0、reason=0、`fire` なしの既存記録を読み出して保存）と `inc-partial-fire`（`fire1`/`fire2` だけ → 拒否）。README の「全 inc に fire 必須」を訂正した。
2. 完全な dump の判定が子と親、本番復帰でそろっていない: 子 `calib-io.ps1` の読み取り終了条件と送信条件を行の形式で判定するようにした（開始行 `(?m)^ZDIAG begin\b`、終了行 `(?m)^ZDIAG end\r?$`）。`ZDIAG endBROKEN` は印にならず、子は送らない（追加場面 `gate-endbroken`）。本番復帰の判定を他の dump と同じ `Validate-Dump`（完了、` #TRUNC` なし。`ZBOOT` 行は任意で、あれば構造検証して本番像でないと判定）に通した（追加場面 `prod-trunc`: 復帰後の dump に ` #TRUNC` → restore FAIL）。
3. 期限超過後に「終了させた」を確認せず復帰へ進む: `Invoke-Child` は終了要求の前にプロセスツリーを `Win32_Process` の親子関係で列挙し、`taskkill /T /F` の出力と終了コードを記録し、列挙した全 PID が消えたことを 5 秒の期限つきで確かめる（`WaitForExit(Int32)` は未終了なら false を返すだけで確認にならない、は Microsoft の文書どおり）。終了要求が 0 を返し全 PID が消えたときだけ `killed=$true`。交換の子で確認が取れなければその段は `Abort` して終了コード 5、段や復帰で取れなければ `TIMEOUT-ALIVE`。`calib-all.ps1` はどちらでも復帰を試みず（`RESTORE NOT ATTEMPTED`、`restore=not-attempted`、終了コード 3）、「本番へ戻せなかった」を失敗として記録して終わる。押下依頼も応答待ちも無い。追加場面 `kill-fail`（終了要求が失敗）、`kill-linger`（終了要求は 0 を返すが対象が残る）、`tree-kill`（段の配下に交換用の子がいる。ツリーに 2 つ以上の PID、終了確認済み、復帰 PASS）、`restore-kill-linger`（復帰の終了未確認）。模擬は `taskkill` の呼び出しだけを差し替え、ツリーの列挙と終了確認は実物（本当に残っている PID を見る）。
今回の変更で模擬試験が捕まえた自分の誤り: `Log "… rc=$krc: $kout"` が PowerShell のドライブ修飾変数として解釈され起動時に落ちた（`${krc}` に修正。全 37 場面が一様に 2 秒で失敗したので見逃せなかった）。

## レビュー #11（2026-10-08、校正スクリプト 32f8f74 の 1 点）への対応
ファームウェアの校正可、第 3 段の SKIP、37 場面の結果はレビューが承認。残った 1 点は「終了処理そのものに期限が無い」（`Get-ProcessTree` の CIM 呼び出しと同期実行の `taskkill` は、戻らなければ 5 秒の確認に到達しない）。
対応: 列挙、終了要求、確認を専用の子プロセス `calib-kill.ps1` に分離し、司令側（`Invoke-Child`）はそれを 20 秒の期限で待つ。子は段階ごとの進捗を逐次出力するので、戻らなくても到達した段階が残る。期限内に戻って `confirmed=True`（`taskkill` が 0 を返し全 PID が消えた）のときだけ終了確認済み。戻らなければ到達段階を記録し、子を `Process.Kill()` で捨て（Microsoft の文書どおり非同期で待たないので、確認には数えない）、終了未確認として扱う。終了未確認の扱い（段は終了コード 5 か `TIMEOUT-ALIVE`、復帰を試みず `RESTORE NOT ATTEMPTED`、終了コード 3、押下依頼も応答待ちも無し）は前回のまま。
追加場面: `kill-enum-hang`（列挙が戻らない）、`kill-req-hang`（終了要求が戻らない）、`io-kill-req-hang`（交換の子の終了要求が戻らない）。いずれも司令側が 20 秒で結果を確定し、`RESTORE NOT ATTEMPTED` を残し、後続の命令送信と複写を行わないことを機械照合した。模擬は補助プロセスの該当段階で止まるだけで、列挙と確認の処理は実物。40 場面の記録は `calib-sim11-20261008/`（09:32〜09:39）。

## 実機初回（2026-10-08 10:41〜、レビュー #12 の後）で見つかった 2 件
記録は `calib-real-20261008/`。1 は実機の読み取りで初めて分かった形。2 は `.config` とソースから事前に分かる設定差（試験像と本番像の通信仕様の差）をスクリプトと模擬に反映し忘れていたもので、「実機でしか分からない」は誤り（レビュー #13 で訂正）。
1. USBSTOR のインスタンス ID の形: 実機は `USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B1&0`（シリアルの前に `A&258725EA&0&`）。照合を「末尾の `&N` の直前の要素がシリアル（直前が `\` でも `&` でもよい）」に直した（`calib-lib.ps1` の `Get-Uf2DrivesOfSerial`。1 行）。読むだけの確認で `drives of serial=[E]`、ブートローダー 1 台。この修正で本番復帰は通った。
2. 試験像は DTR で dump しない: bt4/bt4A は `CONFIG_UART_LINE_CTRL` 無効（`coron_R-bt4.config`）で、`diag_min.c` は line control が取れないと「`d` のときだけ dump」になる。本番像は line control ありで開くだけで dump する。子 `calib-io.ps1` は開いて 1.5 秒で dump が無ければ `d`（読み出し要求）を 1 回送るようにした。命令の関門（直前の dump が完全で `#TRUNC` なし）はそのまま。模擬の試験像の交換は「`d` で初めて dump する」缶詰（`dump_on_request`）にし、本番像の交換は従来どおり開くだけで dump する。
3 回目（10:58:50、両修正入り）で校正 PASS（第 3 段 SKIP）、本番復帰 PASS。実測は `calib-real-20261008/README.md`。

## レビュー #13（2026-10-08、468f07e の 3 点。校正 PASS と本番復帰 PASS は受理）への対応
1. `d` の送信先: 子は同じシリアルの全 Ports に `d` を書いていた（本番像では MI_03 = Studio の RPC UART にも。復帰ログに `opened COM7` → `sent 'd'`）。`Test-ConsoleIface` を入れ、`Get-DiagPorts` は親がこのシリアルで USB インターフェース番号が `MI_00` の Ports だけを返す（根拠は README「校正」: 両像の `zephyr,console = &board_cdc_acm_uart`（cdc_acm インスタンス 0）、`usb_fix_descriptor` の番号付け、実機で MI_00 だけが `ZDIAG` を返した事実）。COM 番号は使わない。他のインターフェースは開かない。模擬の `ports` は実機のインスタンス ID を持ち、同じ関数で絞る。追加場面 `two-ports`（COM5 MI_00 と COM7 MI_03 が同時にある本番像の形で全体実行。COM7 を開かない、書かないことを照合）。
2. USBSTOR 照合の直接検証: 照合を `Test-UsbstorSerial` に分け、実機と模擬で同じ実装にした（模擬のドライブは実機から読んだ完全なインスタンス ID を持つ）。`calib-selftest.ps1` が実機の ID を入力に 15 件（接頭辞あり／なし、末尾 `&1`、別シリアル、前後 1 文字多い、1 文字短い、位置違い、USBSTOR でない、小文字、インターフェース番号の 5 件）を直接検証し、`calib-sim.py` の最初に走って不一致なら全体を非ゼロにする。追加場面 `uf2-partial-serial`（部分一致の 2 台だけ → 複写しない）、`uf2-noprefix`（接頭辞なしの ID → 通る）。
3. 文言の訂正: 「どちらも実機でしか分からなかった」は誤り。USBSTOR の ID 形式は実機の読み取りで判明したが、試験像の `CONFIG_UART_LINE_CTRL` 無効と `d` だけで dump する分岐は公開済みの `.config` とソースから事前に確認できた。正しくは「試験像と本番像の通信仕様の差をスクリプトと模擬に反映し忘れていた」。README と実機記録の文言を直した。

## レビュー #14（2026-10-08、76a4c24 の 3 点は受理。無人ループ案への 4 条件）への対応
計画は `loop-plan.md`、実装は `calib-loop.ps1`（司令）と `calib-trial.ps1`（試行 1 回の子）。実機では動かしていない。
1. 再現条件: 各試行は 13〜26 分の稼働（既定 13, 26, 17, 21, 13 分）の後に 1 回の操作。稼働時間は `up_ms`、接続状態は `ZDIAG now count` の計数と 10 秒ごとの USB 状態で記録。短周期は別の探索試験として扱い、0 件でも現場の停止を否定しない（計画書に明記）。
2. 書き込みと `r` の分離: `-Mode write`（像の交互書き込み）と `-Mode reset` は別の実行で、台帳の分母も分かれる。各行は操作、書いた像、起動番号を対応づける。「全ページ違う」は撤回し、UF2 の内容の比較（4 KiB ページで 104 中 0 が同一。消去回数は別で未計測）だけを書く。
3. 停止条件: 基準（試行 0）で既存記録を全部 PC へ保存し、seq/count/dropped/invalid/reinit を確定。新規記録（count か dropped の増加）、予想外の起動数、ring 再初期化、無効記録の増加、稼働中の離脱、外部応答なし、dump 欠落のどれでも次の書き込みへ進まず停止。校正の名残（`calib=` 印あり）と自然の記録（`-`）を分類。事象は PC へ保存してから本番復帰。dump が取れなければ「観測失敗」として停止機構は未確定のまま保存。
4. 期限と復帰: 司令側はデバイスにも CIM にもシリアルにも触れず、全操作を `Invoke-Child`（`calib-kill.ps1` の 20 秒期限つき終了処理）で実行。周回数の上限、新しい試行を始めない時刻（`-NoNewTrialAfter`、復帰の予約込み）、終了未確認なら復帰を試みない。模擬 14 場面（新規事故、予想外の起動番号、ring 再初期化、途中 FAIL、期限到達、終了未確認、本番復帰 FAIL、外部応答なし、稼働中の離脱、満杯の dropped、校正の名残、基準の自然記録、リセット群、正常）を機械照合した（`calib-sim14-20261008/`）。
実装中に模擬が捕まえた自分の誤り 2 件: `"$Mode:"` のドライブ修飾（3 度目。`${Mode}:` に修正）、`[string]` 型の引数 `$Dwells` と同名の `$dwells` に配列を代入して文字列に戻っていた（PowerShell の変数名は大文字小文字を区別しない。別名 `$dwellList` に修正）。

## レビュー #15（2026-10-08、57f24b0 の無人ループの 6 点）への対応
実機では動かしていない。計画書 `loop-plan.md` を更新。
1. reinit の意味: `ring_reinit_this_boot` は起動時に 1 回決まり、ヘッダと cur の両方に同じ値が出る（`diag_boot.c` 412/443/696 行）。`Judge` を同じ起動の比較（旗が基準と同じこと）と新しい起動の比較（0 であること）に分け、`Validate-Dump` にヘッダと cur の不一致の拒否を足した。模擬は seq 1 の全 dump で 1、以後 0 に直した（校正の模擬も同じ矛盾を抱えていて、新しい検査が 28 場面で捕まえた。直した）。追加場面 `loop-reinit-flag-change`、`loop-header-cur-mismatch`。
2. 事前確認: 司令側は最初に `calib-run.ps1 -Step pre`（期限 90 秒）を走らせ、基準像、最適化像、本番像の存在と md5、いまの像の dump を確かめる。失敗なら実機変更を始めず、復帰も「不要」として終わる（`$deviceChanged` で区別）。追加場面 `loop-prod-missing`、`loop-alt-md5`（`FLASH base start` も `DEVICE-OP` も `sent` も無い）。
3. done と up_ms: 起動後は done=1 になるまで 10 秒おきに最大 6 回読み、未到達なら事象（`running-not-reached`）。基準の試行も done=1 を要求。`up_ms` は必須項目で、同じ起動で単調増加（逆行・停滞は事象）、再現条件は `up_ms` の進みが [稼働 − 2 秒, 稼働 + 120 秒] かつ操作直前の `up_ms ≥ 稼働`（許容差は計画書に明記。丸めた分の値では判定しない）。追加場面 `loop-done0`、`loop-upms-missing`、`loop-dwell-short`、`loop-uptime-regress`。
4. 稼働中の離脱: 最初の app 以外の状態で稼働を打ち切り、90 秒の期限つきで復帰を待って記録を読み（同じ起動として比較し、再起動は予想外として報告）、保存して停止。`b`/`r`/複写には進まない。`loop-left-app` は poll 3 で止まり、残りを消化せず、分母 0。
5. 結果ファイル: 子は保存失敗を失敗（終了コード 1）にする。司令側は終了コード 0 を、その試行番号の完全な結果（`result=ok`、起動後の seq/count/dropped/invalid/reinit/up_ms/tag/done、`completed`）がそろうときだけ受理し、欠落・不正・別試行なら停止して比較対象を空にしたまま続けない。試行ループを try/catch で包み、例外も失敗として記録して復帰の方針を維持。追加場面 `loop-result-missing`、`loop-result-stale`。
6. 台帳の分母: 各試行に段階（dwell_started、op_sent、image_written、boot_observed、running_confirmed、completed）を実績として記録し、分母はそこから数える（「書き込み後の起動」= 像の複写完了）。予定した像・tag と実績（`image_written`、`tag_after_observed`）を分けた。離脱場面は `b sent=0, images written=0`、複写失敗は `b sent=1, images written=0`、外部応答なしは `images written=1, boots observed=0`。結果ファイルが無い試行は「段階不明」として分母から外し別に数える（`stages unknown=1 (no result file; these trials may have operated the device)`）。

## レビュー #16（2026-10-08、ff62123 の台帳の 2 点）への対応
1. 拒否した結果ファイルの段階を集計に使っていた: 司令側は結果ファイルの帰属（JSON が読める、試行番号が一致、段階の塊がある）を先に確かめ、通らなければ段階を一切採用せず「段階不明」にする。その試行の実績は、試行自身のログの刻印（子の `[calib-io] sent 'b'`/`'r'`、複写の `DEVICE-OP copied`）で確認できるものだけを出所つき（`stages_source=trial log stamps only`）で採用する。`loop-result-stale` の期待に「試行 2 を正常完了に加算しない（`RUNNING confirmed=1, completed without event=1`）」「無効な結果の段階を実績に入れない」を加えた。
2. 送信後のタイムアウトで未送信になる: `Exchange` が子の `sent` の刻印を `$script:lastSentStamp`（true / false / 子がタイムアウトして刻印なしなら unknown）に残し、試行は `Send-Cmd` の成否と独立に `finally` でそれを `op_sent` へ引き継ぐ。台帳は true だけを送信数に数え、unknown は別に数える。追加場面 `loop-b-sent-timeout`（送信 1、複写 0、試行 FAIL、終了確認済みで復帰 PASS）、`loop-r-sent-timeout`、`loop-b-sent-timeout-alive`（終了未確認で復帰を試みない）。模擬ポートに「送信後の最初の読み取りで止まる」（`hang_after_send_s`）を足した。

## レビュー #17（2026-10-08、24d34bc の残り 3 点）への対応
1. 完全性検査の前の採用: `Test-ResultUsable` が、帰属（試行番号、段階の塊の 7 項目が真偽値か「不明」）と、子が終了コード 0 のときの成功契約（`Test-ResultComplete`: `result=ok`、`after` の全項目、`completed`）を、台帳に触れる前にまとめて確かめる。通らなければ段階も成功数も採用せず、試行自身のログの刻印だけを出所つきで採用する。追加場面 `loop-result-noafter`（`after` 欠落 → `completed without event=0`、`stages unknown=1`）。
2. 未送信の根拠: `Exchange` の分類を「`sent` の刻印 → true、子の明示的な `NOT sent` → false、それ以外（タイムアウト、書き込み中のエラー、落ちた）→ unknown」にし、分類の根拠をログに残す。台帳は `not sent (explicit)` と `op sent unknown` を別に数える。模擬ポートに「書き込みの中で例外」（`write_error`）を足した。追加場面 `loop-b-send-error`（unknown、未送信に加算しない、試行 FAIL、試行 2 なし）、`loop-b-not-sent`（明示的な拒否は未送信 1）。
3. 模擬の複写刻印: 模擬の `Copy-Uf2` は「複写を試みた」（`copy attempt (mock)`）と、成功したときだけの完了刻印 `DEVICE-OP copied (mock)` を実機と同じ順序で出す。`Get-LogStages` は完了刻印だけを証拠にする。追加場面 `loop-copy-fail-noresult`（複写失敗 + 結果ファイル欠落 → `images written=0`）。
途中で模擬が捕まえた自分の誤り: 分類のログ行の `timed out=False` が正常場面の禁止語 `timed out` に当たった（語を `timed_out` に変更）。
