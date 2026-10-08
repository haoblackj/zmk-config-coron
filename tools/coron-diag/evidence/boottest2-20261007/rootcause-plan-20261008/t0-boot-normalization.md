# リセットハンドラから `board_early_init_hook()` までに正規化されるレジスタ（coron_R bt4 像）

対象: `/home/yagu001/zmk-dya-build`（Zephyr 4.1 系、HEAD `10ba6d0cb`）、nRF52840 / Cortex-M4F、ボード `xiao_ble/nrf52840/zmk`。
設定: `config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/coron_R-bt4.config`
（`.build/R-bt4/zephyr/.config` と `cmp` で同一。以下「config:行」はこのファイルの行）。
ソースに加えて、同じ設定でビルド済みの `.build/R-bt4/zephyr/zmk.elf` を逆アセンブルし、実際に入っている分岐を確かめた（「ELF:アドレス」で示す）。

表記: **[引用]** = ソースか逆アセンブルにそのまま書いてあること。**[推測]** = そこからの推論、またはアーキテクチャ仕様からの推論。

---

## 0. 効いている設定（実際に走る分岐を決めるもの）

| 設定 | 値 | config:行 | 効き目 |
|---|---|---|---|
| `CONFIG_SOC_RESET_HOOK` | y | 266 | reset.S が `bl soc_reset_hook`。実体は `SystemInit`（下記） |
| `CONFIG_INIT_ARCH_HW_AT_BOOT` | **未設定** | 303 | CONTROL のクリア、MPU 無効化、`z_arm_init_arch_hw_at_boot`（PRIMASK/FAULTMASK/NVIC ICER/ICPR の全消去）が**すべて走らない** |
| `CONFIG_SOC_PREP_HOOK` | 未設定 | 1629 | `z_prep_c` 冒頭のフックなし |
| `CONFIG_SOC_EARLY_INIT_HOOK` | 未設定 | 1630 | `soc_early_init_hook` なし |
| `CONFIG_BOARD_EARLY_INIT_HOOK` | y | 1633 | `board_early_init_hook` が呼ばれる（実体は `config/zmk-config-coron/tools/coron-diag/src/diag_boot.c:407`） |
| `CONFIG_ARMV7_M_ARMV8_M_MAINLINE` | y | 1393 | 割り込みマスクは `cpsid i` ではなく BASEPRI |
| `CONFIG_FPU` / `CONFIG_FPU_SHARING` | y / y | 236 / 1475 | CPACR=特権のみ、FPCCR=ASPEN\|LSPEN、CONTROL.FPCA のクリアは**省略** |
| `CONFIG_ARM_MPU` / `CONFIG_MPU_STACK_GUARD` / `CONFIG_MEM_ATTR` | y / y / y | 1423 / 1408 / 2585 | `z_arm_mpu_init` と静的領域の設定が `arch_kernel_init` で走る |
| `CONFIG_CORTEX_M_DWT` | 未設定 | 1400 | DWT は Zephyr 側では触らない |
| `CONFIG_NULL_POINTER_EXCEPTION_DETECTION_NONE` | y | 1405 | DWT/MPU による NULL 検出なし |
| `CONFIG_CORTEX_M_SYSTICK` | 未設定（grep で該当なし） | — | SysTick ドライバなし。SysTick の優先度だけ書く |
| `CONFIG_NRF_RTC_TIMER` | y | 325 | システムタイマは RTC1（初期化は PRE_KERNEL_2 = フックより後） |
| `CONFIG_INIT_STACKS` | 未設定 | 297 | 割り込みスタックの 0xaa 塗りなし |
| `CONFIG_PM_S2RAM` / `CONFIG_WDOG_INIT` / `CONFIG_DEBUG_THREAD_INFO` | 未設定 | — | reset.S の該当分岐なし |
| `CONFIG_ARCH_CACHE` / `CONFIG_ARM_CUSTOM_INTERRUPT_CONTROLLER` | 未設定 | — | `z_arm_interrupt_init` を使う。キャッシュ初期化なし |
| `CONFIG_ZERO_LATENCY_IRQS` | 未設定 | 290 | `_EXC_SVC_PRIO` = 0 |
| `CONFIG_GPIO_AS_PINRESET` / `CONFIG_NFCT_PINS_AS_GPIOS`（Kconfig） | 未設定 | 1345 / 1351 | ただし**DT から HAL へ定義が注入される**（下記）ので SystemInit の該当コードは入っている |
| `CONFIG_NRF_APPROTECT_USE_UICR` | y | 1352 | `ENABLE_APPROTECT` なし → UICR の値を APPROTECT.DISABLE へ写す分岐 |
| `CONFIG_NRF_TRACE_PORT` / SWO | 未設定 | 1354 | SystemInit の TRACE/SWO 分岐なし |
| `CONFIG_NRF_ENABLE_ICACHE` | y | 1346 | ただし書くのは PRE_KERNEL_1（フックより後） |
| `CONFIG_NUM_IRQS` | 48 | 261 | NVIC 優先度の初期化は IRQ 0〜47 |
| `CONFIG_FLASH_LOAD_OFFSET` | 0x27000 | 299 | VTOR に書く値 |

