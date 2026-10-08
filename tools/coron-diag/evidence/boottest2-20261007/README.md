# 証拠の束（Coron 起動停止の調査、計測器 v4、2026-10-07 23:59 作成、2026-10-08 19:05 更新）

GitHub で読める写しは `haoblackj/zmk-config-coron` の `feat/dya-diagnostics` ブランチ、`tools/coron-diag/`（モジュールのソース）と `tools/coron-diag/evidence/boottest2-20261007/`（この束。ELF と UF2 は大きさの都合で入れず、md5 だけ置く。要るときは渡す）。

## v3 → v4 の変更（レビュー #6 の 5 点への対応。差分は `review6-fixes.md`）
1. 試験像で `CONFIG_ZMK_WATCHDOG_FREEZE_DETECT=n`（`boottest*.conf`）。時間で発火してチップをリセットする監視が TIMER4 の仕掛けだけになる。fatal 検出（`CONFIG_ZMK_WATCHDOG_FATAL_DETECT=y`）は残す（フォルトにだけ反応し、PC/LR を記録して再起動する。切ると設定リポジトリの `src/fatal_reboot.c` が記録なしで再起動する側に入る）。
2. `H` は 30 秒で終わる負荷になり、終了後にコンソールが戻る。
3. `H`/`G` は前のスレッドが完全に終了（`k_thread_join`==0）するまで `-EBUSY` で拒む。`h` は 1 回だけ受け付ける。
4. `cur` のスレッド文脈からの更新は `irq_lock` の下で「更新 + CRC」を一組にした。TIMER4 の ISR は最後の書き手で戻らない。
5. ring の再初期化を `cur.ring_reinit` とヘッダ行 `reinit=` に出す。`invalid` の意味を「magic が一致し fmt_ver か CRC が違った記録」と明記。枠を 6 件にし、校正の前に読み出し、退避、`c`、`count=0` の確認を置く。
6. （レビュー外、ビルドで判明）記録領域を `diagrec.overlay` で 0x2002c000 に固定。像ごとに `.noinit` の位置がずれるのを防ぐ。

## ファイル
- `../coron_R-bt4.{uf2,elf,config}` タグ `bt4-R-10080217`（ELF md5 b32956d62f1d…）、`../coron_R-bt4-alt.{uf2,elf,config}` タグ `bt4A-R-10080217`（速度最適化、交互書き込み用。ELF md5 a4dced604ea9…）。レビュー #7 の前の像（`bt4-R-10080143`、`bt4A-R-10080143`）は出力の切り詰めがあるので使わない。md5 は `md5sums.txt`。v3 の像（`bt3-R-10072355`、`bt3A-R-10072355`）は校正に使わない。
- `../diag_boot.c`（計測器）、`../diag_min.c`（コンソール命令）、`../CMakeLists.txt`、`../Kconfig`、`../boottest*.conf`、`../diagrec.overlay`（記録領域を 0x2002c000 に固定する devicetree）、`../build-boottest2.sh`（ビルド手順。記録領域のアドレスを出力する）。
- PC 範囲（`disasm-net.txt`）: USB READY 待ち（`nrf_usbd_common.c:1009`）は基準像 0x57f3c〜0x57f43、最適化像 0x6c4d4〜0x6c4db。`diag_spin_forever` は 0x662ea〜、0x38a08〜。ベクタ表 27 番は 0x00066271、0x00038029。
- `review6-fixes.md` レビュー #6 の各指摘に対する検証結果と修正箇所。
- `disasm-net.txt` 例外入口（naked）から記録処理までの逆アセンブル、ベクタ表 27 番の中身、USB READY 待ちと `diag_spin_forever` の PC 範囲、記録領域と主要スレッドのアドレス（像ごと）。
- `bootloader-ram.md` 実機のブートローダー（Seeed 配布の XIAO Sense 版、文字列 0.6.1）の hex から読んだ RAM の静的な使用範囲（.data 0x20008000〜0x20008620、.bss 〜0x2000ce28、初期 SP 0x20040000）と記録領域の位置、第 7 段で照合する項目。`bootloader-ram.txt`（リンカスクリプトだけの旧版）を置き換える。
- `fatal-path.md` 「main スレッドの終了」判定の根拠。致命的エラー処理（watchdog モジュールの上書き → `sys_reboot`。v3 と v4 で同じ）と、設定リポジトリの `src/fatal_reboot.c` との排他。
- `pnp-raw-1007.txt` Windows の PnP ログの生の行（10/07 15:40〜16:45、Coron のシリアルと BLE HID と VID_0000 に限定）と、不明デバイスのポート。
- `transcript-quotes-1007.md` 10/07 のトランスクリプトの該当行（原文）。
- `config-repo-head.txt`、`west-shas.txt` ビルド時の設定リポジトリと依存の SHA。

## 記録領域（両像で同一。`build-boottest2.sh` が毎回出力する）
| 変数（`diag_area` の中） | アドレス | 大きさ |
|---|---|---|
| `arm_next` | 0x2002c000 | 8 |
| `ring`（枠 6） | 0x2002c008 | 0x6ec |
| `last` | 0x2002c6f4 | 0x124 |
| `cur` | 0x2002c818 | 0x124 |
`diagrec.overlay` が `sram0` を 176 KB に縮め、0x2002c000〜0x2002d000 を `zephyr,memory-region`（`DIAGREC`、NOLOAD、readelf で NOBITS を確認）として切る。像の `.bss` の大きさに関係なく同じアドレスになる。v3 の 2 像は `.noinit` の位置が偶然一致していた（0x20027400）だけで、v4 の最初のビルドでは 0x80 ずれた（`review6-fixes.md` の 6）。
ブートローダーが静的に書く範囲は .data 0x20008000〜0x20008620 と .bss 〜0x2000ce28（配布 hex のリセット処理から。`bootloader-ram.md`）、初期 SP は 0x20040000。記録領域はその外。ブートローダー実行中のスタックの深さとヒープは静的には分からないので、保持は第 7 段で記録の全項目（tag、seq、reason、calib、stage）を照合して確かめる。前版（同じ配置方針）は 112 周の `b`/UF2 交互書きで magic と CRC が残ったが、それは「領域が読めた」までの確認。像を替えるたびにアドレスの一致を確認する（違えば記録は無効として扱う）。

