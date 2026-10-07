# 証拠の束（Coron 起動停止の調査、計測器 v4、2026-10-07 23:59 作成、2026-10-08 02:19 更新）

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

## 校正（実機。リーダーの許可の後。所要 15 分）
前提: 右手側に `coron_R-bt4.uf2` を `b` 経由で書く。各段で COM の `d` を読む。
校正命令の応答: コンソールはまず受理判定を `ZDIAG calibrate X rc=0`（受理）か `rc=-16`（前の校正が生きているので拒否）と出し、受理のときだけ開始する。開始後に `ZDIAG calibrate X returned` が出るのは `S`（すぐ）と `H`（約 30 秒後、スピナーの終了の印）だけ。`h` と `G` は開始した瞬間にコンソールのスレッドが止まり、仕掛けのリセットまで何も出ない。`h`/`G` が実行されたことは、自動復帰後の事故記録（`inc`）で確かめる。
出力の行: すべての行は最長値でも 150 文字以内（`diag_boot.c` の `print_rec`）。コンソールの行バッファは 253 文字で、超えた行は末尾が ` #TRUNC` に置き換わる。` #TRUNC` の付いた行の値は読まない。
| 段 | 操作 | 期待値 |
|---|---|---|
| 0 | `d` → 出力を保存 → `c` → `d` | 2 回目の `d` で `ring count=0 slots=6 dropped=0 invalid=0 reinit=…`。以後の事故は空の ring に積まれる（枠 6 に対し校正で作るのは 4 件） |
| 1 | 正常起動 | `cur`: done=1、running>0、probes 増加、feeds 増加 |
| 2 | `h` | `rc=0` の行のあと何も出ず、15 秒以内に発火して自動復帰。`inc0`: tag=bt4-R、done=1、reason=2、calib=h、handler=0、pc ∈ `diag_spin_forever`、thread = `k_sys_work_q.thread`（`ZBOOT addr` 行の sysq）。usbd en=1/ec の READY=0 でも B と判定しない。`last` = 止まった起動（同じ seq）、`cur` = 復帰後の起動（seq+1） |
| 3 | ピンリセット 1 回 | ring は不変、`last` = 復帰後の起動（done=1、reason=0）、`cur` = 新しい起動 |
| 4 | `H` | `ZDIAG calibrate H rc=0` の後、約 30 秒コンソールが黙る（スピナーの優先度 12 がコンソールの 14 を止める。feeder の 10 は動く）。その後 `ZDIAG calibrate H returned` が出る。`d`: ring count 不変、`calib_live=0`、`cur.feeds` が約 15 増えている |
| 5 | `G` | 第 4 段の `returned` と `calib_live=0` を見てから送る。`ZDIAG calibrate G rc=0` が出て（これは受理の印。`returned` は出ない）、15 秒以内に発火。`inc1`: reason=2、calib=G、thread = `calib_thread`（`ZBOOT addr` 行の calib）、pc ∈ `diag_spin_forever`。これは「監視の進行が止まった」の例で、ワークキューの停止ではない。`rc=-16` が出たら第 4 段のスピナーがまだ生きている |
| 6 | `S` → `r` | 次の起動が APPLICATION 50 で止まり、20 秒で発火。`inc2`: reason=1、calib=S、done=0、stage=6（APP_EARLY）、usb=0、pc ∈ `diag_spin_forever` |
| 7 | `d` で `cur.seq` を控える → `S` → `b` → `coron_R-bt4-alt.uf2` | `S` の仕込みは `b` の次のアプリ起動（＝書き込み後の最適化像の初回起動）で消費され、その起動が止まり 20 秒で発火する。自動復帰後の最適化像の `d`: `inc0`〜`inc2`（tag=bt4-R）がそのまま残り、`inc3` が tag=bt4A-R、seq=控えた値+1、reason=1、calib=S、done=0、stage=6、pc ∈ 最適化像の `diag_spin_forever`。`dropped`/`invalid`/`reinit` は 0。これがブートローダーと像の切り替えを通して ring が保たれたことの確認。magic と CRC だけでは「領域が読めた」までしか言えない |
| 8 | `c` → `d` | ring count=0。そのあと `b` で本番 2725423 へ戻す |
校正の発火は自然発生の件数に数えない。自動復帰で救えない停止（NVIC 優先度 0 まで抑止、TIMER4 準備前、ブートローダー内）は、この計測器では救えない。