DT からの注入 **[引用]**: `zephyr/modules/hal_nordic/nrfx/CMakeLists.txt:170-183` が UICR ノードの `nfct-pins-as-gpios` で `CONFIG_NFCT_PINS_AS_GPIOS`/`NRF_CONFIG_NFCT_PINS_AS_GPIOS`、`gpio-as-nreset` で `CONFIG_GPIO_AS_PINRESET` をコンパイル定義する。この像の `.build/R-bt4/zephyr/zephyr.dts:65-66` に両方ある。ELF の `SystemInit` にも両分岐が入っている（ELF:5c1b0〜5c21e）。

EARLY 段の SYS_INIT **[引用]**: `.build/R-bt4/zephyr/zmk.map:14243-14246` で `__init_EARLY_start = 0x72ac8` と `__init_PRE_KERNEL_1_start = 0x72ac8` が同じ番地。EARLY 段のエントリは 0 件。

`_EXC_IRQ_DEFAULT_PRIO` の値 **[引用]**: `NUM_IRQ_PRIO_BITS` = 3（`zephyr/dts/arm/nordic/nrf52840.dtsi:572`）、`_EXCEPTION_RESERVED_PRIO` = 1（`zephyr/include/zephyr/arch/arm/cortex_m/exception.h:41`、PROGRAMMABLE_FAULT_PRIOS=y は config:1392）、`_IRQ_PRIO_OFFSET` = 1（同:50）、`_EXC_IRQ_DEFAULT_PRIO` = `Z_EXC_PRIO(1)` = `(1<<5)&0xff` = **0x20**（同:20, 53）。ELF:3d5e4 `movs r0,#32` で確認。

---

## 1. 実行順序（リセットハンドラの先頭 → `board_early_init_hook()`）

ブートローダーからのジャンプ先は `z_arm_reset`（= `__start`、ELF:3d5e0）。ベクタ表は `_vector_table` = 0x27000（`zephyr/arch/arm/core/cortex_m/vector_table.S:32-41`。初期 MSP の語 = `z_main_stack + CONFIG_MAIN_STACK_SIZE`（:39）、リセットベクタ = `z_arm_reset`（:41））。初期 MSP にこの語を使うかはブートローダー次第（**[推測]** ハードウェアのリセットベクタ経由でなく直接ジャンプなので、MSP はブートローダーが設定した値のまま入ってくる）。