## 像の中のほかの監視
| 監視 | v3 像 | v4 像 |
|---|---|---|
| watchdog モジュールの freeze 検出（task_wdt、system と lowprio の 2 キュー、最後の給餌から 10 秒で ISR 文脈から `sys_reboot`） | 有効。`h`/`G` では仕掛け（15 秒）より先に再起動し、PC は残らず、`cur` は done=1/reason=0 で事故にならない | 無効 |
| watchdog モジュールの fatal 検出（`k_sys_fatal_error_handler` を上書きし、reason/PC/LR/スレッドを自分の記録に残して `sys_reboot`） | 有効 | 有効（変更なし）。時間で発火する監視ではないので TIMER4 と競合しない。この計測器からは再起動として見える（起動中なら INCOMPLETE として保存、RUNNING 後なら保存しない。フォルトの内容は watchdog の記録を Studio で読む） |
| 設定リポジトリの `src/fatal_reboot.c`（記録なしで `sys_reboot`） | 入らない（fatal 検出が有効のとき CMake が外す） | 入らない |
| ハードウェア WDT | 無し（`CONFIG_WATCHDOG` 無効） | 無し |
停止が確認できた 3 件の像は watchdog モジュールが入る前（162637f、10/07）のもので、freeze 検出は無かった。致命的エラーの扱いは像ごとに違う: bbc509c（10/04）は Zephyr 既定の halt、8d7cc27（10/05 19:47）は `fatal_reboot.c`（10c183c、10/05 00:53）による記録なしの再起動、diag-min3（10/05 09:26 書き込み）は設定が残っておらず不明。v4 の条件（freeze なし、fatal は記録つき再起動）は 8d7cc27 に近く、bbc509c の halt とは違う。自然発生の試験の条件として「freeze 検出なし、fatal は watchdog の記録つき再起動」を記録する。本番像（freeze 検出あり）で同じ停止が起きたときの振る舞いは別の問題として残る。

## 状態遷移（次の起動が事故として保存する条件）
| 出来事 | boot_done | reason | 事故として保存 |
|---|---|---|---|
| 正常起動 → `r`/`b` | 1 | REBOOT_REQ(3) | しない |
| 正常起動 → ピンリセット | 1 | NONE(0) | しない |
| RUNNING 未到達で仕掛けが発火 | 0 | BOOT_TIMEOUT(1) | する |
| RUNNING 未到達でピンリセット | 0 | NONE(0) | する（INCOMPLETE） |
| `S` で仕込んだ停止 → 発火 | 0 | BOOT_TIMEOUT(1) | する（calib=S） |
| RUNNING 後に監視が期限切れ | 1 | WQ_TIMEOUT(2) | する |
| RUNNING 後に `h`/`G` → 発火 | 1 | WQ_TIMEOUT(2) | する（calib=h/G） |
| RUNNING 後に `H`（30 秒で終了、発火しない） | 1 | NONE(0) | しない |
| 致命的エラー → watchdog が記録して即再起動（起動中） | 0 | NONE(0) | する（INCOMPLETE。フォルトの内容は watchdog の記録） |
| 致命的エラー → watchdog が記録して即再起動（RUNNING 後） | 1 | NONE(0) | しない（watchdog の記録だけ） |
| 記録の magic が一致し fmt_ver か CRC が不正 | - | - | 保存せず `ring.invalid` に数える |
| 記録の magic が不一致（別の像、初回、RAM の内容不定） | - | - | 保存せず、数えもしない（`last none`） |
| ring の magic/CRC が不正 | - | - | ring を初期化し直す。count/dropped/invalid は失われ、その起動の `cur.ring_reinit=1` とヘッダ行の `reinit=1` に残る |
規則: `reason ∈ {1,2}` または（`boot_done==0` かつ `reason≠3`）。「書き込み完了」（CRC 一致）、「起動完了」（boot_done）、「事故」（上の規則）は別の情報。

## 監視
| 監視 | 期限 | 解除／切替の条件 | 期限切れが意味すること |
|---|---|---|---|
| 起動 | 入口から 20 秒 | main スレッドが終了した（`k_thread_join(&z_main_thread, K_NO_WAIT)==0`。join は終了の仕方を区別しない。この構成（v3、v4 とも fatal 検出有効）では致命的エラーが watchdog の記録つき `sys_reboot` に進み、他に `k_thread_abort` の呼び出しが無いので、終了は `main()` が戻った場合に限られる。根拠は `fatal-path.md`。ZMK の `main()` は `settings_load()` の後に戻る）かつ、システムワークキューで最初の probe が走った | 所定の段に到達しなかった |
| ワークキュー | 餌なしで 15 秒 | 餌は優先度 `K_PRIO_PREEMPT(10)` の feeder スレッドが「前回の probe が走った」ときだけ与える（2 秒周期） | 監視処理の進行が止まった（probe が走らない、または feeder 自身が飢えた）。ワークキューの停止とは限らず、PC とスレッドで判断する |
記録する数: probes_submitted、probes_run、feeds、feeder_loops、last_feed_cyc。

### `cur` の整合性
スレッド文脈の書き手（SYS_INIT の段、feeder、probe、コンソール）は `irq_lock` の下で項目の更新と CRC の計算を一組にする。TIMER4 の ISR は NVIC 優先度 0 で `irq_lock` の外にあるが、最後の書き手として記録全体を封印してからリセットし、戻らないので、割り込まれたスレッドが古い CRC を後から書き戻すことは起きない。CRC が保証するのは「読み出した内容が ISR の封印したとおりである」ことまでで、複数項目の更新の途中で ISR が割り込んだ場合、その途中の値（例: `probes_run` は増えたが `STG_WQ_PROBED` の刻印はまだ、`stage` は進んだが `stage_cyc[]` はまだ）が CRC つきで保存されることはある。読むときはこの組を「途中の可能性あり」として解釈する。残るのは「ロック中の数マイクロ秒にピンリセットが入る」場合で、CRC 不一致として検出され `invalid` に数えられる（誤った内容が有効と読まれることはない）。

