# main スレッドの終了判定と、致命的エラーの経路（ソースと ELF での確認、2026-10-08 01:10）

## 判定の名前
計測器の `STG_MAIN_DONE` は「main スレッドが終了した」の観測で、「`main()` が正常に戻った」の証明ではない。
`k_thread_join()` は対象スレッドが終了していれば 0 を返し、終了の仕方（戻った、abort された）を区別しない（Zephyr 4.1 の API 定義）。
以下は、この構成で main スレッドが `main()` から戻る以外の経路で終了し得るかの確認。

## 結論
この構成（`bt3-R-10072355`、`bt3A-R-10072355`）では、`k_thread_join(&z_main_thread, K_NO_WAIT) == 0` が成立するのは `main()` が戻った後だけ。
根拠は次の 3 点。いずれもソースと、両像の ELF の逆アセンブルで確認した。
1. 致命的エラーは `z_fatal_error()` から `k_sys_fatal_error_handler()` を呼び、この構成ではその関数が `zmk-feature-watchdog` の実装で置き換えられていて、記録を残したあと `sys_reboot()` → `NVIC_SystemReset()` に進む。戻らないので、`z_fatal_error()` のあとにある `k_thread_abort(thread)`（kernel/fatal.c:177）には到達しない。
2. アプリとモジュール（`zmk/app/src`、`zmk-feature-*`、`zmk-module-*`、`local/`）に `k_thread_abort()` の呼び出しは無い（テストコードのコメントを除く）。
3. `main()` が戻ると、`z_thread_entry()` が `k_thread_abort(k_current_get())` で自分を終了する（lib/os/thread_entry.c:48-50）。これが join が 0 になる唯一の経路。

但し書き:
- `zmk_watchdog_reboot()` には差し替え口（`reboot_override`）があるが、設定する関数 `zmk_watchdog_reboot_set_override()` の呼び出し元はテストコード以外に無い（ツリー全体を grep）。ELF 上でも `reboot_override` は `.bss`（基準像 0x20011710、最適化像 0x20013edc）で、起動時は 0。
- `CONFIG_ASSERT` は無効（`.config` の `# CONFIG_ASSERT is not set`）。`__ASSERT` は何もしない。
- 致命的エラー処理が走れない状況（フォルト中のフォルトによる LOCKUP）はチップのリセット（RESETREAS.LOCKUP）になる。これも「main スレッドが終了して join が 0」にはならない。
- 判定が「正常に戻った」を意味するのは、この構成に限る。`k_sys_fatal_error_handler` を上書きしない構成や `CONFIG_ZMK_WATCHDOG_FATAL_DETECT=n` の構成では、Zephyr 既定の処理（`arch_system_halt()` で停止）になり、やはり abort には進まないが、別途確認が要る。

## ソース（`west-shas.txt` の SHA）

### zephyr/kernel/fatal.c（10ba6d0c）
```c
 37 __weak void k_sys_fatal_error_handler(unsigned int reason,
 38                                       const struct arch_esf *esf)
 39 {
 40         ARG_UNUSED(esf);
 41
 42         LOG_PANIC();
 43         LOG_ERR("Halting system");
 44         arch_system_halt(reason);
 45         CODE_UNREACHABLE;
 46 }
...
119         k_sys_fatal_error_handler(reason, esf);
120
121         /* If the system fatal error handler returns, then kill the faulting
122          * thread; a policy decision was made not to hang the system.
...
177                 k_thread_abort(thread);
```

### zmk-feature-watchdog/src/watchdog_fatal.c（84ad14c6）
```c
 65 void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf) {
 66     struct zmk_watchdog_incident_record rec;
 67     watchdog_fatal_build_record(&rec, reason, esf);
 68
 69     zmk_watchdog_pending_set(&rec);
 70     zmk_watchdog_reboot();
```

### zmk-feature-watchdog/src/watchdog_pending.c
```c
137 void zmk_watchdog_reboot(void) {
138     if (reboot_override) {
139         reboot_override();
140         return;
141     }
142
143     sys_reboot(SYS_REBOOT_WARM);
144 }
```

### zephyr/arch/arm/core/cortex_m/scb.c
```c
 38 void __weak sys_arch_reboot(int type)
 39 {
 40         ARG_UNUSED(type);
 41
 42         NVIC_SystemReset();
 43 }
```

### zephyr/kernel/init.c
```c
564         (void)main();
...
674                                        bg_thread_main,
675                                        NULL, NULL, NULL,
676                                        CONFIG_MAIN_THREAD_PRIORITY,
677                                        K_ESSENTIAL, "main");
```

### zephyr/lib/os/thread_entry.c
```c
 48         entry(p1, p2, p3);
 49
 50         k_thread_abort(k_current_get());
```

### zmk/app/src/main.c（e5c9b691）
`main()` は `settings_subsys_init(); settings_load();` のあと `return 0;`（ディスプレイ無効）。

## ELF（`arm-zephyr-eabi-nm` / `objdump -d`）

