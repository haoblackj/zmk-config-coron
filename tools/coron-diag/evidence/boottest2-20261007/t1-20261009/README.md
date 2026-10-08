# T1: 受け渡し状態の写し（2026-10-09 00:20〜00:35、右手側 B17318CDBE9A61B1、試験像 bt5-R-10090018 / bt5A-R-10090018）
方針 v3（issue の 23:2x に承認）の T1。計測器に、起動の 3 点（`board_early_init_hook` の先頭、クロックドライバの後 = PRE_KERNEL_1 の 31、USB 有効化の後 = APPLICATION の 97）で 49 語のレジスタを写す別枠（`snap`、magic と形式番号と CRC つき、記録領域の末尾、`diag_area` は 0xb9c バイト）を足した像で、DFU 直後の起動と `r`（ソフトリセット）の起動の入口を比べた。手動操作なし、立ち会いなし。
- `loop-1009-002017/`: 書き込み群の 1 回目。基準像の書き込みが、ループが `-TagBase` を書き込みの子へ渡していなかったためのホスト側の FAIL（`cur tag=base`）で止まり、本番復帰 PASS。この起動（seq 20）の写しは取れている。
- `loop-1009-002340/`: 書き込み群（`-Mode write -Dwells 1,1,1`）。基準像の書き込み、試行 3 回とも正常完了、事故記録 0 件、本番復帰 PASS。DFU 直後の起動は seq 21、22、23、24。
- `loop-1009-003010/`: リセット群（`-Mode reset -Dwells 1,1,1`）。基準像の書き込み（seq 25、DFU 直後）、`r` の起動 seq 26、27、28、すべて正常完了、事故記録 0 件、本番復帰 PASS。
- `snap-table.md`: 全起動の全点の値（`snap-collect.py` の出力。表の「CLOCK INTEN=0x380」の印は POWER と CLOCK が INTENSET を共有しているのを見落とした初版の誤判定で、スクリプトは直してある）。

## 入口（フックの先頭）の値。経路内は毎回同じ
| 項目 | DFU 直後（seq 20、21、22、23、24、25 の 6 回） | `r` 直後（seq 26、27、28 の 3 回） |
|---|---|---|
| POWER/CLOCK の INTENSET | **0x380**（USBDETECTED、USBREMOVED、USBPWRRDY の割り込み許可。クロックのビットは 0） | 0x0 |
| POWER の USB イベント | DETECTED=0、REMOVED=0、PWRRDY=0 | **DETECTED=1**（ソフトリセットで VBUS の検出が立ち直り、誰も消していない）、他 0 |
| NVIC ISER[0]/[1] | 0x0 / **0x80**（IRQ 39 = USBD が有効のまま。ブートローダーは ICER[0] しか消していない） | 0x0 / 0x0 |
| NVIC ISPR | 0 / 0 | 0 / 0 |
| CLOCK | LFCLKSTAT=0（停止）、LFCLKRUN=0、LFCLKSRC=0（RC）、HFCLKSTAT=0x10000（HFINT 動作中）、HFCLKRUN=0、**EVENTS_LFCLKSTARTED=1、EVENTS_HFCLKSTARTED=1** | 同じだが EVENTS_HFCLKSTARTED=0 |
| USBD | ENABLE=0、PULLUP=0、INTEN=0、**EVENTCAUSE=0x300**（SUSPEND と RESUME の原因ビットが残る） | ENABLE=0、EVENTCAUSE=0 |
| USBREGSTATUS | 0x1（VBUSDETECT=1、OUTPUTRDY=0） | 0x1 |
| RTC1 | COUNTER が 98304 → 0（2 回の読み取りの間にブートローダーの CLEAR が効いた）、CC[0]=98304、INTEN=0、EVTEN=0 | COUNTER 0/0、CC[0]=0 |
| SysTick | CTRL=0x10004（停止、COUNTFLAG）、LOAD=63999 | 同じ |
| PRIMASK/FAULTMASK/CONTROL/AIRCR/ICSR/SHCSR/DEMCR | 0 / 0 / 0x6 / 0xfa050000 / 0 / 0x70000 / 0x1000000 | 同じ |
| PPI CHEN、GPIOTE INTENSET | 0、0 | 0、0 |
| RESETREAS | 0x4（SREQ） | 0x4 |

## 後の 2 点
- クロックドライバの後（約 1.6 ms）: NVIC ISER[0] に POWER_CLOCK（bit 0）と TIMER4（bit 27、網）が加わる。POWER の INTEN は DFU 直後では 0x380 のまま、`r` では 0。保留なし。RTC1 は 0/0。
- USB 有効化の後（約 24 ms）: 両経路とも INTEN=0x381（USB の 3 ビット + HFCLKSTARTED）、LFCLK は XTAL で動作、HFXO 要求中、USBD ENABLE=1 で PULLUP=0（USBPWRRDY が未到来）、USBREGSTATUS は 0x1 のまま（OUTPUTRDY=0）。NVIC ISER[1] は DFU 直後 0x280（USBD と bit 9）、`r` は 0x200。
- 計測器の段階の時刻（µs）: hook の処理終了 1357、クロックドライバ後 1858、システムタイマ後 2190、POST_KERNEL 2343、APPLICATION 開始 4619、USB 有効化後 24338。水晶の待ちで長く眠ってはいない。

## 禁止条件への照合（`rootcause-plan-20261008/t0-summary.md`）
- A の前提条件（POWER の USB 割り込み許可が入口から残り、クロックドライバが POWER_CLOCK の IRQ を有効にする）は、DFU 直後の経路でだけ成立することを 6/6 で確認した。`r` の経路では成立しない（3/3）。
- A の引き金（窓の中で USB の電源イベントが立つこと）は、9 回の起動のどれでも観測していない。DFU 直後の 6 回は USB イベントが 0 のまま 24 ms まで進み、USBREGSTATUS.OUTPUTRDY も 0 のままだった（USBPWRRDY は USB ドライバが errata 187 の回避を書いた後に来る）。
- B の前提条件も同じ（DFU 直後だけ成立）。引き金は観測していない。
- C（LFCLKRUN=1）: 9/9 で LFCLKRUN=0。成り立たない。
- D（USBD.ENABLE=1）: 9/9 で 0。成り立たない。
- 追加で分かった DFU 直後だけの残留: NVIC の USBD（IRQ 39）が有効のまま（USBD は無効なので割り込みは出ない）、USBD の EVENTCAUSE に SUSPEND/RESUME が残る、EVENTS_HFCLKSTARTED が残る（`t0-driver-assumptions.md` の errata 201 の印の誤動作に当たる）。

## 言えること、言えないこと
- 言えること: DFU 直後の起動は、`r` の起動と違う 4 つの残留（POWER の USB 割り込み許可、NVIC の USBD、EVENTCAUSE、HFCLKSTARTED イベント）を持って Zephyr に渡される。これは毎回で、間欠ではない。
- 言えないこと: 現場の停止がこの残留から起きたこと。引き金（イベントの到来）は 9 回では観測しておらず、現場の率（3.4〜28%）なら 6 回の DFU で 0 件になる確率は 17〜81% で、否定にも肯定にもならない。
- 次（T2）: 整え処理（POWER/CLOCK の割り込み許可、TIMER4 以外の NVIC の有効と保留、HFCLKSTARTED イベント、SysTick を消す。待ちなし、クロック操作なし）を網の直後に入れた像で、DFU 直後の入口が `r` と同じ値（危険な項目について）になることを、同じ写しで確かめる。