## 校正（実機。リーダーの許可の後。手動操作なし。所要 20 分）
実行は `tools/coron-diag/calib/` のスクリプト。`calib-all.ps1` が「事前確認 → 基準像の書き込み → 第 0〜8 段（第 3 段は SKIP）→ 本番復帰」を人の操作なしで通し、各段の生のコンソール出力と PASS/FAIL（期待値と実測値）を `stepN-<時刻>.log` に、全体を `summary.log` に残す。各段と復帰は子プロセスとして期限つきで起動し（pre 90 秒、基準像の書き込み 300 秒、第 0/1/8 段 90 秒、第 2/5/6 段 240 秒、第 4 段 150 秒、第 7 段 400 秒、復帰 300 秒。各段自身の待ち時間の合計より長い）、期限までに戻らない子の終了は、専用の子プロセス `calib-kill.ps1` に委ねる。それがプロセスツリー（`Win32_Process` の親子関係）を列挙し、`taskkill /T /F` を実行して出力と終了コードを記録し、列挙した全 PID が消えたことを 5 秒の期限つきで確かめ、段階ごとの進捗（`phase=enumerate`、`tree=[…]`、`phase=terminate`、`taskkill rc=…`、`phase=confirm`、`alive=[…] confirmed=…`）を逐次出力する。司令側はその子プロセスを 20 秒の期限で待つ（CIM の列挙も `taskkill` も同期呼び出しで内側からは打ち切れないので、終了処理全体の期限はここにある）。期限内に戻って `confirmed=True` を返したときだけ「終了確認済み」（`TIMEOUT`）として校正を不合格にし復帰へ進む。戻らなければ到達した段階を記録し、その子プロセスを `Process.Kill()` で捨て（非同期で待たない。確認には数えない）、終了未確認とする。確認が取れなければ `TIMEOUT-ALIVE` とし、校正のプロセスがまだポートへ書くか複写しうるので、復帰を含む以後の実機操作を一切行わず「本番へ戻せなかった」を失敗として記録して終わる（`RESTORE NOT ATTEMPTED`、`restore=not-attempted`、終了コード 3。押下依頼も応答待ちも無い）。交換の子（`calib-io.ps1`）の終了確認が取れなかった段は終了コード 5 で戻り、同じ扱いになる。子の標準出力と標準エラーは書かれた端からファイル（`child-<段>.out/.err`、交換ごとの `step<段>-<時刻>-ioN.out/.err`）に落ちるので、強制終了しても途中までの出力が残る。
- 第 3 段（ピンリセット 1 回押し）は実施しない。手動操作をこの実行に含めないため SKIP と記録し、PASS にはしない。ピンリセットを挟んだ保持は未検証のまま残す。`r` のソフトリセットをその代わりの合格にはしない。
- FAIL で止まる。各段の前提条件（`Require`）が成立しなければ、生の出力を保存して、その段の次のデバイス操作（命令の送信、`b`、UF2 の複写）を行わない。ログに `STOPPED before: <行わなかった操作>` が残る。校正が止まっても本番復帰は別に走る。
- 命令の送信の関門は、ポートを開いた子プロセス（`calib-io.ps1`）自身が持つ。子は送信の直前に読んだ dump が `ZDIAG begin` と `ZDIAG end` をそろえ、` #TRUNC` を含まないときだけ 1 文字を書き、`[calib-io] sent 'X'` を刻む。そうでなければ何も書かず `[calib-io] NOT sent 'X': <理由>` を刻んで終了コード 2 で戻る。印は行として判定する（開始行 `(?m)^ZDIAG begin\b`、終了行 `(?m)^ZDIAG end\r?$`。親は `(?m)^ZDIAG end\s*$`）ので、`ZDIAG endBROKEN` のような部分一致は印にならず、子と親の判定がそろう。親は「送信した」を自分の送信要求ではなく子の `sent` の刻印だけで判定し（`Send-Cmd`）、刻印が無ければその段は命令の前で FAIL になる。最初の読み取りが正常で、送信のために開き直した読み取りだけが壊れている場合もここで止まる。
- 本番復帰（`calib-flash.ps1 -Expect prod`）は校正の結果にかかわらず最後に必ず行い、校正とは別に PASS/FAIL を出す。合格の条件: 本番像のファイルが存在し md5 が一致（最初の実機操作の前と複写の直前に確認）→ `b` の受理 → そのシリアルに結びついた UF2 ドライブが 1 つだけ（`Win32_DiskDrive` の `PNPDeviceID` にシリアルを含む USBSTOR ディスク → パーティション → 論理ディスク、かつ `INFO_UF2.TXT` あり）かつ USB 上のブートローダーが 1 台 → 複写がエラーなし（`-ErrorAction Stop`）→ 30 秒以内に UF2 ドライブが消える（像が受け取られた印）→ 90 秒以内に app として戻る → dump が完全（`ZDIAG end` 行あり）で ` #TRUNC` を含まず、`ZDIAG begin version=prof1` で `ZBOOT` 行が 0 本（本番像には `CONFIG_CORON_DIAG_BOOT` が無い。コンソールが出す識別はこれだけ）。
- 手動復旧が必要な状態（app としても boot としても戻らない）になったら、成功扱いにせず、到達した状態とログを保存して止まる（`Require 'device back as app within N s'` の FAIL）。
- デバイスの識別は USB シリアル `B17318CDBE9A61B1` だけ。列挙は `Get-PnpDevice` と CIM のディスク連鎖（`Win32_SerialPort` は使わない）。
- 診断コンソールの特定（`Test-ConsoleIface`）: 同じシリアルを親に持つ Ports のうち、USB インターフェース番号が `MI_00` のものだけ。根拠: 両像とも `zephyr,console = &board_cdc_acm_uart`（最初の `zephyr,cdc-acm-uart` ノード = cdc_acm インスタンス 0。`zephyr.dts`）、Zephyr の USB デバイススタックは記述子の並び順にインターフェース番号を振る（`usb_descriptor.c` の `usb_fix_descriptor`）、実機では MI_00 だけが `ZDIAG` を返した（試験像は MI_00 のみ、本番像は MI_00 が DTR で dump し、MI_03 = Studio の RPC UART（スニペットの 2 つ目のノード）は無応答）。バス報告の説明は全インターフェースが `coron` で区別に使えない。COM 番号は使わない。他のインターフェースは開かず、何も書かない。
- 試験像は `CONFIG_UART_LINE_CTRL` 無効（`coron_R-bt4.config`。Studio の UART スニペット無しのビルドで CDC は 1 本）なので、`diag_min.c` は DTR を見られず `d` を受けたときだけ dump する。本番像は line control ありで開くだけで dump する。子 `calib-io.ps1` は、診断コンソールと特定したポートを開いて 1.5 秒で dump が無ければ `d`（読み出し要求。状態を変えない）を 1 回送る。この設定差は `.config` とソースから事前に分かるもので、実機の 2 回目の停止（10:48）はスクリプトと模擬に反映し忘れていたことによる。
- UF2 ドライブの照合（`Test-UsbstorSerial`）: USBSTOR のインスタンス ID の末尾 `&N` の直前の要素がシリアル（直前は `\` でも `&` でもよい。実機では `USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B1&0` と、Windows が付ける接頭辞が入る）。部分一致（前後に 1 文字多い、1 文字短い）は拒否。2 つの照合関数は実機と模擬で同じ実装で、`calib-selftest.ps1` が実機から読んだ ID を入力に 15 件を直接検証する（`calib-sim.py` の最初に走る）。
- 事前確認（`-Step pre`）: 基準像、最適化像、本番像の 3 ファイルの存在と md5（基準 df108d7a…、最適化 e1e62efe…、本番 889f3a48…）を最初の実機操作より前に確認し、いま動いている像（通常は本番像 2725423。`b` と `d` のコンソールはあるが `ZBOOT` 行は無い）から完全な dump（`ZDIAG begin`〜`ZDIAG end`、` #TRUNC` なし）が読めることを要求する。`ZBOOT` 行は要求しない。あれば構造を検証して事故記録を含む全行を保存する。試験像固有の確認（タグ、固定アドレス、done=1）は基準像の書き込み後（`calib-flash.ps1 -Expect base`）に行う。
- 読み取り: すべてのシリアル交換の標準出力、標準エラー、終了コード、期限超過の有無を、dump が取れたかにかかわらず保存する。判定に使う dump は全体の構造を検証する（`Validate-Dump`）: `ZDIAG begin`/`ZDIAG end`、` #TRUNC` なし、`ring` と `addr` の全キー、`ring count` が告げる件数ぶんの `inc0`〜`inc(n-1)` がそれぞれ `a/b/entry1/entry2/us1/us2` の全行と全キーを持つこと、そのうち reason=1（BOOT_TIMEOUT）と reason=2（WQ_TIMEOUT）の記録は `fire1`〜`fire4`（例外フレーム、レジスタ、USBD、クロック）の 4 行と全キーも持つこと（`is_incident()` は `boot_done=0` で意図した再起動でない記録（reason=0。起動中の致命的エラーによる再起動など）も事故として保存し、`print_rec` は `fire.exc_return != 0` のときだけ `fire` 行を出すので、その記録には `fire` 行が無い。`fire` 行が一部だけある記録はどの reason でも不正）、`count` を超える `inc` が無いこと、`last`（記録か `none`）と `cur` が `a`〜`us2` の全行を持つこと（`fire` 行は 4 行そろうか 1 行も無いか）。`print_rec` が出す行とキーの一覧がスクリプトの表（`$script:LineKeys`）。欠けた項目は 0 などに置き換えず `FAIL … present` で止め、消去（`c`）の前の読み取りで欠けていれば `c` を送らない。` #TRUNC` を含む出力は保存するが判定に使わない。コンソール文字列の比較はすべて大文字小文字を区別する（`-ceq`/`-cmatch`。PowerShell の既定の `-eq`/`-match` は区別しないので、`calib=h` と `calib=H`、`h` と `H` の命令応答を取り違えない）。
- リセットの観測: 命令を送った子プロセス（`calib-io.ps1`）が「送信」「ポート消失」の時刻を出力に刻み、親は USB の app 離脱を監視し、起動番号（`seq`）の増分を照合する。直接観測（ポート消失か USB 離脱）が無くても、起動番号と事故記録が合えば「未観測」と記録して合格にする（「リセットしなかった」とは区別する）。起動番号の増分: 第 1、4 段は 0、第 2、5 段は 1、第 6、7 段は 2（`b`/`r` の起動 + 仕込みで止まった起動）。
校正命令の応答: コンソールはまず受理判定を `ZDIAG calibrate X rc=0`（受理）か `rc=-16`（前の校正が生きているので拒否）と出し、受理のときだけ開始する。開始後に `ZDIAG calibrate X returned` が出るのは `S`（すぐ）と `H`（約 30 秒後、スピナーの終了の印）だけ。`h` と `G` は開始した瞬間にコンソールのスレッドが止まり、仕掛けのリセットまで何も出ない。`h`/`G` が実行されたことは、自動復帰後の事故記録（`inc`）で確かめる。
出力の行: すべての行は最長値でも 150 文字以内（`diag_boot.c` の `print_rec`）。コンソールの行バッファは 253 文字で、超えた行は末尾が ` #TRUNC` に置き換わる。
| 段 | 操作 | 期待値（スクリプトの判定） |
|---|---|---|
| pre | 3 ファイルの存在と md5、app で完全な dump が読めること（`ZBOOT` 行は任意。あれば保存） | すべて成立。成立しなければ実機操作なしで終了 |
| flash-base | `b` → UF2 ドライブ（シリアル一致、1 つ）に基準像を複写 | 複写エラーなし、ドライブ消失、app に復帰、dump に `ZBOOT` 行、cur tag=bt4-R、addr cur=0x2002c818、done=1 |
| 0 | `d` で読み出して保存 → `c` → `d` | `c` の前に cur tag と addr を確認。`ZDIAG ring cleared`、`ring count=0 slots=6`、seq 不変 |
| 1 | `d` を 5 秒おきに 2 回 | done=1、running>0、probes_run と feeds が増える、seq 不変、ring 不変 |
| 2 | `h` | 前提: done=1、calib_live=0、空き枠あり。`rc=0` が出て `returned` は出ない。復帰後: seq +1、ring count +1、`inc0`: tag=bt4-R、reason=2、calib=h、done=1、pc ∈ `diag_spin_forever`（0x662ea〜）、handler=0、thread = addr の sysq。`last` = 止まった起動（同じ seq、reason=2）。dropped/invalid/reinit 不変 |
| 3 | 実施しない | SKIP（ピンリセットの保持は未検証） |
| 4 | `H` | 前提: calib_live=0。`rc=0` → 約 30 秒無音 → `returned`。ポート消失なし、seq 不変、ring 不変、calib_live=0、feeds が 12 以上増加、cur calib=H |
| 5 | `G` | 前提: calib_live=0（第 4 段のスピナーが終了済み）。`rc=0`、`returned` なし。復帰後: seq +1、ring count +1、`inc1`: reason=2、calib=G、thread = addr の calib、pc ∈ `diag_spin_forever` |
| 6 | `S` → `r` | `S rc=0` と `returned` を確認してから `r`。`ZDIAG reboot`。復帰後: seq +2、ring count +1、`inc2`: reason=1、calib=S、done=0、stage=6、usb=0、seq=前の seq+1、pc ∈ `diag_spin_forever` |
| 7 | `d` で既存事故記録の全行を保存 → `S` → `b` → 最適化像を複写 | `S rc=0`/`returned`、`b` 受理、シリアル一致の UF2 ドライブ 1 つ、ブートローダー 1 台、md5 再確認、複写エラーなし、ドライブ消失、app 復帰。dump: cur tag=bt4A-R、addr cur=0x2002c818、seq +2、ring count +1、`inc0`〜`inc2` の全行が 1 文字も変わらず残る（行の欠落も、大文字小文字の違いも FAIL）、`inc3`: tag=bt4A-R、reason=1、calib=S、done=0、stage=6、seq=前の seq+1、pc ∈ 最適化像の `diag_spin_forever`（0x38a08〜）、reinit=0、dropped/invalid 不変 |
| 8 | `d` で保存 → `c` → `d` | `ring count=0`。本番復帰はこの段に含めない（別スクリプト、上の条件） |
実機での実施（2026-10-08 10:41〜11:04、3 回目で校正 PASS・本番復帰 PASS。1、2 回目が止まった理由と修正は `calib-real-20261008/README.md` と `review6-fixes.md` の「実機初回」。3 回目の子は `d` を MI_03 にも送っていたので、レビュー #13 で送信先を診断コンソールに限定した）。
無人ループの計画と実装（`calib-loop.ps1`、`calib-trial.ps1`）は `loop-plan.md`。実機初回（2026-10-08 15:42〜16:41、書き込み群、スクリプト 9191082）は `loop-real-20261008/`: 対象となる書き込み後の起動 2 回（試行 1、稼働 13.39 分と試行 2、26.34 分）は事故記録 0 件（試行開始 3、`b` 送信 3 は別の段階の分母）、試行 3（17.24 分）は `b` の送信 231 ms 後に読み取り例外（ポートは閉じています）を観測して応答行が届かず、スクリプトの前提（応答行を関門にしていた）で FAIL（実機は `b` のとおりブートローダーに入っていた。像は書いていない）、試行 4、5 は未実施、本番復帰 PASS。応答行を関門にしない修正（校正の同じ 3 か所も）はレビュー待ちで、実機では未実施。
校正の発火は自然発生の件数に数えない。自動復帰で救えない停止（NVIC 優先度 0 まで抑止、TIMER4 準備前、ブートローダー内）は、この計測器では救えない。