### 基準像 `coron_R-bt2.elf`（md5 768fd1f6…）
```
0006625c T k_sys_fatal_error_handler
000318d0 T zmk_watchdog_reboot
0003b2e0 T sys_reboot
0005ffac T z_fatal_error
00060008 t bg_thread_main
00067c5a T main
200099a8 B z_main_thread
20011710 b reboot_override

0006625c <k_sys_fatal_error_handler>:
   6625c:	push	{lr}
   6625e:	sub	sp, #44	; 0x2c
   66260:	mov	r2, r1
   66262:	mov	r1, r0
   66264:	mov	r0, sp
   66266:	bl	31990 <watchdog_fatal_build_record>
   6626a:	mov	r0, sp
   6626c:	bl	31820 <zmk_watchdog_pending_set>
   66270:	bl	318d0 <zmk_watchdog_reboot>
   66274:	add	sp, #44	; 0x2c
   66276:	ldr.w	pc, [sp], #4

000318d0 <zmk_watchdog_reboot>:
   318d0:	push	{r4, lr}
   318d2:	ldr	r3, [pc, #16]	; (318e4) = 0x20011710 (reboot_override)
   318d4:	ldr	r0, [r3, #0]
   318d6:	cbz	r0, 318de
   318d8:	ldmia.w	sp!, {r4, lr}
   318dc:	bx	r0
   318de:	bl	3b2e0 <sys_reboot>
```

### 最適化像 `coron_R-bt2-alt.elf`（md5 238d501b…）
```
00036eb4 T k_sys_fatal_error_handler
00036c78 T zmk_watchdog_reboot
00044dfc T sys_reboot
0007964c T z_fatal_error
000796d0 t bg_thread_main
00042eec T main
2000b720 B z_main_thread
20013edc b reboot_override

00036eb4 <k_sys_fatal_error_handler>:
   36eb4:	push	{lr}
   36eb6:	sub	sp, #44	; 0x2c
   36eb8:	mov	r2, r1
   36eba:	mov	r1, r0
   36ebc:	mov	r0, sp
   36ebe:	bl	36e44 <watchdog_fatal_build_record>
   36ec2:	mov	r0, sp
   36ec4:	bl	36b9c <zmk_watchdog_pending_set>
   36ec8:	bl	36c78 <zmk_watchdog_reboot>
   36ecc:	add	sp, #44	; 0x2c
   36ece:	ldr.w	pc, [sp], #4

00036c78 <zmk_watchdog_reboot>:
   36c78:	ldr	r3, [pc, #12]	; (36c88) = 0x20013edc (reboot_override)
   36c7a:	ldr	r0, [r3, #0]
   36c7c:	cbz	r0, 36c80
   36c7e:	bx	r0
   36c80:	push	{r4, lr}
   36c82:	bl	44dfc <sys_reboot>
```

## `.config`（両像で同じ値）
```
# CONFIG_ASSERT is not set
CONFIG_ASSERT_VERBOSE=y
CONFIG_ZMK_WATCHDOG=y
CONFIG_ZMK_WATCHDOG_FATAL_DETECT=y
CONFIG_ZMK_WATCHDOG_FREEZE_DETECT=y
CONFIG_ZMK_WATCHDOG_FREEZE_TIMEOUT_MS=10000
CONFIG_TASK_WDT=y
CONFIG_TASK_WDT_HW_FALLBACK=y
CONFIG_MAIN_THREAD_PRIORITY=0
CONFIG_SYSTEM_WORKQUEUE_PRIORITY=-1
CONFIG_REBOOT=y
```
`CONFIG_WATCHDOG`（ハードウェア WDT ドライバ）は無効。`TASK_WDT_HW_FALLBACK=y` でも実体のハード WDT は無い。

## 計測器側の表記の訂正
v3 の `diag_boot.c` の `STG_MAIN_DONE` のコメントは「main() returned」と書いていた。v4（2026-10-08 01:43 の像）でコメントと出力名を「main thread exited」「mainexit」に直した。

## v4 像（bt4-R-10080143、bt4A-R-10080143）での確認（2026-10-08 01:46 追記）
- `CONFIG_ZMK_WATCHDOG_FATAL_DETECT=y` のまま（変更なし）。`k_sys_fatal_error_handler` は両像とも `zmk-feature-watchdog/src/watchdog_fatal.c:65` のもの（`objdump -dl`）。上の結論はそのまま成り立つ。
- 設定リポジトリには `src/fatal_reboot.c`（10c183c、2026-10-05 00:53。記録なしで `sys_reboot`）があり、`CMakeLists.txt` が「coron_L/coron_R かつ `CONFIG_ZMK_WATCHDOG_FATAL_DETECT` でないとき」だけ組み込む。v4 では組み込まれない（`build.ninja` に無い）。fatal 検出を切った最初の試みは、この関数と計測器の自前のハンドラの二重定義でリンクに失敗した。
- 変えたのは `CONFIG_ZMK_WATCHDOG_FREEZE_DETECT=n` だけ。freeze 検出は `task_wdt` の期限切れ callback（タイマー ISR 文脈）から `zmk_watchdog_reboot()` → `sys_reboot` に進む別の経路で、main スレッドの終了には関わらない。
