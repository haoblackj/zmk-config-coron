# Adafruit nRF52 Bootloader 0.6.1（97fbda5）の DFU 完了後の出口の状態（調査役の報告、2026-10-08）

## 結論

0.6.1 のソースでは、UF2 書き込み完了後のジャンプは `NVIC_SystemReset()` を通らない。同じ `main()` の中で `bootloader_app_start()` により直接ジャンプする。

- USB: `usb_teardown()` が USBPULLUP=0 / USBD 割り込み無効 / INTENCLR / ENABLE=0 / HFCLKSTOP まで行う。POWER の USB イベント許可を戻す呼び出し（`nrfx_power_usbevt_disable`）は見つからず。
- クロック: LFCLK/HFCLK とも STOP タスクを出すだけで完了待ちなし。`EVENTS_*STARTED` の clear は見つからず。`LFCLKSRC` は RC のまま。
- NVIC: `ICER`/`ICPR` を全ビット書く。優先度と SysTick の保留は戻さない（推測）。`SCB->VTOR` の設定は見つからず。

## 版と取得元

- タグ 0.6.1 = commit 97fbda552d62f6ba2d518143bac19bf35d8b6d27
- tinyusb サブモジュール = af8e5a90f4244bfe1174724b86bc4b73599b932c
- Seeed 配布版（fork）のソースは未確認。以下はすべて Adafruit 本家 0.6.1。
- 取得方法: WebFetch は要約モデルが main.c を省略し不正確だったため、引用は curl で取った生ファイルの行を使った（書き込み・外部送信なし）。

取得した生ファイル:
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/main.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/boards/boards.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/boards/boards.h
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/usb/usb.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/usb/msc_uf2.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/usb/uf2/ghostfat.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/flash_nrf5x.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/src/dfu_init.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/lib/sdk11/components/libraries/bootloader_dfu/bootloader.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/lib/sdk11/components/libraries/bootloader_dfu/bootloader_util.c
- https://raw.githubusercontent.com/adafruit/Adafruit_nRF52_Bootloader/0.6.1/lib/sdk/components/libraries/timer/app_timer.c
- https://raw.githubusercontent.com/hathach/tinyusb/af8e5a90f4244bfe1174724b86bc4b73599b932c/src/portable/nordic/nrf5x/dcd_nrf5x.c
- https://api.github.com/repos/adafruit/Adafruit_nRF52_Bootloader/git/ref/tags/0.6.1 （タグの commit）
- https://api.github.com/repos/adafruit/Adafruit_nRF52_Bootloader/contents/lib/tinyusb?ref=0.6.1 （サブモジュールの sha）

以下、パスは `https://github.com/adafruit/Adafruit_nRF52_Bootloader/blob/0.6.1/` 配下（tinyusb を除く）。

## 1. USB

`src/usb/usb.c` の `usb_teardown()`（108-112 行）。引用:

```c
void usb_teardown(void)
{
  // Simulate an disconnect which cause pullup disable, USB perpheral disable and hclk disable
  tusb_hal_nrf_power_event(NRFX_POWER_USB_EVT_REMOVED);
}
```

実体は tinyusb（sha af8e5a9）`src/portable/nordic/nrf5x/dcd_nrf5x.c` の `tusb_hal_nrf_power_event()`、`USB_EVT_REMOVED`（978-1000 行）。引用:

```c
    case USB_EVT_REMOVED:
      if ( NRF_USBD->ENABLE )
      {
        // Disable pull up
        NRF_USBD->USBPULLUP = 0;
        // Disable Interrupt
        NVIC_DisableIRQ(USBD_IRQn);
        // disable all interrupt
        NRF_USBD->INTENCLR = NRF_USBD->INTEN;
        NRF_USBD->ENABLE = 0;
        hfclk_disable();
        dcd_event_bus_signal(0, DCD_EVENT_UNPLUGGED, is_in_isr());
      }
```

（`__ISB(); __DSB();` と `TU_LOG2` は省略）

