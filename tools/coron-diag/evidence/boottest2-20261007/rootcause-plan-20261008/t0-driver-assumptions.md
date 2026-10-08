# ブートローダーからの直接ジャンプ時に、アプリのドライバ初期化が入口の周辺レジスタへ置く前提

対象ツリー: `/home/yagu001/zmk-dya-build`（Zephyr 4.1 系、nRF52840）。以下のパスはこのディレクトリからの相対。
ビルド設定: `config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/coron_R-bt4.config`（以下「.config」）。
読むだけの調査で、Web は使っていない。

表記:

- 【引用】: ソースの行から直接言えること。`ファイル:行` を付ける。
- 【推測】: ソースの読みに、ハードウェアや ARM の仕様の理解を足して言うこと。何を足したかを書く。

## 0. 実際に有効な分岐（.config）

| 項目 | 値 | .config の行 |
|---|---|---|
| `CONFIG_CLOCK_CONTROL_NRF` | y | 1661 |
| `CONFIG_CLOCK_CONTROL_NRF_K32SRC_XTAL` | y（RC、SYNTH、EXT は無効） | 1662-1666 |
| `CONFIG_NRFX_CLOCK_LFXO_TWO_STAGE_ENABLED` | y（XTAL 選択で自動的に入る。`zephyr/drivers/clock_control/Kconfig.nrf:36-38`） | 797 |
| `CONFIG_CLOCK_CONTROL_NRF_DRIVER_CALIBRATION` / `K32SRC_RC_CALIBRATION` | 無し（XTAL なので較正は無効） | - |
| `CONFIG_SYSTEM_CLOCK_WAIT_FOR_STABILITY` | y（`NO_WAIT` と `WAIT_FOR_AVAILABILITY` は無効） | 1853-1855 |
| `CONFIG_SYSTEM_CLOCK_INIT_PRIORITY` | 0 | (grep) |
| `CONFIG_CLOCK_CONTROL_INIT_PRIORITY` | 30 | (grep) |
| `CONFIG_NRFX_CLOCK` / `CONFIG_NRFX_POWER` | y / y | (grep) / 813 |
| `CONFIG_NRF_RTC_TIMER` | y、`USER_CHAN_COUNT=0`（RTC1 の CC は 0 番だけ使う） | 325, 1347 |
| `CONFIG_TICKLESS_KERNEL` | y | 281 |
| USB | `CONFIG_USB_DEVICE_STACK=y`、`CONFIG_USB_NRFX=y`（旧スタックの `usb_dc_nrfx.c`）、`CONFIG_NRF_USBD_COMMON=y`。`CONFIG_NRFX_USBD` と `CONFIG_UDC_NRF` は無し | 235, 1862, 1872 |
| `CONFIG_USB_NRFX_ATTACHED_EVENT_DELAY` | 0 | (grep) |
| `CONFIG_USB_DEVICE_INITIALIZE_AT_BOOT` | 無効（USB は ZMK の `zmk_usb_init` が開く） | 39 |
| `CONFIG_ZMK_USB_INIT_PRIORITY` | 96（APPLICATION） | 204 |
| `CONFIG_GPIO_NRFX` / `CONFIG_GPIO_NRFX_INTERRUPT` / `CONFIG_NRFX_GPIOTE` | y / y / y | 1749, 1750, 805 |
| `CONFIG_NRFX_PPI` / `CONFIG_NRFX_GPPI` | 無効 | 814, 808 |
| `CONFIG_ASSERT` | 無効（`NRFX_ASSERT` と `__ASSERT_NO_MSG` は何もしない） | 326 |
| `CONFIG_INIT_ARCH_HW_AT_BOOT` | 無効（Zephyr 側は NVIC を初期化し直さない） | 303 |
| `CONFIG_SOC_RESET_HOOK` | y（`soc_reset_hook` = `SystemInit`。`zephyr/soc/nordic/common/platform_init.ld:8`） | 266 |
| `CONFIG_SYSTEM_WORKQUEUE_PRIORITY` | -1（協調スレッド） | 1530 |
| `CONFIG_ZMK_WATCHDOG_FATAL_DETECT` | y（致命的エラーの処理は zmk-feature-watchdog 側。`config/zmk-config-coron/CMakeLists.txt:5` により `fatal_reboot.c` は入らない） | 557 |
| `CONFIG_BT_LL_SW_SPLIT` | y（Zephyr のソフトウェアコントローラ。MPSL ではない） | 2353 |
| `CONFIG_CORTEX_M_SYSTICK` | 無し（SysTick はシステムタイマーに使わない） | - |
| `CONFIG_NRF52_ANOMALY_132_WORKAROUND` | 無し（nRF52832 だけが既定で有効。`zephyr/soc/nordic/nrf52/Kconfig.defconfig.nrf52832_QFAA:11-13`。errata 132 自体も nRF52832 だけ: `modules/hal/nordic/nrfx/mdk/nrf52_erratas.h:6345-6351`） | - |

## 1. 初期化の順序

