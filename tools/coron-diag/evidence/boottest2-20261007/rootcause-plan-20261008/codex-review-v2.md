結論: v2 は v1 より大幅に改善されており、全面的な作り直しは不要です。ただし T1 の測定位置/記録容量、T2/T3 の無人復旧、手動キー確認の3点は、実機へ進む前に直す必要があります。

1. 事実と PnP ログの解釈 — 重要度: 直すべき

   根拠: 「対象 VID/PID の取り外し記録が無い」「同じポートの `VID_0000&PID_0002` の取り外し記録が3件ある」までに表現を弱めた点は妥当です。実際の記録も取り外しイベントです。[pnp-raw-1007.txt](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/pnp-raw-1007.txt:15>)

   `VID_0000&PID_0002` は Coron の VID/PID ではなく、Windows が正しい VID/PID を取得できなかった列挙失敗ノードです。ただし `PID_0002` 自体を原因コードのように扱うことはできません。Windows の公式説明では、unknown device はポートリセット、Set Address、device/configuration descriptor の取得または検証など、複数段階の失敗で作られます。[Microsoft の説明](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/case-study--troubleshooting-an-unknown-usb-device-by-using-etw-and-netmon)

   「この型では USB に何かが現れた」は少し強く、取り外しログだけから確実に言えるのは「Windows が同じ物理ポートに列挙失敗ノードを作成していた」です。出現時刻や、3行が3回の物理的な再接続だったことは証明できません。

   また「通常の起動との差は USB を一度も有効にしないことだけ」も断定しすぎです。ソース上の分岐差が USB 実行の有無だけでも、その実行によって CLOCK/POWER/PPI/NVIC などの結果状態が変わることが候補 A の主題です。実機ブートローダーとの同一性も未確認です。[bootloader-ram.md](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/bootloader-ram.md:8>)

   直し方の案: 「同じ物理ポートに列挙失敗ノードが存在し、その取り外しが3回記録された」「原因段階と再接続回数は不明」としてください。ブートローダーの差は「確認したソース上で見つかった制御フロー差」と記述してください。

2. 候補 A の T1 — 重要度: 止めるべき

   根拠: v2 の T1 は「受け渡しの瞬間」を測る試験ではありません。これは安全側への意図的な変更ですが、列挙したレジスタのかなりの部分は `board_early_init_hook` までに Zephyr が書き換えています。

   - `soc_reset_hook`、つまり `SystemInit()` は先に実行されます。[reset.S](</home/yagu001/zmk-dya-build/zephyr/arch/arm/core/cortex_m/reset.S:101>)
   - その後、Zephyr は外部 IRQ を全無効化し、pending を全消去します。[scb.c](</home/yagu001/zmk-dya-build/zephyr/arch/arm/core/cortex_m/scb.c:90>)
   - VTOR はアプリのベクタ表へ設定されます。[prep_c.c](</home/yagu001/zmk-dya-build/zephyr/arch/arm/core/cortex_m/prep_c.c:190>)
   - 全外部 IRQ の優先度も既定値へ書き換えられます。[irq_init.c](</home/yagu001/zmk-dya-build/zephyr/arch/arm/core/cortex_m/irq_init.c:26>)
   - CONTROL/MSP/PSP/BASEPRI/FAULTMASK も reset.S とアーキテクチャ初期化で変更されます。

   したがって、T1 で測る `NVIC ISER/ISPR/IPR`、CONTROL/MSP/PSP/VTOR などは、ブートローダーの受け渡し状態を示しません。一方、SystemInit とアーキテクチャ初期化が触らない CLOCK/POWER/RTC1/USBD/SysTick pending などは、ドライバが見る残留状態として測る価値があります。

   記録容量にも問題があります。現在の `diag_area` は 0x93c バイトを使用し、4 KB 領域の残りは 0x6c4 バイトです。[bootloader-ram.md](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/bootloader-ram.md:58>) 推測ですが、v2 の列挙項目は約64語になり、`boot_rec` 内へ追加すると ring 6件/last/cur の8コピーで約2 KB増えるため、残り約1.7 KBを超える可能性が高いです。

   直し方の案:

   - T0 の対象を SystemInit だけでなく、reset.S、`z_arm_init_arch_hw_at_boot()`、`z_prep_c()`、EARLY init、`arch_kernel_init()` まで広げてください。
   - その途中で正規化される CPU/NVIC 項目は T1 から外し、「ソースで棄却」としてください。
   - 拡張スナップショットは `boot_rec` に埋め込まず、cur/last 用の2スロットとして分離し、magic/format/CRC を付けてください。
   - 最終 ELF で DIAGREC の上端を検査し、コンパイル時またはビルド後に4 KB超過を失敗にしてください。
   - CLOCK の停止途中を扱うなら、一連の読み出し前後に時刻または状態の再読を入れてください。逐次読み出しは原子的なスナップショットではありません。