- `dcd_disconnect`（291-299 行）は `NRF_USBD->USBPULLUP = 0;` のみ。ジャンプ経路では呼ばれていない（引用: main.c, usb.c の呼び出しに無い）。
- 残る状態（引用）: NRF_USBD は ENABLE=0、プルアップ無効、割り込み無効。
- 残る状態（推測）: POWER の USB イベント許可は残る可能性が高い。`usb_init()`（`src/usb/usb.c` 80-87 行）は `nrfx_power_init(&pwr_cfg);` / `nrfx_power_usbevt_init(&config);` / `nrfx_power_usbevt_enable();` を呼ぶ。`usbevt_disable` は main.c / boards.c / usb.c / bootloader.c に見つからなかった。ケーブル接続中なら `EVENTS_USBDETECTED` 等が立ったままになり得る。
- USB レギュレータ（`USBREGSTATUS`）はハード側の状態で、ソースに操作は見つからず。
- `usb_teardown()` はジャンプ経路でのみ呼ばれる（`main.c` 280 行、`usb_init` を呼んだ場合のみ）。

## 2. クロック

`src/boards/boards.c` `board_init()`。引用:

```c
  // stop LF clock just in case we jump from application without reset
  NRF_CLOCK->TASKS_LFCLKSTOP = 1UL;

  // Use Internal OSC to compatible with all boards
  NRF_CLOCK->LFCLKSRC = CLOCK_LFCLKSRC_SRC_RC;
  NRF_CLOCK->TASKS_LFCLKSTART = 1UL;
```

`board_teardown()`（128-158 行、149-150 行）。引用:

```c
  // Stop LF clock
  NRF_CLOCK->TASKS_LFCLKSTOP = 1UL;
```

完了待ちなし、`LFCLKSRC` は戻さない。

tinyusb `dcd_nrf5x.c` `hfclk_disable()`（816-827 行）。引用:

```c
  nrf_clock_task_trigger(NRF_CLOCK, NRF_CLOCK_TASK_HFCLKSTOP);
```

（SD 有効時は `sd_clock_hfclk_release()`。非 OTA の DFU では SD は有効化されないため上記側）。`hfclk_enable()`（812 行）は開始前に `nrf_clock_event_clear(NRF_CLOCK, NRF_CLOCK_EVENT_HFCLKSTARTED);` を行うだけ。

- `EVENTS_LFCLKSTARTED` / `EVENTS_HFCLKSTARTED` / `LFCLKSTAT` の clear は main.c / boards.c / usb.c / bootloader.c に見つからず。
- 推測: STOP タスクは非同期なので、ジャンプ時点で止まりきっていないか、`*STARTED` イベントが立ったまま。`LFCLKSRC` は RC のまま。

## 3. RTC1 と SysTick

`boards.c` `board_teardown()`（130-147 行）。引用:

```c
  // Disable systick, turn off LEDs
  SysTick->CTRL = 0;
  ...
  // Stop RTC1 used by app_timer
  NVIC_DisableIRQ(RTC1_IRQn);
  NRF_RTC1->EVTENCLR    = RTC_EVTEN_COMPARE0_Msk;
  NRF_RTC1->INTENCLR    = RTC_INTENSET_COMPARE0_Msk;
  NRF_RTC1->TASKS_STOP  = 1;
  NRF_RTC1->TASKS_CLEAR = 1;
```

- RTC1 は app_timer 用（`lib/sdk/components/libraries/timer/app_timer.c` 160-175 行で PRESCALER 設定、`INTENSET`、`NVIC_ClearPendingIRQ`/`NVIC_EnableIRQ`、`TASKS_START`）。`board_init()` が `app_timer_init();` と `NVIC_SetPriority(SysTick_IRQn, 7); SysTick_Config(SystemCoreClock/1000);` を行う。
- 2 度押し待ちは RTC1 でも SysTick でもない。`main.c` 236 行 `NRFX_DELAY_MS(DFU_DBL_RESET_DELAY);`（`DFU_DBL_RESET_DELAY` = 500、117 行）の忙待ち。
- 残る状態（推測）: `EVENTS_COMPARE[]` と `PRESCALER` は teardown で戻していない（処理が見つからず）。SysTick の優先度設定と SCB の SysTick 保留ビットも触らない。

## 4. NVIC とジャンプ

`lib/sdk11/components/libraries/bootloader_dfu/bootloader.c` `bootloader_app_start()`（357-402 行）。引用:

```c
  // Disable all interrupts
  NVIC->ICER[0]=0xFFFFFFFF;
  NVIC->ICPR[0]=0xFFFFFFFF;
#if defined(__NRF_NVIC_ISER_COUNT) && __NRF_NVIC_ISER_COUNT == 2
  NVIC->ICER[1]=0xFFFFFFFF;
  NVIC->ICPR[1]=0xFFFFFFFF;
#endif
  ...
    app_addr = SD_SIZE_GET(MBR_SIZE);
    fwd_ret = sd_softdevice_vector_table_base_set(app_addr);
  ...  // SD なし
    .command = SD_MBR_COMMAND_IRQ_FORWARD_ADDRESS_SET,
  ...
    // MBR use first 4-bytes of SRAM to store foward address
    *(uint32_t *)(0x20000000) = app_addr;
  ...
  // jump to app
  bootloader_util_app_start(app_addr);
```

`bootloader_util.c`（GCC 版 `bootloader_util_reset`）: `msr msp, r0`（アプリの初期 MSP）→ アプリの Reset ハンドラへ `bx r0`。

- `__disable_irq` / `__enable_irq` と `SCB->VTOR` の設定は main.c / bootloader.c / bootloader_util.c / boards.c に見つからず。向き先は MBR の IRQ forward で切り替える。
- `NVIC_SystemReset()` の呼び出し箇所（grep）: `main.c` 315 行（有効なアプリが無くジャンプしなかったとき）、`main.c` 399 行（`app_error_fault_handler`）、`boards.c` 113 行（UICR REGOUT0 書き換え後）。DFU 完了直後のジャンプ経路では呼ばれない。
- 推測: USBD / SysTick / RTC1 / SWI の優先度は戻していない。

## 5. GPIO / GPIOTE / PPI

`boards.c` `board_teardown()`（152-157 行）。引用:

```c
  // make sure all pins are back in reset state
  // NUMBER_OF_PINS is defined in nrf_gpio.h
  for (int i = 0; i < NUMBER_OF_PINS; ++i)
  {
    nrf_gpio_cfg_default(i);
  }
```

- `led_pwm_teardown()` → `pwm_teardown(NRF_PWM0)`（169-186 行）: `pwm->ENABLE = 0;`、`pwm->PSEL.OUT[0..3] = 0xFFFFFFFF;` など。NeoPixel 用は `pwm_teardown(NRF_PWM1)`（400 行付近）。
- GPIOTE / PPI は main.c / boards.c / usb.c / bootloader.c に出現せず（grep）。触らない構造。
- 他に残るもの: `NRF_TIMER2->CC[0]` はバージョンレジスタ（`main.c` 120 行 `#define BOOTLOADER_VERSION_REGISTER NRF_TIMER2->CC[0]`、186 行で設定）。`NRF_POWER->DCDCEN` は `board_init` で設定し teardown で戻さない（推測）。`GPREGRET` は 182 行 `if (dfu_start || dfu_skip) NRF_POWER->GPREGRET = 0;`。
- 未確認: `nrf_gpio_cfg_default` の中身（SENSE を落とすか。nrfx 標準実装と思われるが未取得）。

## 6. DFU 完了からジャンプまで

1. `src/usb/msc_uf2.c` `tud_msc_write10_complete_cb()`（161-234 行）。引用: `update_status.status_code = DFU_UPDATE_APP_COMPLETE;`（224 行）、`bootloader_dfu_update_process(update_status);`（229 行）。ブートローダー更新時は `update_status.status_code = DFU_RESET;`（197 行）で、新ブートローダーのコピー成功時は MBR が直接実行する（216 行のコメント `// on success, COPY_BL won't return but run the new bootloader right away.`）。
2. `bootloader.c` `bootloader_dfu_update_process()`（205 行〜）: `m_update_status = BOOTLOADER_SETTINGS_SAVING; bootloader_settings_save(&settings);`（219-220 行）。`bootloader_settings_save()`（185-202 行）は非 OTA では `nrfx_nvmc_page_erase` / `nrfx_nvmc_words_write` の後に `pstorage_callback_handler(...)` を直接呼び、これが `m_update_status = BOOTLOADER_COMPLETE;`（72 行）を設定する。
3. `wait_for_events()`（110-145 行）: `app_sched_execute();` → `tud_task(); tud_cdc_write_flush();` → `m_update_status` が `BOOTLOADER_COMPLETE` / `BOOTLOADER_TIMEOUT` / `BOOTLOADER_RESET` なら `return`。固定の遅延は見つからず。
4. `main.c`: `usb_teardown();`（280 行。OTA なら `sd_softdevice_disable();`）→ `board_teardown();`（286 行）→ `bootloader_app_is_valid() && !bootloader_dfu_sd_in_progress()` なら（SD ありで）`sd_softdevice_disable();`（305 行）→ `(*dbl_reset_mem) = 0;`（309 行）→ `bootloader_app_start();`（312 行）。
5. OTA 判定: `_ota_dfu`（`main.c` 169 行）。UF2 経路では偽。
6. `DFU_DBL_RESET_APP`（`main.c` 116 行 `0x4ee5677e`）は、アプリ先頭 +0x200 が `0x87eeb07c`（`APP_ASKS_FOR_SINGLE_TAP_RESET()`、MakeCode 向け）のときだけ 242 行で `dbl_reset_mem` に書かれる。309 行で必ず 0 に戻す。
7. `DFU_RESET` / `DFU_TIMEOUT` 後の挙動は `bootloader.c` 286 行・299 行付近で `m_update_status` を設定するところまでしか見ていない（未確認）。

