# 証拠の束（Coron 起動停止の調査、計測器 v4、2026-10-07 23:59 作成、2026-10-08 03:03 更新）

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
実行は `tools/coron-diag/calib/` のスクリプト。`calib-all.ps1` が「事前確認 → 基準像の書き込み → 第 0〜8 段（第 3 段は SKIP）→ 本番復帰」を人の操作なしで通し、各段の生のコンソール出力と PASS/FAIL（期待値と実測値）を `stepN-<時刻>.log` に、全体を `summary.log` に残す。
- 第 3 段（ピンリセット 1 回押し）は実施しない。手動操作をこの実行に含めないため SKIP と記録し、PASS にはしない。ピンリセットを挟んだ保持は未検証のまま残す。`r` のソフトリセットをその代わりの合格にはしない。
- FAIL で止まる。各段の前提条件（`Require`）が成立しなければ、生の出力を保存して、その段の次のデバイス操作（命令の送信、`b`、UF2 の複写）を行わない。ログに `STOPPED before: <行わなかった操作>` が残る。校正が止まっても本番復帰は別に走る。
- 本番復帰（`calib-flash.ps1 -Expect prod`）は校正の結果にかかわらず最後に必ず行い、校正とは別に PASS/FAIL を出す。合格の条件: 本番像のファイルが存在し md5 が一致（最初の実機操作の前と複写の直前に確認）→ `b` の受理 → そのシリアルに結びついた UF2 ドライブが 1 つだけ（`Win32_DiskDrive` の `PNPDeviceID` にシリアルを含む USBSTOR ディスク → パーティション → 論理ディスク、かつ `INFO_UF2.TXT` あり）かつ USB 上のブートローダーが 1 台 → 複写がエラーなし（`-ErrorAction Stop`）→ 30 秒以内に UF2 ドライブが消える（像が受け取られた印）→ 90 秒以内に app として戻る → dump が `ZDIAG begin version=prof1` で `ZBOOT` 行が 0 本（本番像には `CONFIG_CORON_DIAG_BOOT` が無い。コンソールが出す識別はこれだけ）。
- 手動復旧が必要な状態（app としても boot としても戻らない）になったら、成功扱いにせず、到達した状態とログを保存して止まる（`Require 'device back as app within N s'` の FAIL）。
- デバイスの識別は USB シリアル `B17318CDBE9A61B1` だけ。列挙は `Get-PnpDevice` と CIM のディスク連鎖（`Win32_SerialPort` は使わない）。
- 事前確認（`-Step pre`）: 基準像、最適化像、本番像の 3 ファイルの存在と md5（基準 df108d7a…、最適化 e1e62efe…、本番 889f3a48…）を最初の実機操作より前に確認する。
- 読み取り: すべてのシリアル交換の標準出力、標準エラー、終了コードを、dump が取れたかにかかわらず保存する。判定に使う dump は `ZDIAG begin`/`ZDIAG end` と `ZBOOT ring`/`addr`/`cur` 行がそろっていることを要求し、欠けた項目は 0 などに置き換えず `FAIL field present` で止める。` #TRUNC` を含む出力は保存するが判定に使わない。
- リセットの観測: 命令を送った子プロセス（`calib-io.ps1`）が「送信」「ポート消失」の時刻を出力に刻み、親は USB の app 離脱を監視し、起動番号（`seq`）の増分を照合する。直接観測（ポート消失か USB 離脱）が無くても、起動番号と事故記録が合えば「未観測」と記録して合格にする（「リセットしなかった」とは区別する）。起動番号の増分: 第 1、4 段は 0、第 2、5 段は 1、第 6、7 段は 2（`b`/`r` の起動 + 仕込みで止まった起動）。
校正命令の応答: コンソールはまず受理判定を `ZDIAG calibrate X rc=0`（受理）か `rc=-16`（前の校正が生きているので拒否）と出し、受理のときだけ開始する。開始後に `ZDIAG calibrate X returned` が出るのは `S`（すぐ）と `H`（約 30 秒後、スピナーの終了の印）だけ。`h` と `G` は開始した瞬間にコンソールのスレッドが止まり、仕掛けのリセットまで何も出ない。`h`/`G` が実行されたことは、自動復帰後の事故記録（`inc`）で確かめる。
出力の行: すべての行は最長値でも 150 文字以内（`diag_boot.c` の `print_rec`）。コンソールの行バッファは 253 文字で、超えた行は末尾が ` #TRUNC` に置き換わる。
| 段 | 操作 | 期待値（スクリプトの判定） |
|---|---|---|
| pre | 3 ファイルの存在と md5、app で dump が読めること | すべて成立。成立しなければ実機操作なしで終了 |
| flash-base | `b` → UF2 ドライブ（シリアル一致、1 つ）に基準像を複写 | 複写エラーなし、ドライブ消失、app に復帰、dump に `ZBOOT` 行、cur tag=bt4-R、addr cur=0x2002c818、done=1 |
| 0 | `d` で読み出して保存 → `c` → `d` | `c` の前に cur tag と addr を確認。`ZDIAG ring cleared`、`ring count=0 slots=6`、seq 不変 |
| 1 | `d` を 5 秒おきに 2 回 | done=1、running>0、probes_run と feeds が増える、seq 不変、ring 不変 |
| 2 | `h` | 前提: done=1、calib_live=0、空き枠あり。`rc=0` が出て `returned` は出ない。復帰後: seq +1、ring count +1、`inc0`: tag=bt4-R、reason=2、calib=h、done=1、pc ∈ `diag_spin_forever`（0x662ea〜）、handler=0、thread = addr の sysq。`last` = 止まった起動（同じ seq、reason=2）。dropped/invalid/reinit 不変 |
| 3 | 実施しない | SKIP（ピンリセットの保持は未検証） |
| 4 | `H` | 前提: calib_live=0。`rc=0` → 約 30 秒無音 → `returned`。ポート消失なし、seq 不変、ring 不変、calib_live=0、feeds が 12 以上増加、cur calib=H |
| 5 | `G` | 前提: calib_live=0（第 4 段のスピナーが終了済み）。`rc=0`、`returned` なし。復帰後: seq +1、ring count +1、`inc1`: reason=2、calib=G、thread = addr の calib、pc ∈ `diag_spin_forever` |
| 6 | `S` → `r` | `S rc=0` と `returned` を確認してから `r`。`ZDIAG reboot`。復帰後: seq +2、ring count +1、`inc2`: reason=1、calib=S、done=0、stage=6、usb=0、seq=前の seq+1、pc ∈ `diag_spin_forever` |
| 7 | `d` で既存事故記録の全行を保存 → `S` → `b` → 最適化像を複写 | `S rc=0`/`returned`、`b` 受理、シリアル一致の UF2 ドライブ 1 つ、ブートローダー 1 台、md5 再確認、複写エラーなし、ドライブ消失、app 復帰。dump: cur tag=bt4A-R、addr cur=0x2002c818、seq +2、ring count +1、`inc0`〜`inc2` の全行が 1 文字も変わらず残る（行の欠落も FAIL）、`inc3`: tag=bt4A-R、reason=1、calib=S、done=0、stage=6、seq=前の seq+1、pc ∈ 最適化像の `diag_spin_forever`（0x38a08〜）、reinit=0、dropped/invalid 不変 |
| 8 | `d` で保存 → `c` → `d` | `ring count=0`。本番復帰はこの段に含めない（別スクリプト、上の条件） |
校正の発火は自然発生の件数に数えない。自動復帰で救えない停止（NVIC 優先度 0 まで抑止、TIMER4 準備前、ブートローダー内）は、この計測器では救えない。

