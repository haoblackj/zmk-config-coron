# 証拠の束（Coron 起動停止の調査、計測器 v3、2026-10-07 23:59 作成、2026-10-08 01:30 更新）

GitHub で読める写しは `haoblackj/zmk-config-coron` の `feat/dya-diagnostics` ブランチ、`tools/coron-diag/`（モジュールのソース）と `tools/coron-diag/evidence/boottest2-20261007/`（この束。ELF と UF2 は大きさの都合で入れず、md5 だけ置く。要るときは渡す）。

## ファイル
- `../coron_R-bt2.{uf2,elf,config}` タグ `bt3-R-10072355`、`../coron_R-bt2-alt.{uf2,elf,config}` タグ `bt3A-R-10072355`（速度最適化、交互書き込み用）。md5 は `md5sums.txt`。
- `../diag_boot.c`（計測器）、`../diag_min.c`（コンソール命令）、`../CMakeLists.txt`、`../Kconfig`、`../boottest*.conf`、`../build-boottest2.sh`（ビルド手順。記録アドレスの一致を出力する）。
- `disasm-net.txt` 例外入口（naked）から記録処理までの逆アセンブル、ベクタ表 27 番の中身、USB READY 待ちと `diag_spin_forever` の PC 範囲、記録領域と主要スレッドのアドレス（像ごと）。
- `bootloader-ram.md` 実機のブートローダー（Seeed 配布の XIAO Sense 版、文字列 0.6.1）の hex から読んだ RAM の静的な使用範囲（.data 0x20008000〜0x20008620、.bss 〜0x2000ce28、初期 SP 0x20040000）と記録領域の位置、第 7 段で照合する項目。`bootloader-ram.txt`（リンカスクリプトだけの旧版）を置き換える。
- `fatal-path.md` 「main スレッドの終了」判定の根拠。この構成の致命的エラー処理（watchdog モジュールの上書き → `sys_reboot`）のソースと両像の逆アセンブル。
- `pnp-raw-1007.txt` Windows の PnP ログの生の行（10/07 15:40〜16:45、Coron のシリアルと BLE HID と VID_0000 に限定）と、不明デバイスのポート。
- `transcript-quotes-1007.md` 10/07 のトランスクリプトの該当行（原文）。
- `config-repo-head.txt`、`west-shas.txt` ビルド時の設定リポジトリと依存の SHA。

## 記録領域（両像で同一。`build-boottest2.sh` が毎回出力する）
| 変数 | アドレス | 大きさ |
|---|---|---|
| `arm_next` | 0x20027400 | 8 |
| `ring` | 0x20027408 | 0x494 |
| `last` | 0x2002789c | 0x120 |
| `cur` | 0x200279bc | 0x120 |
ブートローダーが静的に書く範囲は .data 0x20008000〜0x20008620 と .bss 〜0x2000ce28（配布 hex のリセット処理から。`bootloader-ram.md`）、初期 SP は 0x20040000。記録領域 0x20027400〜0x20027adc はその外で、.bss 上端から約 108 KB、スタック上端から約 100 KB 離れている。ブートローダー実行中のスタックの深さとヒープは静的には分からないので、保持は第 7 段で記録の全項目（tag、seq、reason、calib、stage）を照合して確かめる。前版（同じ配置方針）は 112 周の `b`/UF2 交互書きで magic と CRC が残ったが、それは「領域が読めた」までの確認。像を替えるたびにアドレスの一致を確認する（違えば記録は無効として扱う）。

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
| RUNNING 後に `H`（発火しない） | 1 | NONE(0) | しない |
| 記録の magic/CRC が不正 | - | - | 保存せず `ring.invalid` に数える |
規則: `reason ∈ {1,2}` または（`boot_done==0` かつ `reason≠3`）。「書き込み完了」（CRC 一致）、「起動完了」（boot_done）、「事故」（上の規則）は別の情報。

## 監視
| 監視 | 期限 | 解除／切替の条件 | 期限切れが意味すること |
|---|---|---|---|
| 起動 | 入口から 20 秒 | main スレッドが終了した（`k_thread_join(&z_main_thread, K_NO_WAIT)==0`。join は終了の仕方を区別しない。この構成では致命的エラーが必ず `sys_reboot` に進み、他に `k_thread_abort` の呼び出しが無いので、終了は `main()` が戻った場合に限られる。根拠は `fatal-path.md`。ZMK の `main()` は `settings_load()` の後に戻る）かつ、システムワークキューで最初の probe が走った | 所定の段に到達しなかった |
| ワークキュー | 餌なしで 15 秒 | 餌は優先度 `K_PRIO_PREEMPT(10)` の feeder スレッドが「前回の probe が走った」ときだけ与える（2 秒周期） | 監視処理の進行が止まった（probe が走らない、または feeder 自身が飢えた）。ワークキューの停止とは限らず、PC とスレッドで判断する |
記録する数: probes_submitted、probes_run、feeds、feeder_loops、last_feed_cyc。

## 校正（実機。リーダーの許可の後。所要 10 分）
前提: 右手側に `coron_R-bt2.uf2` を `b` 経由で書く。各段で COM の `d` を読む。
| 段 | 操作 | 期待値 |
|---|---|---|
| 1 | 正常起動 | `cur`: done=1、running>0、probes 増加、feeds 増加。ring count は直前の値 |
| 2 | `h` | 15 秒以内に発火して自動復帰。`inc`: tag=bt3-R、done=1、reason=2、calib=h、handler=0、pc ∈ `diag_spin_forever`（0x66422〜0x66425）、thread = `k_sys_work_q.thread`（ヘッダ行の sysq）。usbd en=1/ec の READY=0 でも B と判定しない。`last` = 止まった起動（同じ seq）、`cur` = 復帰後の起動（seq+1） |
| 3 | ピンリセット 1 回 | ring は不変、`last` = 復帰後の起動（done=1、reason=0）、`cur` = 新しい起動 |
| 4 | `H`、30 秒待つ | 事故は増えない。feeds が増え続ける |
| 5 | `G` | 発火。`inc`: reason=2、calib=G、thread = `calib_thread`、pc ∈ `diag_spin_forever`。これは「監視の進行が止まった」の例で、ワークキューの停止ではない |
| 6 | `S` → `r` | 次の起動が APPLICATION 50 で止まり、20 秒で発火。`inc`: reason=1、calib=S、done=0、stage=6（APP_EARLY）、usb=0、pc ∈ `diag_spin_forever` |
| 7 | `S` を打つ直前に `d` で `cur.seq` を控える → `S` → `b` → `coron_R-bt2-alt.uf2` | `S` の仕込みは `b` の次の起動（＝書き込み後の最適化像の初回起動）で消費され、その起動が APPLICATION 50 で止まり 20 秒で発火する。自動復帰後の最適化像の `d` で `inc` が 1 件増え、全項目が一致すること: tag=bt3A-R（止まったのは最適化像）、seq=控えた値+1（`b` の起動の次）、reason=1、calib=S、done=0、stage=6、pc ∈ 最適化像の `diag_spin_forever`（0x389b4〜）。`dropped`/`invalid` は増えない。これがブートローダーと像の切り替えを通して ring（`b` 前の事故も含む）が保たれたことの確認。magic と CRC だけでは「領域が読めた」までしか言えない |
| 8 | `c` | ring count=0。そのあと `b` で本番 2725423 へ戻す |
校正の発火は自然発生の件数に数えない。自動復帰で救えない停止（IRQ 抑止、TIMER4 準備前、ブートローダー内）は、この計測器では救えない。