| 順 | 段・優先度 | 処理 | 根拠 |
|---|---|---|---|
| 1 | リセット直後（C の前） | `soc_reset_hook` = `SystemInit`。nRF52840 では errata 36 の回避で `NRF_CLOCK->EVENTS_DONE`、`EVENTS_CTTO`、`CTIV` を 0 にする | `zephyr/arch/arm/core/cortex_m/reset.S:101-102`、`modules/hal/nordic/nrfx/mdk/system_nrf52.c:189-192`、適用判定 `nrf52_erratas.h`（errata 36 は 52840 で真） |
| 2 | リセット直後 | 割り込みを BASEPRI で止める。main スレッドへ切り替えるまで解かない | `reset.S:119-125` |
| 3 | `arch_kernel_init` | `SCB->SCR = SEVONPEND`（保留になった割り込みが WFE を起こす設定）。以後ずっとこの値 | `zephyr/arch/arm/include/cortex_m/kernel_arch_func.h:41-46`、`zephyr/arch/arm/core/cortex_m/cpu_idle.c:22-27` |
| 4 | PRE_KERNEL_1, 0 | `nordicsemi_nrf52_init`（DCDC の設定など。CLOCK のイベントには触れない） | `zephyr/soc/nordic/nrf52/soc.c:37-52` |
| 5 | PRE_KERNEL_1, 30 | `clk_init`: POWER_CLOCK の ISR を接続し、`nrfx_clock_init`、`nrfx_clock_enable`（POWER_CLOCK の NVIC を有効化、LFCLKSRC=RC を書く） | `zephyr/drivers/clock_control/clock_control_nrf.c:690-732, 772-775`、`modules/hal/nordic/nrfx/drivers/src/nrfx_clock.c:296-338`、`modules/hal/nordic/nrfx/drivers/include/nrfx_power_clock.h:44-70` |
| 6 | PRE_KERNEL_1, 40 | `gpio_nrfx_init` → `nrfx_gpiote_init`（GPIOTE の NVIC を有効化、EVENTS_PORT を消す） | `zephyr/drivers/gpio/gpio_nrfx.c:483-507, 568-573`、`nrfx_gpiote.c:794-836`、`modules/hal/nordic/nrfx/haly/nrfy_gpiote.h:80-111` |
| 7 | PRE_KERNEL_2, 0 | `sys_clock_driver_init`（RTC1）。最後に `z_nrf_clock_control_lf_on(STABLE)` で LFCLK を起こし、XTAL で回るまで `lfclk_spinwait` で待つ | `zephyr/drivers/timer/nrf_rtc_timer.c:727-772`、`clock_control_nrf.c:503-609` |
| 8 | main スレッドへの切替 | ここで初めて割り込みが開く（`arch_irq_unlock_outlined`）。保留中の割り込みはここで走る | `zephyr/arch/arm/core/cortex_m/thread.c:549-551, 567-574` |
| 9 | POST_KERNEL, 0〜49 | 他ドライバ（割り込みは開いている） | - |
| 10 | POST_KERNEL, 50 | `usb_init`: `nrf_usbd_common_init`、`nrfx_power_init`、`nrfx_power_usbevt_init`（POWER の USB 割り込み許可をいったん消してハンドラを登録）、USB 用ワークキュー起動 | `zephyr/drivers/usb/device/usb_dc_nrfx.c:1883-1934`、`nrfx_power.c:115-145, 326-355` |
| 11 | APPLICATION, 50 | `zmk_ble_init`（以後 BT コントローラが HFCLK を要求・解放する） | `zmk/app/src/ble.c:842` |
| 12 | APPLICATION, 96 | `zmk_usb_init` → `usb_enable` → `usb_dc_attach`: USBD の ISR 接続、`nrfx_power_usbevt_enable`、ケーブルが既にあれば ATTACHED を自作して積む | `zmk/app/src/usb.c:78-91`、`zephyr/subsys/usb/device/usb_device.c:1638`、`usb_dc_nrfx.c:1269-1311` |
| 13 | 以後（usbd_workq、協調スレッド） | ATTACHED → `nrf_usbd_common_enable`（READY を待つ）+ HFXO 要求、POWERED → `nrf_usbd_common_start`（USBD の INTEN、NVIC、プルアップ） | `usb_dc_nrfx.c:671-735`、`nrf_usbd_common.c:995-1020, 1146-1196, 1242-1272` |

## 2. 周辺レジスタごとの前提

列の意味: 「前提」= 初期化がその値であることを当てにしているか（当てにしていないなら「無し」）。「自分で消すか」= 初期化の中で上書き・クリアするか。「違ったとき」= 前提と違う値が残っていたときの挙動の読み。

### CLOCK