### 模擬試験（実機なし。`calib-sim.sh`、2026-10-08 03:01）
スクリプトは `-Mock <scenario.json>` で USB 状態、コンソール出力、UF2 ドライブ、複写結果、ファイルの md5 を差し替えられる（モックは PnP も CIM も SerialPort も Copy-Item も呼ばない）。場面は `gen-scenarios.py` が作り、ログは `calib-sim-20261008/` に置いた。
| 場面 | 判定 | 行われなかった後続操作 |
|---|---|---|
| 正常（全段、`calib-all.ps1`） | pre/flash-base/0/1/2/4/5/6/7/8 PASS、3 SKIP、restore PASS。全体 `CALIBRATION PASS (step 3 SKIP) / RESTORE PASS` | なし |
| 第 0 段の dump に ` #TRUNC` | FAIL | `c` を送らない（`STOPPED before: send 'c'`） |
| dump に `ZDIAG end` が無い | FAIL | （読むだけの段） |
| 必須項目（cur us2 行）の欠落 | FAIL（`FAIL field present cur.us2.running`、0 に置き換えない） | （読むだけの段） |
| dump が取れない（子プロセスがエラー、標準エラーと終了コードを保存） | FAIL | （読むだけの段） |
| 親の監視前に切断と復帰が完了（ポート消失の印なし、USB は app のまま、seq +1、事故記録あり） | PASS。`NOTE reset NOT observed directly …（unobserved, not 'no reset'）` を記録 | なし |
| `h` の後にリセットが起きない（seq 不変、事故記録なし） | FAIL（3 件） | （以後の段は走らない） |
| UF2 ドライブが別シリアルのもの | FAIL | 複写しない（`STOPPED before: copy the alt image`） |
| 自分のドライブと別シリアルのドライブが同時にある（ブートローダー 2 台） | FAIL | 複写しない |
| 複写がエラー | FAIL（`copy error`） | 以後の確認に進まない |
| 複写は通ったがドライブが消えない（像が受け取られない） | FAIL | 以後の確認に進まない |
| 本番像のファイルが無い／md5 不一致 | pre が FAIL。復帰スクリプト単体でも FAIL | 実機操作なし（`STOPPED before: nothing (preflight)`） |
| 書き込み後、既存事故記録のタグは同じで PC だけ違う | FAIL（`inc1 kept verbatim` が不一致、変わった行をログに出す） | なし（読むだけ） |
| 書き込み後、既存事故記録の 1 行が欠落 | FAIL | なし |
| 本番復帰後も `ZBOOT` 行が出る（本番像になっていない） | restore FAIL | なし |