| # | 何をするか | ファイル:行 | ELF |
|---|---|---|---|
| 1 | `CONFIG_INIT_ARCH_HW_AT_BOOT` が無いので、CONTROL=0、MPU 無効化、MSP 再設定、`z_arm_init_arch_hw_at_boot` は**すべて飛ばす** | `zephyr/arch/arm/core/cortex_m/reset.S:71-83, 105-118` | 3d5e0 で即 `bl SystemInit` |
| 2 | **`SystemInit`**（`soc_reset_hook` の別名）。この時点は**ブートローダーの PRIMASK/BASEPRI/VTOR のまま**で走る | `reset.S:101-103`、別名は `zephyr/soc/nordic/common/platform_init.ld:8` と `zephyr/soc/nordic/common/CMakeLists.txt:7` | 3d5e0 → 5c054（`soc_reset_hook` と `SystemInit` は同番地 0x5c054） |
| 2a | 　errata 36（CLOCK の EVENTS_DONE/EVENTS_CTTO/CTIV を 0） | `modules/hal/nordic/nrfx/mdk/system_nrf52.c:186-194` | 5c062-5c070 |
| 2b | 　errata 66（TEMP の A0-5/B0-5/T0-4 を FICR から） | `system_nrf52.c:215-237` | 5c074-5c0fc |
| 2c | 　errata 98/103/115/120（nRF52840 の版 0x00 = 初期の試作版だけ） | `system_nrf52.c:239-277` | 5c100-5c14c（4つとも同じ判定関数に畳まれている。表 0x80a8f は版 0 だけ 1） |
| 2d | 　errata 136（RESETREAS） | `system_nrf52.c:279-287` | 5c150-5c16c |
| 2e | 　FPU 有効化 CPACR \|= 0xF00000 | `system_nrf52.c:305-312` | 5c170-5c182 |
| 2f | 　APPROTECT（configuration 249: 版 ≥ 0x05 だけ）APPROTECT.DISABLE ← UICR.APPROTECT | `system_nrf52.c:314` → `modules/hal/nordic/nrfx/mdk/system_nrf52_approtect.h:41-59`（:51-56 の分岐） | 5c186-5c1ac |
| 2g | 　NFCPINS: UICR.NFCPINS.PROTECT=1 なら NVMC.CONFIG=Wen → NFCPINS の bit0 を消す → CONFIG=Ren → **`NVIC_SystemReset()`** | `system_nrf52.c:331-339` | 5c1b0-5c1e2 |
| 2h | 　PSELRESET: PSELRESET[0]/[1] のどちらかが未接続なら NVMC.CONFIG=Wen → 両方 18 → CONFIG=Ren → **`NVIC_SystemReset()`** | `system_nrf52.c:344-355` | 5c1e6-5c21e |
| 3 | **割り込みマスク**: `BASEPRI = 0x20`（`cpsid i` は Baseline だけ。PRIMASK は触らない） | `reset.S:120-128`（:124-125） | 3d5e4-3d5e6 |
| 4 | PSP = `z_interrupt_stacks + ISR_STACK_SIZE + MPU_GUARD` = 0x20024480+0x880 = **0x20024d00**、CONTROL \|= SPSEL(bit1)、isb | `reset.S:154-167` | 3d5ea-3d602 |
| 5 | `z_prep_c` へ | `reset.S:174` | 3d606 |
| 6 | `relocate_vector_table`: **VTOR = 0x27000** | `zephyr/arch/arm/core/cortex_m/prep_c.c:54-59, 196` | 3d7b0-3d7c0 |
| 7 | `z_arm_floating_point_init`: CPACR の CP10/CP11 を消してから特権アクセス（0x500000）を立てる、FPCCR = 0xC0000000、FPSCR = 0。CONTROL.FPCA のクリアは FPU_SHARING のため**省略** | `prep_c.c:81-177`（:89, :101, :132, :149, 省略は :172-176）、呼び出し :197-199 | 3d7c4-3d7ee |
| 8 | **RAM 初期化**: `z_bss_zero`（.bss 0x20002698 から 0x1bc31 バイト） | `prep_c.c:200` → `zephyr/kernel/init.c:219-250` | 3d7f2 |
| 9 | **RAM 初期化**: `z_data_copy`（.data 0x20000000 から 0x1d4a バイトを flash 0x80f7c から） | `prep_c.c:201` → `zephyr/kernel/xip.c:26` | 3d7f6 |
| 10 | `z_arm_interrupt_init`: NVIC IPR[0..47] = 0x20 | `prep_c.c:206` → `zephyr/arch/arm/core/cortex_m/irq_init.c:26-33` | 3d7fa → 3d978 |
| 11 | `z_cstart` へ | `prep_c.c:215` | 3d7fe |
| 12 | `gcov_static_init`（空）、`z_sys_init_run_level(INIT_LEVEL_EARLY)`（**0 件**） | `zephyr/kernel/init.c:752-755` | 6007e-60080 |
| 13 | `arch_kernel_init`（インライン展開） | `init.c:758` → `zephyr/arch/arm/include/cortex_m/kernel_arch_func.h:41-62` | 60084-600ca |
| 13a | 　`z_arm_interrupt_stack_setup`: **MSP = 0x20024d00**、CCR \|= STKALIGN | `zephyr/arch/arm/include/cortex_m/stack.h:39-63`（:44, :60） | 60084-60094 |
| 13b | 　`z_arm_exc_setup`: SHPR（PendSV=0xE0、SVCall=0、MemManage/BusFault/UsageFault=0、DebugMonitor=0、SysTick=0※）、SHCSR \|= USG/BUS/MEMFAULTENA | `zephyr/arch/arm/include/cortex_m/exception.h:144-206` | 60098-600b2 |
| 13c | 　`z_arm_fault_init`: CCR \|= DIV_0_TRP、CCR &= ~UNALIGN_TRP | `zephyr/arch/arm/core/cortex_m/fault.c:1090-1121` | 600b6 → 3d5b4 |
| 13d | 　`z_arm_cpu_idle_init`: SCR = SEVONPEND（0x10、代入） | `zephyr/arch/arm/core/cortex_m/cpu_idle.c:25-28` | 600ba → 3d96c |
| 13e | 　`z_arm_clear_faults`: CFSR ← 0xFFFFFFFF、HFSR ← 0xFFFFFFFF（どちらも W1C で全消去） | `exception.h:213-225` | 600be-600c4 |
| 13f | 　`z_arm_mpu_init`: MPU.CTRL=0 → 固定領域（FLASH_0, SRAM_0）→ DT 由来の領域 → 残りの領域を消去 → MPU.CTRL = ENABLE\|PRIVDEFENA | `zephyr/arch/arm/core/mpu/arm_mpu.c:412-474`（:433→:291、:456-458、:464、:470-472、:474→:274）、領域表 `zephyr/arch/arm/core/mpu/arm_mpu_regions.c:12-26` | 600c6 → 3db04 |
| 13g | 　`z_arm_configure_static_mpu_regions`（ramfunc 等の静的領域） | `zephyr/arch/arm/core/mpu/arm_core_mpu.c:130-165` | 600ca |
| 14 | `LOG_CORE_INIT()`（ELF では何も出ていない） | `init.c:760` | — |
| 15 | `z_dummy_thread_init`（RAM の構造体だけ） | `init.c:763` → `zephyr/kernel/thread.c:1128-1153` | 600d2 |
| 16 | `z_device_state_init`（RAM だけ。USERSPACE なしで `k_object_init` は実質空） | `init.c:766` → `zephyr/kernel/device.c:22-27` | 600d6 |
| 17 | `soc_early_init_hook` は無効 | `init.c:768-770` | — |
| 18 | **`board_early_init_hook()`** | `init.c:771-773` | 600da |
| (後) | PRE_KERNEL_1（`nordicsemi_nrf52_init` の ICACHE と DCDC、クロック制御、GPIO など）、PRE_KERNEL_2（RTC1 のシステムタイマ） | `init.c:775, 779`、`zephyr/soc/nordic/nrf52/soc.c:28-52` | 600de-600e6 |