### 模擬試験（実機なし。`calib-sim.py`、2026-10-08 20:09〜20:21。記録は `calib-sim20-20261008/`（実機ループ初回の 1 件への対応後。自己試験 15 件 + 校正 46 場面 + 無人ループ 37 場面。ループの場面は `loop-plan.md`）。14:54〜15:03 の 76 場面は `calib-sim18-20261008/`、14:36〜14:45 の 74 場面は `calib-sim17-20261008/`、13:51〜13:59 の 70 場面は `calib-sim16-20261008/`、13:19〜13:27 の 67 場面は `calib-sim15-20261008/`、12:25〜12:32 の 57 場面は `calib-sim14-20261008/`、11:34〜11:41 の 43 場面は `calib-sim13-20261008/`、10:52〜10:58 の 40 場面は `calib-sim12-20261008/`、レビュー #11 時点の 40 場面は `calib-sim11-20261008/`、レビュー #9 時点の 29 場面は `calib-sim9-20261008/`、レビュー #10 時点の 37 場面は `calib-sim10-20261008/`）
`calib-sim.py` が、まず `calib-selftest.ps1`（照合関数の直接検証）を走らせ、次に `gen-scenarios.py` の 83 場面（校正 46、無人ループ 37）をすべて `calib-all.ps1` の全体実行（事前確認 → 基準像 → 第 0〜8 段 → 本番復帰）として流し、各場面の `expect.json`（終了コード、`results:` 行の全段の値、ログに必ず現れる正規表現と現れてはならない正規表現。ファイル名の glob で段を限定できる）と機械的に照合する。1 つでも不一致なら非ゼロで終わる。模擬は USB 状態、UF2 ドライブ、複写結果、ファイルの md5 を差し替え（PnP も CIM も Copy-Item も呼ばない）、コンソールの子プロセス `calib-io.ps1` は実物を起動してポートだけを缶詰（`-MockFile`）に置き換えるので、子の送信の関門、刻印、期限超過時の強制終了がそのまま試験される。異常場面も全体実行なので、「失敗した段の後の段が `not-run`」「それでも復帰が走り別に判定される」が `results:` 行で確かめられる。
03:01 の旧版（`calib-sim.sh`、`calib-sim-20261008/`）は単段実行で期待の照合が無かったので、この版で置き換えた。08:12 の版（29 場面）の初回実行で、旧版では見えなかった欠陥を 1 つ捕まえて直した: 子の刻印 `dump incomplete (no ZDIAG end within 4 s)` に文字列 `ZDIAG end` が含まれ、親の「dump 完了」判定（`-cmatch 'ZDIAG end'`）が刻印に当たって PASS になっていた（`no dump (no ZDIAG begin …)` も同様）。判定を行頭アンカー（`(?m)^ZDIAG end\s*$`）にし、刻印の文言から印の文字列を外した。
83 場面の結果（全部期待どおり。`report.txt`。校正の 46 場面:）
| 場面 | 内容 | 期待（終了コード、結果） | 照合した決め手 |
|---|---|---|---|
| normal | 本番像（`ZBOOT` なし）から始めて基準像の書き込み、第 0〜8 段、本番復帰 | 0。pre/flash-base/0/1/2/4/5/6/7/8 PASS、3 SKIP、restore PASS | pre に `no ZBOOT line`、複写 2 回、`CALIBRATION PASS`、第 2 段 `reset observed directly`、`inc0 evidence: … fire4`、`NOT sent`/`timed out`/` #TRUNC` 行末なし |
| normal-from-test | 試験像に古い事故記録が残った状態から | 0。同上 | pre と第 0 段で `saved ZBOOT inc0 …` |
| trunc | 第 0 段の最初の読み取りに ` #TRUNC` | 1。0=FAIL、以後 not-run、restore PASS | `STOPPED before: send 'c'`、`sent 'c'` なし |
| gate-c | 第 0 段: 最初の読み取りは正常、`c` のために開き直した読み取りに ` #TRUNC` | 1。0=FAIL | 子の `NOT sent 'c': the dump before it has a #TRUNC line`、`STOPPED before: send 'c'`、`[calib-io] sent 'c'` なし |
| gate-h | 第 2 段: `h` のための読み取りに `ZDIAG end` が無い | 1。2=FAIL | `NOT sent 'h': the dump before it is incomplete`、`sent 'h'` なし |
| gate-r | 第 6 段: `S` は送られ、`r` のための読み取りに ` #TRUNC` | 1。6=FAIL | `sent 'S'` あり、`NOT sent 'r'`、`STOPPED before: send 'r'`、`sent 'r'` なし |
| gate-b | 第 7 段: `b` のための読み取りに `ZDIAG end` が無い | 1。7=FAIL | `NOT sent 'b'`、`STOPPED before: send 'b'`、第 7 段に `sent 'b'` も `DEVICE-OP copy` も無し |
| missing-end | 第 1 段の dump に `ZDIAG end` が無い（子の刻印は `dump incomplete (no end mark …)`） | 1。1=FAIL | `FAIL read 1:dump complete` |
| missing-field | 第 1 段の dump に `cur us2` 行が無い | 1。1=FAIL | `FAIL read 1:cur us2 line present`（0 に置き換えない） |
| no-dump | 第 1 段: 子がポートを開けない（標準エラーあり、終了コード 1） | 1。1=FAIL | `[stderr] diagio: access denied`、`exit=1`、`FAIL read 1:dump present` |
| ring-count-mismatch | 第 0 段: `ring count=1` なのに `inc0` が無い | 1。0=FAIL | `FAIL before clear:inc0 present`、`STOPPED before: send 'c'`、`sent 'c'` なし |
| inc-no-regs | 第 2 段: 新しい事故記録に `fire3`/`fire4` が無い | 1。2=FAIL | `FAIL after h:inc0 fire1..fire4 (exception frame, registers, USBD, clocks) present` |
| early-reset | 第 2 段: 親の監視前に切断と復帰が完了（ポート消失の印なし、USB は app のまま、seq +1、事故記録あり） | 0。全段 PASS | `NOTE reset NOT observed directly`（未観測と記録。「リセットしなかった」とは別） |
| no-reset | 第 2 段: `h` の後にリセットが起きない | 1。2=FAIL | `FAIL boot number advanced by 1`、`FAIL inc0 present` |
| foreign-uf2 | 第 7 段: UF2 ドライブが別シリアルのものだけ | 1。7=FAIL | `STOPPED before: copy the alt image`、第 7 段に `DEVICE-OP copy` なし |
| two-uf2 | 第 7 段: 自分のドライブと別シリアルのドライブ（ブートローダー 2 台） | 1。7=FAIL | 同上 |
| copy-fail | 第 7 段: 複写がエラー | 1。7=FAIL | `copy error (mock)`、`FAIL copy raised no error` |
| copy-not-taken | 第 7 段: 複写は通るがドライブが消えない | 1。7=FAIL | `FAIL UF2 drive vanished` |
| prod-missing | 本番像のファイルが無い | 3。pre=FAIL、以後 not-run、restore=FAIL | pre `STOPPED before: nothing (preflight`、復帰 `FAIL prod image exists`、全ログに `DEVICE-OP` も `[calib-io] sent` も `opened` も無し（実機操作ゼロ） |
| prod-md5 | 本番像の md5 不一致 | 3。同上 | `FAIL production image md5`、`FAIL prod image md5`、実機操作ゼロ |
| inc-changed | 第 7 段: 書き込み後、既存記録のタグは同じで PC だけ違う | 1。7=FAIL | `FAIL inc1 kept verbatim` |
| inc-missing-line | 第 7 段: 書き込み後、既存記録の 1 行（`fire4`）が欠落 | 1。7=FAIL | `FAIL after flash:inc2 fire1..fire4 …` |
| inc-case | 第 7 段: 書き込み後、既存記録の `calib=h` が `calib=H` | 1。7=FAIL | `FAIL inc0 kept verbatim`（大文字小文字を区別） |
| prod-still-test | 本番復帰後も `ZBOOT` 行が出る | 2。校正 PASS、restore=FAIL | `FAIL no ZBOOT line` |
| mock-missing | 模擬: `flash-prod.json` が無い | 4。結果なし | `MOCK FILE MISSING/INVALID: flash-prod.json missing`、`STEP pre start`/`FLASH`/`DEVICE-OP`/`[calib-io]` が 1 行も無い（子の起動ゼロ） |
| mock-badjson | 模擬: `flash-base.json` が JSON でない | 4。結果なし | `… flash-base.json invalid`、同上 |
| io-hang | 第 1 段: コンソールの子がポートを開いたまま戻らない（交換の期限 3 秒） | 1。1=FAIL、以後 not-run、restore PASS | `FAIL console child returned within 3s (timed out; killed with its process tree; sent stamp absent)`、`timed_out=True` |
| step-hang | 第 4 段の子スクリプトが戻らない（段の期限 8 秒） | 1。4=TIMEOUT、以後 not-run、restore PASS | `4 did not return within 8s: killed with its process tree`、`step 4 rc=TIMEOUT`、`restore PASS` |
| restore-hang | 本番復帰の子スクリプトが戻らない（期限 8 秒） | 2。校正 PASS、restore=TIMEOUT | `flash-prod did not return within 8s`、`CALIBRATION PASS … | RESTORE FAIL` |
| inc-boot-abort | 試験像に起動中断の事故記録（done=0、reason=0、基本 6 行、`fire` 行なし）が残った状態から | 0。全段 PASS | pre と第 0 段で `saved ZBOOT inc0 us2`、`inc0 reason=0 (boot interrupted …): fire lines not required`、pre と第 0 段に `saved ZBOOT inc0 fire` 行なし |
| inc-partial-fire | 第 0 段: 既存記録に `fire1`/`fire2` だけある | 1。0=FAIL | `FAIL before clear:inc0 fire lines all-or-none`、`sent 'c'` なし |
| gate-endbroken | 第 0 段: `c` のための読み取りの終了行が `ZDIAG endBROKEN` | 1。0=FAIL | 子の `NOT sent 'c': the dump before it is incomplete`、`sent 'c'` なし |
| prod-trunc | 本番復帰後の dump に ` #TRUNC` | 2。校正 PASS、restore=FAIL | `FAIL after flash:no #TRUNC line` |
| kill-fail | 第 1 段: 子が戻らず、終了要求が失敗（模擬: `taskkill` を呼ばず rc=1） | 3。1=5、以後 not-run、restore=not-attempted | `taskkill rc=1`、`termination confirmed=False`、`termination NOT confirmed, pids still alive`、段の `exit 5`、`RESTORE NOT ATTEMPTED`、`NOT restored to the production image`、復帰のログなし |
| kill-linger | 第 4 段の子スクリプトが戻らず、終了要求は 0 を返すが対象が残る（模擬） | 3。4=TIMEOUT-ALIVE、以後 not-run、restore=not-attempted | `taskkill rc=0: (mock) taskkill NOT invoked`、`termination confirmed=False`、`RESTORE NOT ATTEMPTED`、復帰のログなし |
| tree-kill | 第 4 段: 段の期限が来たとき配下の交換用の子がハング中 | 1。4=TIMEOUT、restore PASS | `kill: tree=[<段>,<子>]`（2 つ以上の PID）、`kill: taskkill rc=0`、`termination confirmed=True` |
| restore-kill-linger | 本番復帰の子が戻らず、終了要求が効かない | 2。校正 PASS、restore=TIMEOUT-ALIVE | `restore process not confirmed dead`、`termination confirmed=False` |
| two-ports | 同じシリアルに診断コンソール（COM5、MI_00）と Studio の RPC UART（COM7、MI_03）がある（本番像の形）で全体実行 | 0。全段 PASS | `opened COM5` あり、`opened COM7`/`console COM7`/COM7 への `sent` が 1 行も無い |
| uf2-partial-serial | 第 7 段: UF2 ドライブの ID がシリアルの部分一致（1 文字多い F:、1 文字短い G:）だけ | 1。7=FAIL | `drives of serial=[] all uf2 drives=[F,G]`、`STOPPED before: copy the alt image`、複写なし |
| uf2-noprefix | UF2 ドライブの ID が接頭辞なし（`\<シリアル>&0`）で全体実行 | 0。全段 PASS | `drives of serial=[E]` |
| flash-ack-lost | 基準像の書き込み: `b` の応答行 `ZDIAG bootloader` が届かず、送信後にポートが消える | 0。全段 PASS | `'b' reply: ack line 'ZDIAG bootloader' seen=False, port lost after the send=True`、`PASS bootloader of this serial on USB within 30 s (state=boot)`、`DEVICE-OP copied`、`b acknowledged`/`r acknowledged` なし（`c acknowledged` は第 0、8 段の正当な確認で残る） |
| step6-ack-lost | 第 6 段: `r` の応答行 `ZDIAG reboot` が届かず、送信後にポートが消える | 0。全段 PASS | `'r' reply: ack line 'ZDIAG reboot' seen=False, port lost after the send=True`、`PASS 'r' acted upon … (ack_seen=False port_lost=True state=none)`、`reset observed directly` |
| step7-ack-lost | 第 7 段: `b` の応答行が届かず、送信後にポートが消える | 0。全段 PASS | `'b' reply: … seen=False, port lost after the send=True`、`PASS bootloader of this serial on USB within 30 s (state=boot)`、`DEVICE-OP copied` |
無人ループの 37 場面（`calib-loop.ps1` の全体実行。`loop-plan.md` の表の条件。`results:` 行には事前確認 `pre` が加わる）:
| 場面 | 内容 | 期待（終了コード、結果） | 照合した決め手 |
|---|---|---|---|
| loop-normal | 書き込み群 3 試行（稼働 13、17、26 分）、事象なし。seq 1 の全 dump で reinit=1、以後 0 | 0。全試行 0、restore 0、stop=all-trials-done | 台帳の行（予定と実績の像が一致、seq 1→2→3→4、操作直前の稼働 13.17/17.2/26.2 分）、`up_ms 10000 -> 790000, progress 780000 ms`、`trials started=3, b sent=3, images written=3 (boots after a write), boots observed=3, RUNNING confirmed=3, completed without event=3`、事前確認で本番像の md5 PASS、EVENT 行なし |
| loop-reset-normal | リセット群 2 試行 | 0 | `r sent=2 (boots after a soft reset), boots observed=2, RUNNING confirmed=2, completed without event=2`、`sent 'r'`、複写なし |
| loop-new-incident | 試行 2 の起動後に自然の事故記録（count 0→1） | 10。t2=10、t3 not-run、restore 0 | `EVENT after write: incident records count 0 -> 1`、`saved [natural] ZBOOT inc0 …`（保存が復帰より先）、`LOOP STOPPED ON EVENT \| RESTORE PASS`、試行 3 のログなし |
| loop-dropped | 基準で ring が満杯（6 件の校正の名残）、試行 1 の後に dropped 0→1 | 10。t1=10 | `count 6 -> 6, dropped 0 -> 1`、基準に `calibration artifact` |
| loop-reinit | 試行 1 の起動後（新しい起動）に reinit=1 | 10 | `EVENT after write: the ring was reinitialised in this new boot` |
| loop-reinit-flag-change | 同じ起動（seq 1、基準で reinit=1）なのに稼働終了の dump で reinit=0 | 10 | `EVENT end of dwell: the reinit flag changed within the same boot (1 -> 0)`、`b` を送らない |
| loop-header-cur-mismatch | 基準の dump でヘッダ reinit=1、cur reinit=0 | 1。baseline=1、t1〜t3 not-run、restore 0 | `FAIL baseline:ring header reinit == cur reinit (header=1 cur=0)` |
| loop-prod-missing | 本番像のファイルが無い | 1。pre=1、試行なし、restore=not-needed | `FAIL production image exists`、`RESTORE NOT NEEDED: no device change was started`、`FLASH base start` も `DEVICE-OP` も `sent` も無し |
| loop-alt-md5 | 最適化像の md5 不一致 | 1。同上 | `FAIL alt image md5`、実機操作ゼロ |
| loop-done0 | 起動後の dump が 3 回とも done=0 | 10。t1=10 | `done=0 (RUNNING not reached yet) at read 3 of 3`、`the boot never reported done=1`、`RUNNING confirmed=0`、`TRIAL 1 RESULT OK` なし |
| loop-upms-missing | 稼働終了の dump に `up_ms` が無い | 1。t1=1 | `FAIL end of dwell:up_ms present`、`b` を送らない |
| loop-dwell-short | 稼働 13 分のはずが `up_ms` の進みが 290 秒 | 1 | `FAIL dwell progress within tolerance (progress=290000 want=780000)`、`b` を送らない |
| loop-uptime-regress | 同じ起動で `up_ms` が 10000 → 5000 | 10 | `EVENT end of dwell: up_ms went backwards or stood still`、`b` を送らない |
| loop-result-missing | 試行 1 が終了コード 0 なのに結果ファイルが無い | 1。t1=0、stop=…result file missing… | `result file missing or not JSON`、試行 2 は走らない、`LOOP FAILED \| RESTORE PASS` |
| loop-result-stale | 試行 2 の結果ファイルが試行 1 の番号 | 1。t2=0、stop=…of trial 1, not 2 | `result file not usable … its stages are NOT adopted`、台帳の試行 2 は `stages_source=trial log stamps only`、`op_sent=True image_written_stage=True`（ログの刻印から）、他は unknown。集計は `RUNNING confirmed=1, completed without event=1, stages unknown=1`（2 にしない）、試行 3 は走らない |
| loop-b-sent-timeout | 試行 1: `b` の送信刻印が出た後に通信の子がタイムアウト（終了確認済み） | 1。t1=1、restore 0 | `sent 'b'` あり、`timed out; killed … termination confirmed; sent stamp PRESENT`、`stage op_sent=True`、台帳 `b sent=1, images written=0`、複写なし、試行 2 なし、`LOOP FAILED \| RESTORE PASS` |
| loop-r-sent-timeout | リセット群で同じ | 1 | `sent 'r'`、`r sent=1 (boots after a soft reset), boots observed=0`、復帰 PASS |
| loop-b-sent-timeout-alive | 送信後のタイムアウトで終了未確認 | 3。t1=5、restore=not-attempted | `sent stamp PRESENT`、`op_sent=True`、`b sent=1`、`RESTORE NOT ATTEMPTED`、復帰の起動なし |
| loop-result-noafter | 試行 1 が終了コード 0 で、試行番号と段階はそろうが `after` が無い結果 | 1。t1=0、stop=…after snapshot missing | `result file not usable (after snapshot missing): its stages are NOT adopted`、台帳 `completed without event=0, RUNNING confirmed=0, stages unknown=1`（1 にならない）、`b sent=1, images written=1` はログの刻印から、`LOOP FAILED \| RESTORE PASS` |
| loop-b-send-error | `b` の書き込みの中で子が例外終了（`sent` も `NOT sent` も無し） | 1。t1=1 | `error on COM5 (… inside the write`、`send classification for 'b': unknown`、台帳 `op_sent=unknown`、`b sent=0, …, not sent (child refused)=0, send not attempted=0, op sent unknown=1`、試行 2 なし、復帰 PASS |
| loop-b-not-sent | 子の関門が `b` を拒否（`ZDIAG endBROKEN`） | 1 | `NOT sent 'b'`、`send classification for 'b': False`、`not sent (child refused)=1, send not attempted=0`、`op sent unknown` なし |
| loop-stage-unknown-fail | 複写失敗の結果ファイルの `image_written`/`boot_observed`/`running_confirmed`/`completed` が文字列 `unknown` | 1。t1=1 | 台帳の試行 1 は `stages_source=result file` で各段階が `unknown` のまま（true に変換しない）、集計 `b sent=1, images written=0, boots observed=0, RUNNING confirmed=0, completed without event=0`、復帰 PASS |
| loop-completed-unknown | 終了コード 0 の成功結果で `completed` が文字列 `unknown` | 1。t1=0、stop=…stages.completed is not boolean true (unknown) | 採用前に拒否、`stages_source=trial log stamps only`、`completed without event=0, stages unknown=1`、試行 2 なし、復帰 PASS |
| loop-copy-fail-noresult | 複写が失敗し、結果ファイルも無い | 1。t1=1 | `copy attempt (mock)` と `copy error (mock)` はあるが `DEVICE-OP copied` は無し、台帳 `b sent=1, images written=0`（ログの刻印から）、`stages unknown=1` |
| loop-unexpected-seq | 試行 1 の起動後に seq +2 | 10 | `boot number 1 -> 3, expected +1` |
| loop-left-app | 稼働中（poll 3）に USB が app を離れ、復帰後の dump で seq +1 | 10。t1=10、stop=…left-app-during-dwell (unexpected-boot-count) | `the device left 'app' (state=none) at poll 3; the dwell ends here`（poll 4 以降なし、`end of dwell` なし）、`EVENT after leaving app: boot number 1 -> 2`、`b` は送らない、台帳 `b sent=0, images written=0, …, not sent (child refused)=0, send not attempted=1`、試行 1 の `op_sent=not-attempted` |
| loop-no-response | 書き込み後に app へ戻らない（USB に無い）。復帰も失敗 | 13（11 + 2）。t1=11、restore 1 | `NO EXTERNAL RESPONSE`、`images written=1 (boots after a write), boots observed=0`、復帰 `FAIL device on USB`、`LOOP STOPPED, NO OBSERVATION \| RESTORE FAIL` |
| loop-mid-fail | 試行 1 の複写がエラー | 1。t1=1、restore 0 | `copy error (mock)`、`STOPPED before`、`b sent=1, images written=0`、`LOOP FAILED \| RESTORE PASS` |
| loop-deadline | `-NoNewTrialAfter` が過去 | 0。t1〜t3 not-run、stop=deadline…、restore 0 | `deadline: trial 1`、試行のログなし、`LOOP DONE (no event) \| RESTORE PASS` |
| loop-kill-unconfirmed | 試行 1 が戻らず終了要求が効かない | 3。t1=TIMEOUT-ALIVE、restore=not-attempted | `termination confirmed=False`、`RESTORE NOT ATTEMPTED`、復帰の起動なし |
| loop-restore-fail | 復帰後も `ZBOOT` 行 | 2 | `LOOP DONE (no event) \| RESTORE FAIL` |
| loop-old-calib-records | 基準に校正の名残 2 件（h、G）があり、試行は事象なし | 0 | `saved [calibration artifact] ZBOOT inc1 a`、EVENT 行なし |
| loop-incident-at-baseline | 基準に自然の事故記録 | 10。baseline=10、t1〜t3 not-run、restore 0 | `EVENT baseline: 1 natural incident record`（起源は曖昧と記録） |
| kill-enum-hang | 第 4 段の子が戻らず、終了処理のプロセス列挙が戻らない（模擬: 列挙の前で止まる） | 3。4=TIMEOUT-ALIVE、以後 not-run、restore=not-attempted | `kill: phase=enumerate` まで、`termination confirmed=False: kill helper did not return within 20s (last phase=enumerate)`、`RESTORE NOT ATTEMPTED`、`tree=`/`taskkill rc=` なし、復帰のログなし |
| kill-req-hang | 同上、終了要求が戻らない（模擬: `taskkill` の代わりに止まる） | 3。同上 | `kill: tree=[…]`、`kill: phase=terminate` まで、`… did not return within 20s (last phase=terminate)`、`RESTORE NOT ATTEMPTED`、`taskkill rc=` なし |
| io-kill-req-hang | 第 1 段の交換の子が戻らず、その終了要求が戻らない | 3。1=5、以後 not-run、restore=not-attempted | 第 1 段に `kill helper did not return within 20s (last phase=terminate)`、`exit 5`、`RESTORE NOT ATTEMPTED` |
| loop-b-ack-lost | 試行 2: `b` の応答行が届かず、送信後にポートが消え、ブートローダーが現れる（実機の試行 3 の形） | 0。全試行 0、restore 0 | 試行 2 に `'b' reply: ack line 'ZDIAG bootloader' seen=False, port lost after the send=True`、`PASS bootloader of this serial on USB within 30 s (state=boot)`、`DEVICE-OP copied`、試行 1 は `seen=True`、台帳 `b sent=3, images written=3`、`acknowledged` 行なし、`LOOP DONE (no event) \| RESTORE PASS` |
| loop-r-ack-lost | リセット群の試行 1: `r` の応答行が届かず、送信後にポートが消える | 0 | `'r' reply: ack line 'ZDIAG reboot' seen=False, port lost after the send=True`、`PASS 'r' acted upon … (ack_seen=False port_lost=True state=none)`、`r sent=2 (boots after a soft reset), boots observed=2, RUNNING confirmed=2, completed without event=2` |
| loop-b-no-ack-stays-app | 試行 1: `b` の応答行が届かず、ポートも消えず、実機が app のまま | 1。t1=1、t2 なし、restore 0 | `seen=False, port lost after the send=False`、`FAIL bootloader of this serial on USB within 30 s (state=app)`、`STOPPED before: copy the image to the UF2 drive`、`op_sent=True image_written_stage=False`、`b sent=1, images written=0`、`EVENT` なし、`DEVICE-OP cop` なし |
| loop-r-no-ack-stays-app | リセット群で同じ | 1。t1=1 | `FAIL 'r' acted upon … (ack_seen=False port_lost=False state=app)`、`r sent=1 (boots after a soft reset), boots observed=0`、`EVENT` なし |
手動押下もユーザーの応答待ちも、どの場面にも無い。
