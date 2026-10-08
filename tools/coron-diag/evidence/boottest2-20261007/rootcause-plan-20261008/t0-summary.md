# T0（机上）の結果（2026-10-08〜09。実機は触っていない）

資料: `t0-boot-normalization.md`（Zephyr と `SystemInit` がフックまでに正規化するレジスタ。ソースと同じ設定の ELF の逆アセンブルで照合）、`t0-driver-assumptions.md`（各ドライバが前提にする入口状態と、違ったときの挙動）、`t0-spec-snapshot-and-crumb.md`（T1 の写しの枠と本番用の印の仕様）、`bootloader-exit-0.6.1.md`（ブートローダーの出口）。

## 禁止条件（入口でその値だと起動が止まりうる、とソースから言えるもの）
| 条件 | 入口の値 | 機構（根拠行は `t0-driver-assumptions.md` §3） | 現場の型との整合 |
|---|---|---|---|
| A. 無限待ち | POWER.INTEN の USB ビット（USBDETECTED/USBREMOVED/USBPWRRDY）が 1 かつ対応する EVENTS_USB* が 1、または CLOCK.INTEN の HFCLKSTARTED/LFCLKSTARTED が 1 かつ対応する EVENTS が 1 | 起動中は BASEPRI で割り込みが止まっていて、`clk_init`（PRE_KERNEL_1, 30）が POWER_CLOCK の NVIC を有効にしても保留は消さない。線が立っていれば保留のまま。`lfclk_spinwait`（PRE_KERNEL_2、XTAL が回るまで上限なし）は PRIMASK を立てて WFE で眠り、起床は「保留への移り」だけ（SEVONPEND）。既に保留なら RC の LFCLKSTARTED で移りが起きず、起きない。ドライバ自身が `clock_control_nrf.c:560-563` に「保留を消さないと起きない」と書いている。RTC1 の COMPARE0 が約 256 秒後に 1 回起こすが、XTAL の起動（数百 ms）より先にもう一度眠ると要因が無くなる。例外も起きないので watchdog の再起動も無い | 型 S1（書き込み直後、USB 初期化より前で止まる）。DFU の経路だけが POWER の USB 許可を残す（ブートローダーの出口の表）ので「書き込み直後だけ」、イベントの残り方次第なので「間欠」、ピンリセットもソフトリセットも周辺をリセットし DFU を通らないので「リセットで直る」。成否は INTEN とイベントの実値で決まる（T1 で測る） |
| B. 致命的エラー → 再起動 | POWER.INTEN の USB ビットが 1（DFU の経路で成立）かつ、割り込みが開いてから `usb_init`（POST_KERNEL 50）までに EVENTS_USB* が 1 | POWER_CLOCK の ISR が `nrfx_power_irq_handler` を呼び、未登録（NULL）の USB イベントハンドラを呼ぶ（`CONFIG_ASSERT` 無効で検査は空）。故障例外 → watchdog が記録して再起動（はず）。A と同じ入口なら先に A で止まる | 止まりはせず再起動。本番像 2725423 の watchdog の記録（Studio 経由、受動的な読み取り）に PC=0 の故障があるかで、起きていたかが分かる |
| C. 無限待ち | LFCLKRUN=1 のまま LFCLK が止まっていて EVENTS_LFCLKSTARTED=0 | `nrfx_clock_start` が START 済みとみなして START を打たず、`lfclk_spinwait` も打たない | 計測器の 179 回で `lfclkrun=0`、`lfev=1` だったので成り立ちにくい |
| D. 無限待ち | USBD.ENABLE=1 のまま入る | `nrf_usbd_common_enable` が READY を上限なしで待つ（協調スレッド） | ブートローダーは ENABLE=0 にするので該当しない（T1 で確認） |

## 無害と判定できる残留（抜粋）
`EVENTS_LFCLKSTARTED`（START の前に消す）、`EVENTS_DONE/CTTO`（`SystemInit` が消す）、`LFCLKSRC`（`clk_init` が RC を書く）、RTC1 の PRESCALER と CC（書き直す）、USBD の READY、GPIOTE の PORT、NVIC の全無効。`EVENTS_HFCLKSTARTED` は起動は止めないが、errata 201 の印を立てる誤動作（汎用の HF 要求が完了通知を受けない）がある。

## フックまでに正規化されるもの（測る意味が無い）
BASEPRI（0x20）、MSP/PSP、VTOR、NVIC の IPR（全部 0x20）、FPU、MPU、SCR、SHPR、CFSR/HFSR。この設定（`CONFIG_INIT_ARCH_HW_AT_BOOT` 無効）では NVIC の ISER/ISPR、PRIMASK、FAULTMASK、AIRCR、ICSR、SysTick、DWT はフックまで一度も書かれない（Codex のレビューにあった「Zephyr が正規化する」は当たらない）。

## T1 で測る項目（確定）
`t0-spec-snapshot-and-crumb.md` §1 の 49 語 × 3 点（フックの先頭、クロックドライバの後、USB 有効化の後）。禁止条件 A の判定に直接効くのは、フックの先頭の POWER.INTEN、EVENTS_USBDETECTED/USBREMOVED/USBPWRRDY、CLOCK.INTEN、EVENTS_LFCLKSTARTED/HFCLKSTARTED、NVIC ISPR[0] の POWER_CLOCK ビット、SCB ICSR の VECTPENDING。

## T0 で足した受動的な確認（実機の書き込みなし）
- 本番像 2725423 の watchdog の記録を Studio 経由（BLE）で読み、10/07 16:28 以降に PC=0 の故障があるかを見る（禁止条件 B の痕跡）。

## 不明点（T1 でしか決まらない）
1. 入口で POWER の USB イベントと CLOCK の INTEN が実際に何か。
2. LFCLKSTOP が LFCLKRUN を 0 に戻すか（179 回の観測は 0）。
3. USBD を一度 ENABLE して 0 に戻した後、アプリが再び ENABLE したときに USBPWRRDY が新しく発生するか（発生しないと USB が列挙されない。起動は止めない）。
4. ブートローダーが PPI の CHEN を残すか。
5. 実機のブートローダー（Seeed 配布版）が本家 0.6.1 と同じ出口か。

## 修正の形（T1 で A か B が成立したとき）
- 最小: `board_early_init_hook`（本番でも可。計測処理ではなく整え処理）で、POWER.INTENCLR に USB の 3 ビット、CLOCK.INTENCLR に HF/LF、EVENTS_USB* と EVENTS_*STARTED の消去、NVIC の POWER_CLOCK の保留消去を書く。クロックは触らない（LFCLKSRC の書き換え禁止に抵触しない）。十数命令。
- 代替: 新しい像の初回起動で一度だけソフトリセット（DFU の出口を通常の出口に揃える）。cookie の状態機械が要る。