※ SysTick の優先度: `exception.h:204` は `NVIC_SetPriority(SysTick_IRQn, _EXC_IRQ_DEFAULT_PRIO)` で、**すでにシフト済みの 0x20 を渡す**。CMSIS の `__NVIC_SetPriority` がさらに `<< 5` して `& 0xFF` する（`modules/hal/cmsis/CMSIS/Core/Include/core_cm4.h:1814-1824`）ので 0x400 & 0xFF = **0x00**。ELF:6009e 前後の `strb.w r5, [r4, #35]`（r5=0、r4=0xE000ED00 → 0xE000ED23 = SHPR3 の SysTick バイト）で実際に 0 が書かれていることを確認 **[引用]**。意図（BASEPRI で隠れる優先度にする）と結果（最高優先度 0）が食い違う **[推測: Zephyr 側の不具合]**。

---

## 2. レジスタごとの表

列: 書かれるか / 誰が（関数、ファイル:行） / 書く値 / ブートローダーの値がフック時点でそのまま見えるか

### 2.1 CPU コアレジスタ

| レジスタ | 書かれるか | 誰が | 書く値 | 残るか |
|---|---|---|---|---|
| PRIMASK | **いいえ** | （`z_arm_init_arch_hw_at_boot` の `__disable_irq/__enable_irq` は `scb.c:90-152` だが INIT_ARCH_HW_AT_BOOT 無効で走らない。reset.S の `cpsid i` は Baseline だけ `reset.S:121-122`） | — | **残る** |
| BASEPRI | はい | `z_arm_reset`、`reset.S:124-125` | 0x20 | 消える |
| FAULTMASK | **いいえ** | （`scb.c:96` は走らない） | — | **残る**（**[推測]** スレッドモードで FAULTMASK=1 のまま渡すことは通常ない） |
| CONTROL | 一部 | `reset.S:158-161`（読んで SPSEL を OR）。FPCA クリア `prep_c.c:172-176` は FPU_SHARING で省略。全クリア `reset.S:71-75` は走らない | bit1 SPSEL=1。他ビットは保持 | **nPRIV(bit0) は残る**。FPCA(bit2) は **[推測]** `z_prep_c` の `vmsr fpscr`（ELF:3d7ee、ASPEN=1 の後）で 1 になる。ブートローダー値の判別には使えない |
| MSP | はい | `z_arm_interrupt_stack_setup`、`stack.h:44`（ELF:60084-60086） | 0x20024d00 | 消える（SystemInit 実行中まではブートローダーの MSP） |
| PSP | はい | `reset.S:154-157` | 0x20024d00（以後スタックとして使われ下がる） | 消える |
| MSPLIM/PSPLIM | 対象外 | M4 に無い（`CPU_CORTEX_M_HAS_SPLIM` 無し） | — | — |
| FPSCR | はい | `prep_c.c:149` | 0 | 消える |
| 汎用レジスタ r0-r12, LR | はい（コード実行で） | — | — | 消える |