## 7. 通常起動（DFU に入らずジャンプ）との差

- `usb_init()` が呼ばれないため `usb_teardown()` も呼ばれない（`main.c` 249-282 行は `dfu_start || !valid_app` のときのみ）。USB は一度も有効化されない。
- 初回は 224 行 `(*dbl_reset_mem) = DFU_DBL_RESET_MAGIC;` の後、236 行で 500 ms 待つ。待ち中にピンリセットされると 177 行の条件
  `((*dbl_reset_mem) == DFU_DBL_RESET_MAGIC) && (NRF_POWER->RESETREAS & POWER_RESETREAS_RESETPIN_Msk)` により DFU に入る。
- `board_init()` の LFCLK 開始・RTC1 開始・SysTick は通常起動でも走る。`board_teardown()` と `bootloader_app_start()` は共通。

## アプリが受け取る状態（DFU 直後 vs 通常のジャンプ）

引用 = ソースの引用で裏付け、推測 = ソースに処理が見つからないことからの推定。

| 項目 | DFU 直後 | 通常のジャンプ |
|---|---|---|
| ジャンプ経路 | 同一プロセスで直接ジャンプ。リセットなし（引用） | 同左（初回は 500 ms 待ちあり）（引用） |
| NVIC enable/pending | 全クリア（引用） | 同左（引用） |
| NVIC 優先度 | USBD/SysTick/RTC1/SWI が設定値のまま（推測） | USBD 以外が同様（推測） |
| USBD | ENABLE=0、PULLUP=0、INTEN=0（引用） | 未使用でリセット値（推測） |
| POWER の USB イベント許可 | 残る可能性が高い（推測） | 未許可（推測） |
| HFCLK | STOP タスク済み、完了待ちなし（引用） | 未起動（推測） |
| LFCLK | STOP タスク済み、完了待ちなし。`LFCLKSRC`=RC、`*STARTED` イベントは残り得る（引用+推測） | 同左 |
| RTC1 | STOP/CLEAR 済み。`PRESCALER` と `CC[0]` は残る（引用+推測） | 同左 |
| SysTick | CTRL=0。保留ビットと優先度は残り得る（引用+推測） | 同左 |
| GPIO | 全ピン `nrf_gpio_cfg_default`（引用） | 同左（引用） |
| PWM0/1 | 無効化、PSEL 切断（引用） | 同左（引用） |
| GPIOTE / PPI | 触らない（見つからず） | 同左 |
| TIMER2 CC[0] | バージョン値（引用） | 同左（引用） |
| `dbl_reset_mem` / `GPREGRET` | 0 / 要求値なら 0（引用） | 同左（引用） |
| WDT | 起動済みなら残る（`bootloader.c` 119 行のコメント）（引用） | 同左 |

## 未確認・見つからず

- Seeed 配布版（fork）のソース差分。
- `nrf_gpio_cfg_default` の中身（SENSE を落とすか）。
- `EVENTS_LFCLKSTARTED` / `HFCLKSTARTED` / POWER の USB イベントの clear 処理。上記ファイルには見つからなかったが、他のファイル（app_timer.c は一部のみ確認）は全件を見ていない。
- tinyusb 側の POWER 割り込みハンドラ全体。
- `DFU_RESET` / `DFU_TIMEOUT` 後の `m_update_status` 設定箇所（286・299 行付近）より先。
- README や issue による裏付け（探していない）。