| レジスタ | 前提 | 自分で消すか | 違ったとき |
|---|---|---|---|
| LFCLKSTAT | 「止まっている」か「XTAL または RC で回っている」のどちらか。`nrfx_clock_start` は回っていれば源を見て、正しい源ならそのまま START を打ち直す【引用】`nrfx_clock.c:406-412, 279-294, 442, 478, 485` | しない（読むだけ） | 止まっている: 前提どおり。回っている（ブートローダーの STOP がまだ効いていない）: STOP の後に START を打つことになる。その結果 LFCLK が回り続けるか止まるかはソースからは決まらない【推測】。止まった場合、`lfclk_spinwait` は入った時点で XTAL と見えて抜け（`clock_control_nrf.c:536-538`）、その後 RTC1 が数えなくなるのでカーネル時刻が進まない＝**誤動作（タイムアウトが永久に来ない）**【推測】 |
| LFCLKRUN | 0（START 未発行）を想定。1 なら「START 済みで立ち上がり待ち」とみなし、LFCLKSRCCOPY が正しければ START を打たずに戻る【引用】`nrfx_clock.c:413-433` | しない | LFCLKRUN=1 かつ実際には何も起動中でない場合: START が出ない。`lfclk_spinwait` の中の第二段の START（`clock_control_nrf.c:551-566`）は「LFCLKSRC=RC かつ EVENTS_LFCLKSTARTED=1」のときだけ打たれる（LFCLKSRC は `nrfx_clock.c:326` で RC にされている）。EVENTS_LFCLKSTARTED も 0 なら誰も START を打たず、XTAL 待ちのループ（`clock_control_nrf.c:536-567`、上限なし）が抜けない＝**無限待ち**。LFCLKSTOP が LFCLKRUN を 0 に戻すかどうかが分かれ目（不明点 1） |
| LFCLKSRC | 無し。`clk_init` が RC（二段起動の一段目）を書く【引用】`nrfx_clock.c:259-266, 326` | する（上書き）`nrfx_clock.c:326`、`442` | 無害 |
| LFCLKSRCCOPY | LFCLKRUN=1 のときだけ読む【引用】`nrfx_clock.c:416`。`lfclk_spinwait` は AVAILABLE モードでだけ読む（`clock_control_nrf.c:517-519`。STABLE なので通らない） | しない | LFCLKRUN=0 なら読まれない＝無害 |
| HFCLKSTAT / HFCLKRUN | 無し。HF の開始は状態を見ずに EVENTS_HFCLKSTARTED を消して START を打つ【引用】`nrfx_clock.c:448-458, 478, 485-489`。`generic_hfclk_start` が HFCLKSTAT を見るのは BT が既に HF を要求しているときだけ【引用】`clock_control_nrf.c:301-311` | しない | ブートローダーの HFCLKSTOP がまだ効いていなくても、起動時に HF を要求するものはない（BT と USB は APPLICATION 以降）＝無害【推測】 |
| INTENSET（LFCLKSTARTED） | 0 を想定（自分で立てる）。`nrfx_clock_start` が START の後で立てる【引用】`nrfx_clock.c:486-489`（LFCLKRUN=1 の分岐では `424`） | しない（`nrfx_clock_init`/`nrfx_clock_enable` は INTEN に触れない `nrfx_clock.c:296-338`。消すのは ISR の XTAL 段 `792` と、スレッド文脈の `lfclk_spinwait` だけ `clock_control_nrf.c:532-534`。起動時は ISR 文脈扱いなので消さない） | 1 のまま、かつ EVENTS_LFCLKSTARTED=1 が残っていると、`clk_init` の時点から POWER_CLOCK の割り込み線が立つ。EVENTS_LFCLKSTARTED は `nrfx_clock.c:478` で消えるが、NVIC の保留ビットは残る。この保留が `lfclk_spinwait` の WFE を起こさなくする＝**無限待ちの候補**（§3 の A） |
| INTENSET（HFCLKSTARTED） | 0 を想定。HF 開始時に立て（`nrfx_clock.c:488`）、ISR で消す（`762`） | しない | 1 のまま、かつ EVENTS_HFCLKSTARTED=1（ブートローダーが消さない）だと、割り込み線が `clk_init` 以降立ちっぱなし。§3 の A と同じ機構で**無限待ちの候補** |
| INTENSET（DONE/CTTO） | 較正が無効なので扱わない（`nrfx_clock.c:807-832` は `NRFX_CLOCK_CONFIG_LF_CAL_ENABLED` のときだけ） | しない | INTEN が立っていてイベントも立っていれば割り込み線が立つ（ISR は消さないので立ちっぱなし）＝A と同じ機構。EVENTS_DONE/CTTO は `SystemInit` が消すので（下行）、実際には起きない【推測】 |
| EVENTS_LFCLKSTARTED | 無し（自分で消してから START）【引用】`nrfx_clock.c:478` | する（LFCLKRUN=0 の通常分岐）`nrfx_clock.c:478`。LFCLKRUN=1 の分岐では消さない（`413-433`） | 通常分岐: 無害。LFCLKRUN=1 の分岐: 消されずに残り、`lfclk_spinwait` が「RC が立ち上がった」と読んで XTAL へ切り替えて START を打つ（`clock_control_nrf.c:551-566`）＝結果として起動が進む方向に働く【推測】 |
| EVENTS_HFCLKSTARTED | 無し | しない（HF を開始するときに `nrfx_clock.c:478` で消すが、起動の途中に HF の開始は無い） | ISR は INTEN を見ずにこのイベントを処理する（`nrfx_clock.c:758-773`）。main スレッドへの切替時に POWER_CLOCK の ISR が走ると（LF の XTAL 段の完了で必ず保留されている。下の注）、残ったイベントを「HF が立ち上がった」として処理し、errata 201 の回避用の印 `hfclk_started` を true にする（`764-769`）。上位（`clock_control_nrf.c:616-628`）は HF が STARTING でないので無視する。ところがこの印は `clock_stop`（`nrfx_clock.c:251-256`）でしか false に戻らないため、その後の最初の本物の HFCLKSTARTED が上位へ渡らない（`765`）＝**誤動作**: 汎用の HF の onoff 要求（USB の `hfxo_start` `usb_dc_nrfx.c:543-549`、`clock_control_on` `clock_control_nrf.c:430-446`）が完了通知を受けない。BT コントローラの HF 要求→解放が一度でも先にあれば `clock_stop` で印が戻るので、影響は「BT の最初の解放より前に出た汎用要求」に限られる【推測】。起動そのものは止めない（汎用 HF を同期で待つのは `clock_control_on` の 500 ms 上限付きと BT のテスト用 `lll_hfclock_on_wait` だけ） |
| EVENTS_DONE / EVENTS_CTTO | 無し | する（`SystemInit` の errata 36 回避）`system_nrf52.c:189-192` | 無害 |