### 2.2 SCB / SysTick / NVIC / FPU / MPU / DWT（コア周辺）

| レジスタ | 書かれるか | 誰が | 書く値 | 残るか |
|---|---|---|---|---|
| VTOR | はい | `relocate_vector_table`、`prep_c.c:56` | 0x00027000 | 消える（SystemInit と BASEPRI 設定の間はブートローダーの VTOR が有効） |
| ICSR | **いいえ** | — | — | **残る**（PENDSVSET/PENDSTSET/ISRPENDING などの保留状態） |
| AIRCR | **いいえ** | （`exception.h:187-189` は ARM_SECURE_FIRMWARE だけ） | — | **残る**（特に PRIGROUP） |
| SCR | はい（代入） | `z_arm_cpu_idle_init`、`cpu_idle.c:27` | 0x10（SEVONPEND のみ。SLEEPDEEP/SLEEPONEXIT は 0 になる） | 消える |
| CCR | 一部（RMW） | `stack.h:60`（STKALIGN \|=）、`fault.c:1094`（DIV_0_TRP \|=）、`fault.c:1119`（UNALIGN_TRP &= ~） | bit9=1, bit4=1, bit3=0 | **他のビットは残る**（NONBASETHRDENA bit0、USERSETMPEND bit1、BFHFNMIGN bit8 など） |
| SHPR1（MemManage/BusFault/UsageFault） | はい | `exception.h:159-161`（ELF:600a0-600a4） | 0x00, 0x00, 0x00 | 消える |
| SHPR2（SVCall） | はい | `exception.h:155`（ELF:6009e） | 0x00 | 消える |
| SHPR3（DebugMonitor / PendSV / SysTick） | はい | `exception.h:165`、`:149`、`:204`（ELF:600a6, 6009a, 600b2） | 0x00 / 0xE0 / **0x00**（上記※） | 消える（予約バイト 0xE000ED21 は書かない） |
| SHCSR | 一部（RMW） | `exception.h:172-173` | \|= 0x00070000（USG/BUS/MEMFAULTENA） | **active/pended ビット（bit0-15）は残る** |
| CFSR | はい（W1C） | `exception.h:218`（ELF:600c2） | 0xFFFFFFFF → 全消去 | 消える |
| HFSR | はい（W1C） | `exception.h:221`（ELF:600c4） | 0xFFFFFFFF → 全消去 | 消える |
| MMFAR / BFAR | **いいえ** | — | — | **残る**（**[推測]** CFSR の VALID ビットが消えるので、値は残っても有効かは判別不能） |
| DFSR | **いいえ** | — | — | 残る |
| SysTick CTRL / LOAD / VAL | **いいえ** | （CORTEX_M_SYSTICK 無効。ドライバなし） | — | **残る** |
| NVIC ISER / ICER（有効化状態） | **いいえ** | （`scb.c:107-109` の ICER 全消去は走らない） | — | **残る**（ブートローダーが有効にした IRQ は有効のまま） |
| NVIC ISPR / ICPR（保留） | **いいえ** | （`scb.c:111-113` は走らない） | — | **残る** |
| NVIC IABR | 読取専用 | — | — | — |
| NVIC IPR[0..47] | はい | `z_arm_interrupt_init`、`irq_init.c:30-32`（ELF:3d978-3d988） | 全バイト 0x20 | 消える（nRF52840 の IRQ は 0〜47 で全部） |
| CPACR | はい | `SystemInit` `system_nrf52.c:309`（\|= 0xF00000）→ `prep_c.c:89, 101`（CP10/11 を消して 0x500000） | CP10/CP11 = 特権のみ（0x00500000）。他ビットは保持 | 消える（CP10/11 部分） |
| FPCCR | はい（代入） | `prep_c.c:132` | 0xC0000000（ASPEN\|LSPEN） | 消える |
| FPCAR | **いいえ** | — | — | 残る（意味のない値） |
| MPU CTRL / RNR / RBAR / RASR | はい | `z_arm_mpu_init`、`arm_mpu.c:433, 456-458, 464, 470-472, 474` と `arm_core_mpu.c:140-143` | CTRL=0 → 領域設定 → CTRL=0x5（ENABLE\|PRIVDEFENA） | 消える |
| DWT（CTRL/CYCCNT/COMP など） | **いいえ**（`board_early_init_hook` に入るまで） | （CORTEX_M_DWT 無効、NULL 検出なし。フック自身が `diag_boot.c:408-410` で DEMCR.TRCENA と CYCCNT を触る） | — | **残る**（フックの先頭で読む場合） |
| CoreDebug DEMCR | **いいえ** | （SWO/TRACE と errata 32 のコードは入っていない） | — | **残る**（フックの 408 行より前に読む場合） |

