結論: 候補 A の着眼点と T0 の机上調査は妥当ですが、PnP の断定、`soc_reset_hook` の実装前提、統計、無人復旧の4点に停止級の問題があります。現状の手順のまま実機へ進むべきではありません。

1. **PnP ログの解釈 — 重要度: 止めるべき**

   - 根拠: 取り外し行しかないログから言えるのは「そのデバイスノードの取り外しが記録された」までです。該当時間帯に VID_1D50 や VID_0000 が一度も現れなかった、あるいは出現時刻がその行の時刻だったとは証明できません。したがって S1 の「USB pull-up 前で停止」と S2 の時系列分類は断定過剰です。
   - `VID_0000&PID_0002` は Coron の VID/PID ではなく、Windows が列挙に失敗したデバイスに付けるプレースホルダーです。原因はデバイス記述子の無応答だけでなく、ポートリセット、Set Address、構成記述子、不正な記述子なども含みます。また、ホストは一つの接続に対して列挙を複数回再試行するため、3行を3回の再起動と数えることもできません。[Microsoft の列挙失敗説明](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/case-study--troubleshooting-an-unknown-usb-device-by-using-etw-and-netmon)、[列挙再試行の説明](https://techcommunity.microsoft.com/blog/microsoftusbblog/how-does-usb-stack-enumerate-a-device/270685/)
   - UF2 ドライブの消失も「像が受理され、ブートローダーが USB を終了した」とは整合しますが、実機ブートローダーと調査した配布バイナリのバイト同一性は未確認です。[bootloader-ram.md](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/bootloader-ram.md:8>)
   - 直し方の案: S1 は「対象 VID/PID の取り外し記録がない」、S2 は「同じ物理ポートに列挙失敗ノードの取り外し記録がある」とだけ記述してください。「USB 有効化まで進んだ」「3回再起動した」は推測と明記します。S2 の判別には、制御した致命的エラー1回の前後で Windows USB ETW を自動採取し、接続、ポートリセット、GET_DESCRIPTOR、再試行を直接確認する方が安価です。

2. **候補 A の T1 — 重要度: 止めるべき**

   - 根拠: Zephyr 4.1 の `soc_reset_hook` は RAM 初期化前ですが、リセットハンドラの最初の命令ではありません。またこの版では、フックの後に割り込みをマスクします。[reset.S](</home/yagu001/zmk-dya-build/zephyr/arch/arm/core/cortex_m/reset.S:101>)。`bl` により LR は変わり、通常の C 関数ならプロローグで MSP も変わります。周辺レジスタの早期状態はほぼ捉えられますが、「受け渡しの瞬間の全 CPU 状態」という表現は不正確です。
   - 固定 DIAGREC はアプリの `.bss` 初期化から保護されていますが、ブートローダーの動的スタックとヒープとの非衝突は静的には未証明です。既存校正が示すのは保持できた実績までです。
   - 現在の入口記録には NVIC、SysTick、VTOR、USBD の動作状態がありません。[diag_boot.c](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_boot.c:148>)。最低でも次が必要です。

     - `NVIC ISER/ISPR/IABR` の全実装ワード
     - `PRIMASK/BASEPRI/FAULTMASK/CONTROL/MSP/PSP`
     - `SCB->VTOR/ICSR`、`SysTick CTRL/LOAD/VAL`
     - RTC1 の `INTENSET/EVTEN/PRESCALER/CC/EVENTS`
     - USBD の `ENABLE/USBPULLUP/INTEN/EPINEN/EPOUTEN/EVENTCAUSE`
     - CLOCK の `INTENSET` と関係イベント
     - 仮説に含めるなら PPI `CHEN`、GPIOTE `INTENSET/EVENTS`

   - 「汚れが1回あれば採用、20回清浄なら棄却」も成立しません。経路差やリセット値との差は原因の証明ではなく、20回ゼロは低頻度の残留を棄却しません。
   - 直し方の案: `entry0` は既存 ring と分離した小さな固定スロットにし、スカラーの volatile 書き込みだけを行い、有効印を最後に書きます。`memset`、CRC、未初期化の static/global、ログは使わず、最終 ELF の逆アセンブルでスタック使用と外部呼出しを確認してください。判定は事前に「後段が禁止条件を破る値」を定義し、単なる非ゼロを汚れ扱いしないようにします。

3. **候補 A の修正 — 重要度: 止めるべき**

   - 根拠: 現在すでに `CONFIG_SOC_RESET_HOOK=y` で、Nordic は `soc_reset_hook = SystemInit` を既定で提供しています。[platform_init.ld](</home/yagu001/zmk-dya-build/zephyr/soc/nordic/common/platform_init.ld:7>)。独自の `soc_reset_hook()` を定義するとこれを置き換えます。明示的に `SystemInit()` を一度呼ばなければ、nRF52 errata、FPU、APPROTECT、ピン設定などの初期化を失います。[system_nrf52.c](</home/yagu001/zmk-dya-build/modules/hal/nordic/nrfx/mdk/system_nrf52.c:132>)
   - LFCLK は `LFCLKSTAT.STATE=Running` を確認した後だけ `LFCLKSTOP` を発行でき、動作中の `LFCLKSRC` 書き換えは禁止です。[nRF52840 Product Specification](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/clock.html)。停止完了後に、Zephyr/nrfx に `LFCLKSRC` を設定させる方針自体は整合します。
   - HFXO の待ち条件が不正です。既存コードは停止後に `HFCLKSTAT.STATE==0` を待っていますが、HFXO から HFINT に戻っても CPU の HFCLK は動作中です。[diag_boot.c](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_boot.c:362>)。待つべきなのは `HFCLKSTAT.SRC==RC` など、HFXO が選択されなくなった条件です。
   - `soc_reset_hook` では既存の DWT 初期化より前に待ち処理が走ります。現在の `WAIT_US` は DWT/CYCCNT 前提なので、そのまま移植すると期限が成立しません。
   - NVIC の外部 IRQ だけを消しても SysTick、PendSV、周辺の `INTEN/EVENTS` は残ります。逆に RTC1/USBD を部分的にだけ停止すると、Zephyr/nrfx がソフトウェア状態をゼロから構築する際にハードウェアだけ半端な状態になります。
   - 直し方の案: 順序を「最小 raw 記録 → 割り込みマスク → 周辺 IRQ/イベント停止 → 周辺停止 → クロック停止 → `SystemInit()` を正確に一度 → Zephyr へ戻る」として、各段の仕様を表にしてください。HFXO は SRC、LFCLK は STATE を使って有界待ちします。USBD、RTC1、NVIC、SysTick、PPI/GPIOTE は、測定で残留が確認された対象だけを、nrfx の初期化が期待する状態まで完全に戻してください。

4. **候補 B の T3 — 重要度: 直すべき**

   - 根拠: TIMER ISR からの `k_oops()` は、reason、fatal ハンドラ、`sys_reboot()` という共通経路は試せます。しかし 10/07 の `LL_ASSERT_OVERHEAD` は Bluetooth LLL の高優先度コンテキストで、RADIO、PPI、ticker、関連 IRQ が活動中です。人工 TIMER ISR はその周辺状態、優先度、ネスト状態を代表しません。
   - fatal ハンドラ自身は RAM 上の pending 記録を作って即再起動し、設定保存と mutex は次回起動へ繰り延べています。[watchdog_fatal.c](</home/yagu001/zmk-dya-build/zmk-feature-watchdog/src/watchdog_fatal.c:65>)、[watchdog_pending.c](</home/yagu001/zmk-dya-build/zmk-feature-watchdog/src/watchdog_pending.c:48>)。この点はすでにソースで確認可能です。ただし Zephyr の共通 fatal 経路はその前にログと coredump を通ります。
   - T3 成功で退けられるのは「一般的な ISR `k_oops` → pending 記録 → SREQ の経路」だけです。S2 全体や、LLL 固有の周辺状態を伴う再起動は退けられません。失敗した場合も、TIMER4 の既存監視との競合なら別原因です。
   - 直し方の案: TIMER4 と独立した EGU/SWI などを使い、元の LLL IRQ に近い優先度で1回試し、USB ETWと次回入口状態を同時取得してください。10回反復しても代表性は増えないため、まず1回の機構試験で十分です。

5. **統計 — 重要度: 直すべき**

   - 根拠: 4/33 の95%区間を約3〜28%とするのは、Clopper–Pearson の約3.4〜27%として概ね妥当です。
   - 一方、率を 4/33 と置いたとき4回中0件の確率は約59.6%で、約0.7ではありません。結論の方向は変わりませんが数値は訂正が必要です。
   - 真の率を下限の3%と置いた場合、179回中0件の確率は約0.43%です。「数%」ではありません。0/179 の95%上限は片側で約1.66%、両側で約2.04%です。独立かつ同条件と仮定すれば、4/33 と 0/179 は「差が確立していない」とは言えません。
   - ただし実際には像、滞在時間、経路が違い、同一個体での反復なので、単純な二項独立試行として原因を推定することもできません。
   - 直し方の案: 「試験条件では率が大幅に低いことは示唆されるが、構成差が交絡しており原因は特定できない」としてください。候補 C を単なる残余候補にせず、経路、像、滞在条件別の記述統計として扱います。

6. **失敗時の復旧 — 重要度: 止めるべき**

   - 根拠: スクリプトの期限と子プロセス終了確認は、PC 側の暴走を止める仕組みであり、実機の復旧ではありません。復帰スクリプトは初期状態が app または boot の場合しか進めず、どちらにも見えない場合は失敗します。[calib-flash.ps1](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/calib/calib-flash.ps1:38>)
   - TIMER4 の網は現在 `board_early_init_hook` 内で張られるため、T1 の `soc_reset_hook`、そのスタック、記録書き込み、T2 の待ち処理の失敗を救えません。[diag_boot.c](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_boot.c:407>)
   - 「それでも出なければリセット1回」と「最後にリーダーがキーを押す」は、ボタン押下、立ち会い、途中応答を求めないという固定制約に直接違反します。
   - 直し方の案: app/boot の双方が消えた場合にも自動で戻せる経路が確認できるまで、T1/T2 の実行を許可しないでください。ハード WDT を使わない条件では、少なくとも早期処理をすべて有界化し、異常時は直接 `NVIC_SystemReset()` へ進む必要があります。それでもコードフォルト前の救済にはならないため、利用可能ならホスト制御の電源サイクル等の実在する復旧設備が必要です。無ければ、この無人制約下では実験不能と明記すべきです。キー入力は自動化可能な HID レポート試験へ置き換えるか、物理スイッチの確認を完了条件から外してください。

7. **所要時間 — 重要度: 直すべき**

   - 根拠: T1 は「1分稼働×40回」だけで40分です。これに20回の UF2 遷移、20回の `r`、dump、開始・復帰、15分のビルドが加わるため、「実行25分、T1計40分」は物理的に成立しません。
   - T2 は T1 の測定を繰り返したうえで本番確認を行うので、記載の1.5時間は余裕がありません。また `entry0` 追加では dump の検証表、固定アドレス、tag、MD5、場合によっては記録構造の更新が必要ですが、その実装・模擬試験時間が含まれていません。
   - 直し方の案: T1 は最低でも「40分の dwell＋40操作の実測中央値＋ビルド・復帰」、T2 は「同じ測定＋本番更新」として再計算してください。失敗時の90秒待ちや復帰も予備時間に含めると、T2を行う場合の全体3〜4時間は楽観的です。

8. **先に行うべき安価な試験 — 重要度: 直すべき**

   - 根拠: いきなり RAM 初期化前のフックを置換しなくても、候補 A の多くは既存の安全な入口計測で判別できます。現在の179回で LFCLK はすべて停止しており、少なくとも「LFCLK が時々動作中」の予測はすでに弱くなっています。
   - 直し方の案:

     1. まず既存の `board_early_init_hook` の入口記録に、NVIC、RTC1、USBD、SysTick、PPI/GPIOTEを追加する。現構成ではこの前に走る `SystemInit()` が変更しないレジスタに限定すれば、RAM 初期化前のリスクなしに経路差を取れます。
     2. そこで差が見つかった項目だけを、仕様上の危険条件とZephyr/nrfxの初期化コードに突き合わせる。単なるイベントビットの残留は原因扱いしません。
     3. S2 は制御した fatal 1回と USB ETW を組み合わせ、3行が3再起動なのか、一接続のホスト再試行なのかを先に確定する。
     4. 候補 A の集約的な因果試験として、UF2後の初回起動だけ retained cookie で一度 `NVIC_SystemReset()` し、2回目を通常起動する比較像を検討する。個別周辺の推測清掃より判別力があります。ただし無人復旧の穴を閉じた後に限ります。

全体の判定: 作り直し