注: LF の XTAL 段の完了について。`lfclk_spinwait` は起動時（`k_is_pre_kernel()` が真）には INTEN を消さない（`clock_control_nrf.c:529-534`）。XTAL への切替後の LFCLKSTARTED は INTEN が立ったまま発生し、割り込みが開いた瞬間に POWER_CLOCK の ISR が走る【引用＋推測】。

### POWER

| レジスタ | 前提 | 自分で消すか | 違ったとき |
|---|---|---|---|
| INTENSET（USBDETECTED/USBREMOVED/USBPWRRDY） | 0 を想定。`nrfx_power_usbevt_init` で一度消し（`nrfx_power.c:326-335` → `351-355` → `344-349`）、`usb_dc_attach` で立てる（`usb_dc_nrfx.c:1288`、`nrfx_power.c:337-342`） | する。ただし POST_KERNEL 50 の `usb_init`（`usb_dc_nrfx.c:1921`）になってから | 1 のままだと、割り込みが開く（main スレッドへの切替、`thread.c:549-551`）から `usb_init` までの間、POWER_CLOCK の ISR が USB のイベントを見る。そのときのハンドラ `m_usbevt_handler` は未登録の NULL（`nrfx_power.c:98`、static で 0）。ISR はイベントが立っていれば NULL を呼ぶ（`nrfx_power.c:393-413`。`NRFX_ASSERT` は `CONFIG_ASSERT` 無効で空）＝**致命的エラー**（下の「USB の各イベント」行）。INTEN だけが残りイベントが 0 なら、この区間に新しい USB イベントが起きない限り無害 |
| INTENSET（POFWARN/SLEEPENTER/SLEEPEXIT） | 0 を想定（このビルドではハンドラを登録しない） | しない（`nrfx_power_init` は INTEN に触れない `nrfx_power.c:115-145`。`usbevt_init` が消すのは USB の 3 ビットだけ） | 1 が残り、対応するイベントが起きると、ISR が NULL のハンドラを呼ぶ（`nrfx_power.c:367-391`）＝**致命的エラー**。この区間に限らず、ずっと残る。依頼の前提では USB の 3 ビットだけが残るので、該当しない |
| EVENTS_USBDETECTED / USBREMOVED / USBPWRRDY | 無し | しない（`usbevt_init`/`usbevt_enable` はイベントを消さない `nrfx_power.c:326-342`。消すのは ISR の `nrf_power_event_get_and_clear` だけ `393-413`） | (a) INTEN の USB ビットも 1 なら、入口から POWER_CLOCK の割り込み線が立ちっぱなし。`lfclk_spinwait` の WFE が LF の起動で起きなくなる＝**無限待ちの候補**（§3 の A）。A を抜けても、main への切替で ISR が走ると NULL 呼び出し＝**致命的エラー → 再起動**（§3 の B）。(b) INTEN が 0 なら、`usb_dc_attach` が INTEN を立てた瞬間（`usb_dc_nrfx.c:1288`）に ISR が残りのイベントを処理する。処理順はイベントの発生順ではなく DETECTED → REMOVED → PWRRDY の固定順（`nrfx_power.c:393-413`）。その後 `usb_dc_attach` がケーブル有りなら DETECTED を自作する（`usb_dc_nrfx.c:1299-1308`）。残った PWRRDY だけがあると POWERED が ATTACHED より先に積まれ、`nrf_usbd_common_start` が USBD の ENABLE 前に走る（`usb_dc_nrfx.c:690-700`、`nrf_usbd_common.c:1242-1272`）＝順序の**誤動作**の可能性。本物の USBPWRRDY が ENABLE 後にもう一度来れば立ち直る【推測、不明点 4】 |
| USBREGSTATUS | ケーブル有無の判定にだけ使う（`usb_dc_nrfx.c:1299`、`nrfx_power.h:419-431`） | （読み取り専用） | ブートローダーが USB を使った直後でも VBUSDETECT=1 なら ATTACHED を自作するので、DETECTED のイベントが無くても USBD は ENABLE される。POWERED（`nrf_usbd_common_start`、プルアップ）は USBPWRRDY のイベントでしか起きない（`usb_dc_nrfx.c:517-519, 690-700`）。OUTPUTRDY が既に 1 のまま新しい USBPWRRDY が来ないなら、USB が列挙されない＝**誤動作**（起動は止めない）【推測、不明点 4】 |

### RTC1（システムタイマー）