### 2.3 nRF52840 の周辺

| レジスタ | 書かれるか | 誰が | 書く値 | 残るか |
|---|---|---|---|---|
| CLOCK EVENTS_DONE / EVENTS_CTTO / CTIV（0x4000010C / 0x40000110 / 0x40000538） | はい（nRF52840 なら常に） | `SystemInit` errata 36、`system_nrf52.c:189-193`（ELF:5c062-5c070） | 0 | 消える |
| CLOCK のその他（HFCLKSTAT、LFCLKSTAT、LFCLKSRC、LFCLKSRCCOPY、INTENSET/CLR、EVENTS_HFCLKSTARTED/LFCLKSTARTED、TASKS_*、HFXODEBOUNCE、TRACECONFIG） | **いいえ** | （クロック制御ドライバは PRE_KERNEL_1。`CONFIG_CLOCK_CONTROL_INIT_PRIORITY=30` config:285） | — | **残る**（HFXO/LFCLK が動いているか、どの LF 源か） |
| POWER RESETREAS（0x40000400） | **条件つき** | `SystemInit` errata 136、`system_nrf52.c:282-286`（ELF:5c150-5c16c） | RESETPIN(bit0) が立っていたら `~1` を書く（W1C）→ **bit0 以外の全ビットを消す** | RESETPIN=0 なら全ビット残る。RESETPIN=1 なら bit0 だけ残り、他（DOG/SREQ/LOCKUP/OFF/LPCOMP/DIF/NFC/VBUS）は消える |
| POWER INTENSET/CLR | **いいえ** | （nrfx POWER/クロックの初期化は後） | — | **残る** |
| POWER EVENTS_USBDETECTED / USBREMOVED / USBPWRRDY、USBREGSTATUS | **いいえ** | — | — | **残る** |
| POWER EVENTS_POFWARN / SLEEPENTER / SLEEPEXIT、POFCON | **いいえ** | — | — | 残る |
| POWER DCDCEN / DCDCEN0 | **いいえ**（フックより後） | `nordicsemi_nrf52_init`（`soc.c:35-42`）は `SYS_INIT(..., PRE_KERNEL_1, 0)`（`soc.c:52`） | — | **残る** |
| POWER GPREGRET / GPREGRET2 | **いいえ** | （retained_mem / reboot 種別の処理は後） | — | **残る** |
| POWER RAM[n].POWER | **いいえ** | — | — | 残る |
| POWER 0x40000EE4（未公開、RAM 関連） | 条件つき（版 0x00 のみ） | errata 115 `system_nrf52.c:266-268`（ELF:5c11c-5c13c） | 下位4ビットを FICR から | 実機の版では **[推測]** 残る |
| APPROTECT.DISABLE（0x40000558） | 条件つき（版 ≥ 0x05） | `system_nrf52_approtect.h:51-56`（ELF:5c186-5c1ac） | UICR.APPROTECT の値 | 版次第 |
| RTC0 / RTC1 / RTC2 | **いいえ** | （RTC1 は PRE_KERNEL_2 のシステムタイマ） | — | **残る**（COUNTER、PRESCALER、INTEN/EVTEN、CC、TASKS） |
| TIMER0〜TIMER4 | **いいえ** | （フック自身が TIMER4 を使う: `diag_boot.c` 冒頭の説明 :36） | — | **残る** |
| USBD | **いいえ** | — | — | **残る**（ENABLE、USBPULLUP、INTEN、EVENTS） |
| PPI（CHEN、CH[n]、CHG、FORK） | **いいえ** | — | — | **残る** |
| GPIOTE（CONFIG[n]、INTEN、EVENTS） | **いいえ** | （GPIO ドライバは PRE_KERNEL_1 以降） | — | **残る** |
| GPIO P0/P1（OUT、DIR、PIN_CNF、LATCH、DETECTMODE） | **いいえ** | （TRACE ピン設定は無効） | — | **残る** |
| TEMP A0-A5 / B0-B5 / T0-T4 | はい（nRF52840 なら常に） | errata 66 `system_nrf52.c:218-236`（ELF:5c074-5c0fc） | FICR の校正値 | 消える |
| NFCT 0x4000568C | 条件つき（版 0x00） | errata 98 `system_nrf52.c:242-244` | 0x00038148 | 実機では **[推測]** 書かれない |
| CCM MAXPACKETSIZE（0x4000F518） | 条件つき（版 0x00） | errata 103 `system_nrf52.c:250-252` | 0xFB | 同上 |
| QSPI 0x40029640 | 条件つき（版 0x00） | errata 120 `system_nrf52.c:274-276` | 0x200 | 同上 |
| NVMC CONFIG | 条件つき（その場合は直後にリセット） | `system_nrf52.c:333, 336, 347, 352`（ELF:5c1c0, 5c1da, 5c1fe, 5c21a） | Wen → Ren（=0） | 書く経路では `NVIC_SystemReset` で戻ってこないので、フックに来た回は**書かれていない** = 残る |
| NVMC ICACHECNF | **いいえ**（フックより後） | `soc.c:30-33`（PRE_KERNEL_1） | — | **残る** |
| UICR NFCPINS / PSELRESET[0..1] | 条件つき（書いたら直後にリセット） | `system_nrf52.c:331-338, 344-354` | NFCPINS bit0 クリア / 18 | フックに来た回は「もう設定済みで書かなかった」回。UICR は不揮発なのでブートローダーとは無関係 |
| UICR APPROTECT | 読むだけ | `system_nrf52_approtect.h:55` | — | — |
| SystemCoreClock（RAM の変数） | はい（.data） | `z_data_copy` | 64000000 | 消える |