3. 候補 A の修正 — 重要度: 止めるべき

   根拠: ドライバ初期化前に完全な状態へ戻す限り、cleanup 自体が Zephyr/nrfx と並行して衝突する問題はありません。ただし v2 の順序「最小の記録 → 割り込みマスク」は危険です。Zephyr 4.1 は `soc_reset_hook` の後で初めて BASEPRI を設定します。[reset.S](</home/yagu001/zmk-dya-build/zephyr/arch/arm/core/cortex_m/reset.S:120>) つまり候補 A が想定する残留 IRQ が本当に有効なら、記録中に割り込めます。

   Nordic の仕様との整合は概ね改善されています。LFCLKSTOP は `LFCLKSTAT.STATE=Running` のときだけ発行でき、動作中の LFCLKSRC 書き換えは禁止です。[nRF52840 CLOCK 仕様](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/clock.html) HFXO は STATE ではなく SRC が RC に戻ることを待つ方針で正しいです。

   ただし外部 NVIC の enable/pending/priority は、後続の Zephyr 初期化がすでに正規化します。ここを独自 cleanup の対象にする必要性は薄く、対象は SysTick/PendSV と、Zephyr が初期化前に正規化しない周辺状態へ絞れます。RTC1 ドライバも初期化時に INTEN/EVTEN/PRESCALER/CLEAR を設定しています。[nrf_rtc_timer.c](</home/yagu001/zmk-dya-build/zephyr/drivers/timer/nrf_rtc_timer.c:703>)

   「新しい像の初回だけリセット」の RAM 目印も仕様不足です。単純な magic では、同じ UF2 の再書き込みを検出できない、古い magic を引き継ぐ、更新途中で torn write になる、またはリセットループになる可能性があります。

   直し方の案:

   - `soc_reset_hook` の先頭は小さなアセンブリにし、元の PRIMASK を退避して直ちに `cpsid i` してください。
   - cleanup は、測定とソース調査で危険と分かった周辺だけに限定してください。
   - LFCLK は Running の場合だけ STOP を発行し、NotRunning を確認するまで LFCLKSRC に触れないでください。可能なら LFCLKSRC の設定自体は nrfx に任せてください。
   - cleanup 後に `SystemInit()` を正確に1回だけ呼び、Zephyr の reset.S へ戻してください。
   - 初回リセット方式を使うなら、magic/build ID/CRC/有効印を持つ状態機械として仕様化し、「同一 UF2 の再書き込み」「途中リセット」「壊れた cookie」を試験してください。

4. 候補 B の T3 — 重要度: 直すべき

   根拠: v2 は T3 を「一般的な ISR → SVC/k_oops → fatal → pending → reboot」の機構試験1回に限定しており、代表性の言い過ぎは解消しています。LLL の assert も最終的には `k_oops()` を使うため、共通経路の試験としては妥当です。

   ただし EGU/SWI では、10/07 に活動していた RADIO/TIMER0/PPI/ticker の状態を再現しません。また Zephyr の共通 fatal 経路は watchdog handler より前にログと coredump を通ります。[fatal.c](</home/yagu001/zmk-dya-build/zephyr/kernel/fatal.c:85>) watchdog 側が即再起動することは確認済みです。[watchdog_fatal.c](</home/yagu001/zmk-dya-build/zmk-feature-watchdog/src/watchdog_fatal.c:65>)

   直し方の案: T3 の合格条件は「汎用 fatal 経路が1回完走した」に限定してください。S2 または LLL 固有原因の棄却には使わないでください。PnP の取り外しログだけでなく USB ETW を自動採取し、接続/ポートリセット/GET_DESCRIPTOR/再試行を保存してください。

5. 統計 — 重要度: 直すべき

   根拠: 数値にまだ小さな誤りがあります。

   - 4/33 の両側95% Clopper–Pearson 区間は約 3.40〜28.20%です。上限27%ではありません。
   - 率を4/33と置いた4回中0件は約59.64%で、v2 の約60%は正しいです。
   - 下限3.40%を使った179回中0件は約0.20%です。v2 の約0.4%は、率を3%と置いた場合の値に近いものです。
   - 0/179 の95%上限は片側約1.66%、両側約2.04%です。

   像/滞在時間/進入経路が違い、同一個体の反復なので原因推定に使えないという注意書きは妥当です。

   直し方の案: 数値だけ訂正し、「試験条件間に大きな率差があることは示唆されるが、構成差が交絡している」に留めてください。