| レジスタ | 前提 | 自分で消すか | 違ったとき |
|---|---|---|---|
| TASKS（RTC の走行状態） | 止まっていること（PRESCALER を書くため）。init は STOP を打たずに PRESCALER を書く【引用】`nrf_rtc_timer.c:739` | しない（CLEAR と START を打つ `753-754`） | 依頼の前提（STOP 済み）なら無害。走っていた場合、PRESCALER の書き込みはハードウェアに無視される（nRF の RTC の仕様。ソース外の知識）＝刻みが 32768 Hz にならない**誤動作**【推測】 |
| PRESCALER | 無し（0 を書く） | する `nrf_rtc_timer.c:739` | 無害（停止中なら） |
| CC[0] | 無し | する（`compare_set` → `set_alarm` が書く `nrf_rtc_timer.c:764, 358, 283`） | 無害 |
| CC[1..3] | 無し（このビルドは CC[0] だけ使う。`CHAN_COUNT = USER_CHAN_COUNT + 1 = 1` `nrf_rtc_timer.c:23-24`） | しない | 無害（INTEN と EVTEN を消すので何も起こさない `713, 716`） |
| INTENSET | 無し | する: いったん TICK/OVRFLW/COMPARE0-3 を消し（`nrf_rtc_timer.c:703-717, 736`）、COMPARE0 と OVRFLW を立てる（`742, 745`） | 無害 |
| EVTEN | 無し | する（消す `716`。CC0 だけ `set_alarm` で立てる `291`） | 無害 |
| EVENTS_COMPARE[0] | 無し | する（`compare_set` 経由の `set_alarm` が消す `nrf_rtc_timer.c:277-278`） | `742`（INTEN 立て）から `764`（消す）まで割り込み線が立ち、`747` で保留を消してもすぐまた保留になる。`278` でイベントは消えるが NVIC の保留は残る。main への切替で ISR が 1 回空振りする（`process_channel` は target_time が未来なので何もしない `nrf_rtc_timer.c:509-551`）＝無害。ただし RTC1 の保留が `lfclk_spinwait` の間ずっと立つので、§3 の A の「RTC1 による救済の起床」が無くなる【推測】 |
| EVENTS_COMPARE[1..3]、EVENTS_TICK | 無し | しない | INTEN と EVTEN が 0 なので無害 |
| EVENTS_OVRFLW | 0 を想定（消さずに INTEN を立てる） | しない | 1 が残っていると `745` 以降割り込み線が立ち、main への切替で ISR が `overflow_cnt++` をする（`nrf_rtc_timer.c:569-572`）。システム時刻が 2^24 刻み（32768 Hz で 512 秒）先へ飛ぶ。次の `sys_clock_set_timeout` で未通知分が半周以上と判定され（`665-667`）、512 秒分の刻みを一度にカーネルへ通知する（`471-491`）＝**誤動作**（起動直後のタイムアウトがまとめて満了）。起動は止めない【推測】 |
| COUNTER | 無し | する（CLEAR `753`） | 無害 |

### USBD

| レジスタ | 前提 | 自分で消すか | 違ったとき |
|---|---|---|---|
| ENABLE | 0 を想定。ATTACHED で `nrf_usbd_common_enable` が 1 を書き、EVENTCAUSE.READY を上限なしで待つ（`nrf_usbd_common.c:1006-1011`）。errata 223 の回避で最初の 1 回は 0→1 をもう一度やる（`1155-1161`） | する（ATTACHED のとき） | 依頼の前提（0）なら該当しない。1 のまま入った場合に READY がもう一度立つかはソースから決まらない。立たなければ協調スレッド（`usbd_workq`、`CONFIG_SYSTEM_WORKQUEUE_PRIORITY=-1`、`usb_dc_nrfx.c:1923-1926`）が回り続け、プリエンプティブなスレッドがすべて止まる＝**無限待ち**【推測】 |
| EVENTCAUSE | READY ビットだけ前提あり: 待つ前に自分で消す（`nrf_usbd_common.c:1151`） | READY だけする（`1151, 1011`）。他のビットは割り込みで読んだときに消す（`731-734`） | READY: 無害。SUSPEND/RESUME などが残っていると、`nrf_usbd_common_start` が INTEN を立てた後の最初の USBEVENT で処理される（`1080-1083, 740-753`）＝起こりうるのは偽の SUSPEND 通知程度の**誤動作**【推測】 |
| INTEN | 無し（`nrf_usbd_common_start` が全体を書き込む `nrf_usbd_common.c:1265`） | する | 無害 |
| EVENTS_*（USBRESET/EP0SETUP/EPDATA/ENDEP*/USBEVENT/SOF） | 無し | しない（enable と start はイベントを消さない `nrf_usbd_common.c:1146-1196, 1242-1272`） | ブートローダーの残りが、start の後の最初の USBD 割り込みで処理される（`1028-1094`）。偽の USB リセットや SETUP の処理＝**誤動作の可能性**【推測】。USBD の ENABLE=0 の間イベントレジスタが保持されるかは不明（不明点 5） |
| USBPULLUP | 無し（start で 1 を書く `nrf_usbd_common.c:1271`） | する | 無害 |

### GPIOTE（と GPIO）