---

## 3. 結論

### 3.1 `board_early_init_hook()` の時点で、ブートローダーの値がそのまま見えるもの（実機で測る価値がある）

コア:
- **PRIMASK**（Mainline では一度も触らない。`cpsid i` は Baseline のみ）
- **FAULTMASK**
- **CONTROL.nPRIV**（bit0）
- **AIRCR**（特に PRIGROUP）
- **ICSR** の保留状態（PENDSVSET、PENDSTSET、VECTPENDING、ISRPENDING）
- **SHCSR の active/pended ビット**（bit0-15。ENA の 3 ビットだけ立てられる）
- **CCR の STKALIGN/DIV_0_TRP/UNALIGN_TRP 以外のビット**
- **NVIC ISER（どの IRQ が有効か）と ISPR（どの IRQ が保留か）** — INIT_ARCH_HW_AT_BOOT が無効なので一切消されない
- **SysTick CTRL/LOAD/VAL**
- **DWT と DEMCR**（フック自身が 408-410 行で書き換えるので、その前に読む必要がある）
- MMFAR/BFAR/DFSR/FPCAR（値は残るが、CFSR/HFSR が消されているので意味づけは弱い）

nRF 周辺:
- **CLOCK**: HFCLKSTAT、LFCLKSTAT、LFCLKSRC、LFCLKSRCCOPY、INTENSET、EVENTS_HFCLKSTARTED/LFCLKSTARTED（errata 36 で消える DONE/CTTO/CTIV を除く）
- **POWER**: INTENSET、EVENTS_USBDETECTED/USBREMOVED/USBPWRRDY、USBREGSTATUS、DCDCEN、GPREGRET/GPREGRET2、POFCON、RAM[n].POWER
- **POWER RESETREAS**: RESETPIN が立っていない回だけ完全に残る（下記の注意）
- **RTC0/RTC1/RTC2、TIMER0〜4、USBD、PPI、GPIOTE、GPIO P0/P1** のすべて
- **NVMC ICACHECNF**（ICACHE 有効化は PRE_KERNEL_1）
- RAM のうち .bss/.data の外（noinit 0x2001e300〜0x2002ab34 のうち割り込みスタックとして使っていない部分、0x2002ab34 から上）