6. 失敗時の復旧 — 重要度: 止めるべき

   根拠: 固定制約との衝突が残っています。

   - 完了条件の選択肢 (b) は、後日であってもユーザーのキー押下と報告を要求するため、固定制約違反です。
   - T1 は「フック内で読むだけ」ですが、実際には新しい読み出しが `net_arm()` より前に追加されます。現在の網は入口処理と記録初期化の後に張られます。[diag_boot.c](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_boot.c:407>) [diag_boot.c](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_boot.c:459>)
   - T3 も、fatal が同優先度またはマスク不能の文脈で停止した場合、TIMER4 が必ず救済できるとは限りません。既存資料も priority 0 の抑止や TIMER4 準備前は救えないと明記しています。[README.md](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/README.md:103>)
   - `calib-flash.ps1` は app/boot のどちらにも見えない状態から復旧できません。[calib-flash.ps1](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/calib/calib-flash.ps1:38>)
   - `uhubctl` で切れるのは通常 VBUS です。推測ですが、本体がバッテリーまたは別経路から給電されている場合、MCU の電源サイクルにはならず復旧設備として機能しません。

   直し方の案:

   - キー押下の (b) は削除し、自動確認できる USB/BLE/RPC だけを完了条件にしてください。ただし物理スイッチ/キーマトリクスは未確認と明記してください。
   - 危険な試験の前に、給電停止1回で MCU が実際にコールドリセットされることを自動確認してください。VBUS だけで落ちなければ、T2 と T3 は無人条件下では実行不可です。
   - T1 は可能なら最小の復旧タイマをフック入口で先に張り、その後にスナップショットを取ってください。それでもフォルト/LOCKUPは救えないため、完全な電源断が確認できなければ安全とはみなせません。
   - 「穴を明示的に受け入れる」は復旧策ではありません。固定制約下では選択肢 (iii) を採る必要があります。

7. 所要時間 — 重要度: 直すべき

   根拠: 実機実行約75分の算術は妥当です。一方、T0 2時間と T1 実装/模擬1.5時間は楽観的です。T1 は記録形式、固定アドレス、4 KB 容量、dump/parser、缶詰、期待表を変更し、既存83場面を再検証します。記録構造を分離する修正も必要です。

   T3 の30分実装も、IRQの予約競合、優先度、SVC/fatal の確認、USB ETW、失敗時復旧まで含めると余裕がありません。T2 は cookie の状態機械と同一 UF2 再書き込み試験が追加されます。USB ハブを導入する場合、調達時間も別枠です。

   直し方の案: 推測ですが、T0 は3〜5時間、T1 は実装/模擬3〜5時間と実行約1.5時間、T3 は2時間程度、T2 は6〜10時間程度を初期見積もりにした方が安全です。20対20回についても、まず少数の対で経路が決定的か確認し、経路内変動がある場合だけ事前上限まで進める方が判別効率は高いです。

8. 先に行うべき安価な試験 — 重要度: 直すべき

   根拠: v2 は board hook での安全な観測を採用しましたが、さらに安価な切り分けがあります。

   直し方の案:

   - T0 で Zephyr の reset.S/scb.c/irq_init.c を読むだけで、外部 NVIC の enable/pending/priority、CONTROL/MSP/PSP/VTOR は候補から外せます。これらを実機で40回測る必要はありません。
   - T1 は入口だけでなく、既存の `STG_PK1_AFTER_CLK` と `STG_APP_AFTER_USB` でも危険項目の小さな再スナップショットを取ってください。[diag_boot.c](</home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_boot.c:483>) 経路差がドライバ初期化後まで残るかを同じ1回の起動で判定でき、単なる無害な残留イベントを除外できます。
   - 制御した fatal 1回では Windows USB ETW を同時採取してください。これは試行回数を増やさず、3件がホスト再試行か複数接続かを直接判定できます。
   - 完全な自動電源断が確認できた後なら、個別 cleanup より先に「board hook 到達後、復旧タイマを張ってから1回だけ SREQ」の比較像を1対試す価値があります。ただし cookie の状態機械を先に完成させる必要があります。

9. v1 の8点が解消されたか

   1. PnP ログの解釈: 解消。断定はほぼ除去されています。「USB に何かが現れた」だけ表現をさらに限定すべきです。
   2. 候補 A の T1: 一部。RAM 初期化前の危険は避けましたが、Zephyr が正規化済みの CPU/NVIC 値を多数測ろうとしており、記録容量も未解決です。
   3. 候補 A の修正: 一部。SystemInit、HFXO、LFCLK、有界待ちは改善しましたが、割り込みマスクの順序と cookie の仕様が未解決です。
   4. 候補 B の T3: 解消。機構試験1回に限定し、LLL 固有状態を代表しないと正しく扱っています。
   5. 統計: 一部。解釈は改善しましたが、区間上限と179回中0件の確率がまだ誤っています。
   6. 失敗時の復旧: 未解消。穴の明記は進みましたが、穴の受け入れ、未検証の VBUS 断、手動キー確認が残っています。
   7. 所要時間: 一部。実行時間は直りましたが、実装/模擬/T0/T3/T2 の工数が楽観的です。
   8. 先に行う安価な試験: 一部。board hook 観測と初回リセット案は採用しましたが、USB ETW、Zephyr による正規化の机上棄却、同一起動内の前後観測が未反映です。

全体の判定: 条件つきで採用