| レジスタ | 前提 | 自分で消すか | 違ったとき |
|---|---|---|---|
| INTENSET（IN[n]） | 0 を想定 | しない（`nrfy_gpiote_int_init` は `enable=false` で呼ばれ INTEN に触れない `nrfy_gpiote.h:80-111`、`nrfx_gpiote.c:825-829`） | 1 で、かつ EVENTS_IN[n]=1 なら、main への切替で GPIOTE の ISR が走る（NVIC は `nrfy_gpiote.h:104-105` で有効）。ピンにハンドラが無ければ呼ばない（`nrfx_gpiote.c:575-586, 1407-1421`）。全体ハンドラは該当ピンの GPIO コールバックを呼ぶだけ（`gpio_nrfx.c:459-476`）＝無害、またはコールバックがあるピンなら偽の割り込み通知（キー走査の空振り程度） |
| INTENSET（PORT） | 0 を想定 | しない | EVENTS_PORT は消すので（下行）、新しい DETECT が無い限り無害。起きた場合も、ハンドラが無いピンは SENSE を逆にして終わる（`nrfx_gpiote.c:1439-1458, 1482-1522`）＝無害 |
| EVENTS_IN[n] | 無し | しない（`nrfy_gpiote_int_init` のマスクが PORT だけなので IN は消えない `nrfy_gpiote.h:86-91, 373-381`） | 上の IN[n] の行のとおり |
| EVENTS_PORT | 無し | する `nrfy_gpiote.h:93`（`nrfx_gpiote.c:825-829` から） | 無害 |
| CONFIG[n] | 全チャネル空きを想定（制御ブロックだけ初期化 `nrfx_gpiote.c:823, 831-832`） | しない | ブートローダーがチャネルを TASK/EVENT モードで残していれば、そのピンの出力が残る。割り当て時に上書きされる＝起動には無害【推測】 |
| GPIO の LATCH / DETECTMODE / PIN_CNF.SENSE | 無し | しない（DETECTMODE を書くコードはこのツリーの GPIO/GPIOTE ドライバに無い。grep で `nrf_gpio.h:1409` の HAL 関数だけ） | ISR のループは LATCH が消えるまで回る（`nrfx_gpiote.c:1462-1480, 1521`）が、ハンドラの無いピンは SENSE を逆にするので LATCH は消える＝無限ループにはならない【推測】 |

### PPI

| レジスタ | 前提 | 自分で消すか | 違ったとき |
|---|---|---|---|
| CHEN | 起動時に PPI を初期化するドライバは無い（`CONFIG_NRFX_PPI` 無効 .config:814）。BT コントローラは使うチャネルを個別に有効・無効にする（`zephyr/subsys/bluetooth/controller/ll_sw/nordic/hal/nrf5/radio/radio_nrf5_ppi.h:31-33` など）。全チャネルを消すコードは見当たらない（grep） | しない | 残ったチャネルがどのイベントをどのタスクへ繋いでいるか次第＝不明（不明点 6）。依頼の前提に PPI の状態は無い |

### NVIC / SysTick

| 対象 | 前提 | 自分で消すか | 違ったとき |
|---|---|---|---|
| NVIC の有効化 | 全無効を想定（`CONFIG_INIT_ARCH_HW_AT_BOOT` 無効で、Zephyr は消さない）。使う IRQ だけ有効化する（POWER_CLOCK `nrfx_power_clock.h:65-69`、RTC1 `nrf_rtc_timer.c:751`、GPIOTE `nrfy_gpiote.h:105`） | しない | 依頼の前提（全無効）なら無害 |
| NVIC の保留 | 保留なしを想定。RTC1 だけ自分で消す（`nrf_rtc_timer.c:747`）。POWER_CLOCK の保留は消さない（`clk_init` `clock_control_nrf.c:699-715` にも `nrfx_power_clock_irq_init` にも無い） | RTC1 だけ | ブートローダーが保留を消していても、割り込み線が立ったままなら直ちに保留に戻る（Cortex-M の仕様。ソース外）。POWER_CLOCK については §3 の A |
| SysTick | 使わない（`CONFIG_CORTEX_M_SYSTICK` 無し） | - | CTRL=0 は無害 |

## 3. 「禁止条件」の候補（入口でその値だと起動が止まりうる、とソースから言えるもの）

### A. POWER_CLOCK の割り込み線が `lfclk_spinwait` より前から立っている → PRE_KERNEL_2 で止まる（無限待ち）【推測、根拠行あり】

成り立つ入口の組み合わせ（どれか一つ）:

- POWER.INTEN の USBDETECTED/USBREMOVED/USBPWRRDY のどれかが 1、かつ対応する EVENTS_USB* が 1（依頼の前提では INTEN は残る。イベントの値は不明）
- CLOCK.INTEN の HFCLKSTARTED が 1、かつ EVENTS_HFCLKSTARTED が 1（イベントはブートローダーが消さない。INTEN の値は不明）
- CLOCK.INTEN の LFCLKSTARTED が 1、かつ EVENTS_LFCLKSTARTED が 1（同上。`nrfx_clock.c:478` でイベントは消えるが、保留はそれより前に立つ）

機構:

1. 起動中は BASEPRI で割り込みが止まっている（`reset.S:119-125`）。`clk_init` は POWER_CLOCK の NVIC を有効にするが保留は消さない（`nrfx_power_clock.h:65-69`）。割り込み線が立っていれば NVIC は保留のまま。
2. `lfclk_spinwait` は起動時、`irq_lock` したうえで `k_cpu_atomic_idle` を回し（`clock_control_nrf.c:529-548`）、`k_cpu_atomic_idle` は PRIMASK を立てて WFE で眠る（`cpu_idle.c:107-144`、WFE は `138`）。WFE を起こすのは「割り込みが保留へ移ったこと」（SEVONPEND、`cpu_idle.c:27`）。PRIMASK で止まっている割り込みは起床要因にならない（ARM の仕様。ソース外）。
3. POWER_CLOCK が既に保留なら、RC の LFCLKSTARTED が来ても保留への「移り」が起きず、WFE が起きない。ドライバ自身がこの性質を書いている:「Clear pending interrupt, otherwise new clock event would not wake up from idle.」（`clock_control_nrf.c:560-563`）。ただしこの保留消去は、RC 段のイベントを見つけた後にしか走らない。
4. 他の起床要因は RTC1 の COMPARE0 だけ。CC0 は `compare_set(0, MAX_CYCLES)`（`nrf_rtc_timer.c:761-764`）で約 2^23 刻み＝約 256 秒先【推測: `MAX_TICKS` の計算 `nrf_rtc_timer.c:36-43` と 32768 Hz から】。256 秒後に一度起き、RC 段を処理して XTAL へ切り替え、POWER_CLOCK の保留を消す（`551-566`）。割り込み線は立ったままなので保留が戻り、その移りで WFE が 1 回だけ起きる。XTAL の起動（数百 ms）より先にもう一度眠ると、今度は POWER_CLOCK も RTC1（COMPARE0 のイベントが INTEN 付きで残り、保留のまま）も既に保留で、移りが起きる要因が無い。ここで眠り続ける。
5. 例外も起きないので、致命的エラー処理による再起動も起きない。

ここでの「止まる」は、上の 4 の最後の眠りが続く場合に限る。RTC1 の OVRFLW が入口で 1（`nrf_rtc_timer.c:745` で INTEN を立てると線が立つ）の場合は、256 秒後の救済の起床も無くなり、最初の眠りから戻らない。

### B. POWER の USB 割り込み許可が残り、USB イベントが立っている（または起動中に起きる）→ NULL 関数呼び出しで致命的エラー → 再起動【引用】

- 条件: POWER.INTEN の USB ビットが 1（依頼の前提で成立）、かつ割り込みが開いてから（`thread.c:549-551`）`usb_init` の `nrfx_power_usbevt_init`（`usb_dc_nrfx.c:1921`、POST_KERNEL 50）までに、対応する EVENTS_USB* が 1 であること（入口で 1、またはこの区間にケーブルの抜き差しなどで立つ）。
- 機構: 割り込みが開いた瞬間、POWER_CLOCK の ISR は少なくとも 1 回走る（LF の XTAL 段の完了が保留になっている。§2 CLOCK の注）。ISR は先に `nrfx_power_irq_handler` を呼び（`nrfx_power.c:428-432`）、INTEN とイベントが一致した USB イベントについて `m_usbevt_handler` を呼ぶ（`393-413`）。この時点でハンドラは未登録の NULL（`98`、登録は `usb_dc_nrfx.c:1921` → `nrfx_power.c:331-334`）。`NRFX_ASSERT` は `CONFIG_ASSERT` 無効で空（`zephyr/modules/hal_nordic/nrfx/nrfx_glue.h:42`、.config:326）なので、そのまま 0 番地を呼ぶ。Thumb ビットが 0 のアドレスへの分岐なので故障例外になる【推測: Cortex-M の仕様】。
- 結果: 致命的エラー処理へ進む。このビルドでは zmk-feature-watchdog の処理（`CONFIG_ZMK_WATCHDOG_FATAL_DETECT=y`、`config/zmk-config-coron/CMakeLists.txt:3-7` のコメントによると記録して再起動。中身は読んでいない）。止まりはせず、リセットを経て起動し直すはず。リセットで INTEN が 0 に戻るので 2 回目の起動では起きない【推測】。
- A と B は同じ入口条件（USB の INTEN とイベントの両方が 1）で両方成り立つ。その場合は先に A で止まり、A を抜けたときだけ B に進む。

### C. LFCLKRUN=1 のまま LFCLK が実際には止まっていて、EVENTS_LFCLKSTARTED=0 → LF の START が誰からも出ず、XTAL 待ちが終わらない（無限待ち）【引用＋推測】

- 機構: `nrfx_clock_start` は LFCLKSTAT が「止まっている」かつ LFCLKRUN=1 なら「START 済み」とみなす。LFCLKSRCCOPY が XTAL か RC なら、START を打たずに INTEN を立てて戻る（`nrfx_clock.c:413-433`。二段起動では RC も正しい源と数える `282-285`）。`lfclk_spinwait` は XTAL で回るまで上限なしで待ち（`clock_control_nrf.c:536-567`）、自分から START を打つのは「LFCLKSRC=RC かつ EVENTS_LFCLKSTARTED=1」のときだけ（`551-566`）。イベントが 0 なら START は永久に出ない。
- 成り立つかどうかは、ブートローダーの LFCLKSTOP の後に LFCLKRUN が 0 に戻るかで決まる（不明点 1）。戻るなら該当しない。EVENTS_LFCLKSTARTED=1 が残っていれば（依頼の前提ではブートローダーが消さないので、LF を一度起動していれば 1 のはず）この経路でも抜けられる。

### D. （依頼の前提では該当しない）USBD.ENABLE=1 のまま入る → `nrf_usbd_common_enable` が READY を上限なしで待つ