### 3.2 もう正規化されていて、フックで測る意味が無いもの

- BASEPRI（0x20）、MSP（0x20024d00）、PSP（0x20024d00 から下）、CONTROL.SPSEL（1）、CONTROL.FPCA（**[推測]** FP 命令で 1）、FPSCR（0）
- VTOR（0x27000）
- SCR（0x10）、CCR の STKALIGN/DIV_0_TRP/UNALIGN_TRP、SHPR1/2/3 の全優先度、SHCSR の FAULTENA 3 ビット、CFSR（0）、HFSR（0）
- NVIC IPR[0..47]（全部 0x20）
- CPACR の CP10/CP11（0x500000）、FPCCR（0xC0000000）
- MPU の全レジスタ
- CLOCK EVENTS_DONE/EVENTS_CTTO/CTIV（0）、TEMP の校正レジスタ
- RESETREAS のうち、RESETPIN が立っていた回の bit0 以外
- .bss（0）と .data（初期値）の RAM

### 3.3 解釈上の注意

- **RESETREAS**: errata 136 の処理（`system_nrf52.c:282-286`）は「RESETPIN が立っていたら `~RESETPIN` を書く」。RESETREAS は W1C なので、ピンリセットが記録されていると他の原因ビットが全部消える。フックで読む RESETREAS は、RESETPIN=1 のときは「他の原因が無かった」ことの証拠にならない。
- **割り込みの露出**: ブートローダーが NVIC の IRQ を有効のまま、PRIMASK=0 で渡すと、`SystemInit` 実行中（BASEPRI 設定前、VTOR もブートローダーのまま）は IRQ が入りうる。BASEPRI=0x20 の後は IRQ の優先度がすべて 0x20 なのでマスクされる。**[推測]**
- **SysTick と優先度 0**: SysTick の優先度は上記の二重シフトで 0（最高）になり、BASEPRI=0x20 では隠れない。ブートローダーが SysTick を TICKINT 付きで動かしたまま渡すと、Zephyr の SysTick ベクタは `z_arm_exc_spurious`（`vector_table.S:82-88`、`CORTEX_M_SYSTICK_INSTALL_ISR` 無効）なので、PRIMASK=0 ならそこで落ちる。**[推測]** 実機の SysTick CTRL を測る価値がある理由。
- UICR の NFCPINS/PSELRESET を書く経路は `NVIC_SystemReset` で終わるので、フックに到達した回はそれらを書いていない。

---

## 4. 不明点（ソースで確定できなかったもの）

1. **実機の nRF52840 の版**（FICR 0x10000134）。errata 98/103/115/120（版 0x00 だけ）と configuration 249 / APPROTECT.DISABLE（版 ≥ 0x05 だけ、表 ELF:0x80a89）が走るかはこれで決まる。判定は `modules/hal/nordic/nrfx/mdk/nrf52_erratas.h:5304-`（errata 103）と `:13158-`（configuration 249）。
2. **ブートローダーが渡す時点の MSP**。直接ジャンプなのでベクタ表の初期 SP（`vector_table.S:39`）が使われるかはブートローダー次第。Zephyr 側は `z_cstart` まで MSP を直さない（INIT_ARCH_HW_AT_BOOT 無効）ので、SystemInit はブートローダーの MSP 上で走る（SystemInit はスタックに r4/lr を積む: ELF:5c054）。
3. **CONTROL.FPCA の最終値**: `vmsr fpscr` で FPCA が立つのは ARMv7-M の仕様からの推論で、ソースには書かれていない。
4. **ブートローダーの PRIMASK/FAULTMASK/NVIC/SysTick の実際の値**（このツリーの外。Adafruit nRF52 ブートローダー 0.6.1 の `bootloader_util_app_start` 相当と MBR の転送経路を見ないと分からない）。
5. `z_arm_configure_static_mpu_regions` と `mpu_configure_regions_from_dt` が最終的に何個の MPU 領域を使うか（MPU は全部書き換わるという結論には影響しない）。
6. SysTick 優先度が 0 になる件が意図したものか（ソースの意図は `exception.h:196-204` のコメントどおり「カーネルの割り込みより低く」で、結果と食い違う）。