- `nrf_usbd_common.c:1151`（READY を消す）→ `1006`（ENABLE=1）→ `1009-1010`（上限なしの待ち）。既に ENABLE=1 のところへ 1 を書いて READY がもう一度立つかは不明。立たなければ協調スレッドの `usbd_workq` が回り続け、他のプリエンプティブなスレッドが止まる。依頼の前提は ENABLE=0 なので、ここでは候補として挙げるだけ。

## 4. 「無害」と判定できる残留

- CLOCK.EVENTS_LFCLKSTARTED: LF を起動するとき、通常の分岐では START の前に消す（`nrfx_clock.c:478`）。LFCLKRUN=1 の分岐では残るが、`lfclk_spinwait` がそれを使って起動を進める（`clock_control_nrf.c:551-566`）。ただし INTEN の LF ビットも残っている場合は §3 の A。
- CLOCK.EVENTS_DONE / EVENTS_CTTO: `SystemInit` が消す（`system_nrf52.c:189-192`）。較正も無効。
- CLOCK.LFCLKSRC: `clk_init` が RC を書く（`nrfx_clock.c:326`）。
- CLOCK.HFCLKSTAT / HFCLKRUN（HFCLKSTOP がまだ効いていない）: 起動中に HF を参照・要求する処理は無い。
- CLOCK.EVENTS_HFCLKSTARTED は、起動を止める点では無害。ただし §2 のとおり errata 201 の印を立ててしまう**誤動作**がある（INTEN の HF ビットも残っている場合は §3 の A）。
- POWER.INTEN の USB ビットそのもの（イベントが 0 で、その区間に USB イベントが起きない場合）: `usb_init` が消してから立て直す（`nrfx_power.c:330, 353, 344-349` → `usb_dc_nrfx.c:1288`）。
- RTC1 が STOP と CLEAR 済みで、PRESCALER と CC が残る: PRESCALER は 0 を書く（`nrf_rtc_timer.c:739`）、CC0 は書き直す（`283`）、CC1-3 は使わず INTEN と EVTEN も消す（`713, 716`）、COUNTER は CLEAR（`753`）。
- RTC1.EVENTS_COMPARE[0]: `set_alarm` が消す（`nrf_rtc_timer.c:277-278`）。ISR は 1 回空振りするだけ。
- RTC1.EVENTS_TICK、EVENTS_COMPARE[1..3]: INTEN と EVTEN が 0。
- USBD.ENABLE=0: 前提どおり。
- USBD.EVENTCAUSE.READY: 待つ前に消す（`nrf_usbd_common.c:1151`）。
- GPIOTE.EVENTS_PORT: `gpiote_init` が消す（`nrfy_gpiote.h:93`）。GPIOTE の IN の残りイベントは、ハンドラの無いピンでは何も呼ばない（`nrfx_gpiote.c:575-586, 1407-1421`）。
- NVIC 全無効・保留消去: Zephyr は自分で使う IRQ だけ有効にする。
- SysTick の CTRL=0: このビルドは SysTick を使わない。
- nRF52 errata 132（LF の RC を止めた直後に起動すると立ち上がらない）: nRF52832 だけが対象で、nRF52840 では該当しない（`nrf52_erratas.h:6345-6351`、`zephyr/soc/nordic/nrf52/Kconfig:77-94`）。

## 5. 不明点

1. LFCLKSTOP が LFCLKRUN を 0 に戻すか（§3 の C の成否）。ハードウェアの仕様で、ソースからは決まらない。
2. LFCLKSTOP を出してまだ止まりきっていない LFCLK に LFCLKSTART を出したとき、最終的に回り続けるか（§2 の LFCLKSTAT の行）。アプリの `clk_init` までの時間（データのコピー、bss の 0 埋め、PRE_KERNEL_1 の 0〜29）とブートローダーの STOP の完了のどちらが早いか。
3. 入口で POWER の EVENTS_USBDETECTED/USBREMOVED/USBPWRRDY と、CLOCK の INTEN（HF/LF）が実際に何になっているか。§3 の A と B はこの値で成否が決まる。依頼の前提には POWER の INTEN しか無い。実機で入口の値を読めば決着する。
4. USBD を一度 ENABLE してから 0 に戻した後、アプリが再び ENABLE したときに USBPWRRDY が新しく発生するか（USB の電源レギュレーターが USBD の ENABLE に連動するか）。発生しないと POWERED が来ず、USB が列挙されない（起動は止めない）。
5. USBD の ENABLE=0 の間、USBD のイベントレジスタと EVENTCAUSE が保持されるか（§2 の USBD の残りイベント）。
6. ブートローダーが PPI の CHEN を残すか、残すならどのチャネルか。このビルドの起動経路は PPI を初期化しない。
7. §3 の A は、WFE の起床条件に関する ARM の仕様の理解（PRIMASK で止めた割り込みは起床要因にならず、起床要因は「保留への移り」だけ）に依っている。ソース側の裏付けは `clock_control_nrf.c:560-562` のコメントだけ。
8. zmk-feature-watchdog の致命的エラー処理の中身（§3 の B で本当に再起動するか、記録が残るか）は読んでいない。ハードウェアのウォッチドッグを起動時に動かすかも読んでいない（`CONFIG_WATCHDOG` は無効 .config:343）。§3 の A で止まったときにウォッチドッグが救うかはここ次第。
