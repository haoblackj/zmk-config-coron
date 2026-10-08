結論: 条件つきで採用です。起動時の整え処理そのものは、現在の構成と実機試験の範囲では安全です。ただし、本番投入前に少なくとも「crumb の途中書き込み対策」「dump 行長の短縮」「USBD の残留イベント消去」を直し、DFU 起動を再確認するべきです。

1. `board_early_init_hook` の操作

判定: 現在のビルド構成では問題なし。

根拠:

- フックは `SystemInit`、RAM 初期化、割り込み優先度初期化の後、PRE_KERNEL 初期化より前に呼ばれています。[diag_entry.c](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_entry.c:76) [init.c](/home/yagu001/zmk-dya-build/zephyr/kernel/init.c:747)
- 対象ビルドには、このフックより前に IRQ を有効化する EARLY init や SoC early hook がありません。
- SoftDevice/MPSL を使う構成ではないため、MBR/SoftDevice の IRQ 転送を維持する目的で NVIC の enable/pending を引き継ぐ必要もありません。
- NVIC の ICER/ICPR は外部 IRQ のみを対象とし、その後の Zephyr/nrfx ドライバが必要な IRQ を改めて有効化します。
- SysTick はこの構成のシステムクロック源ではなく、`CTRL=0` は安全です。
- 4回の DFU 起動試験でも、クロックドライバ初期化後には Zephyr が有効化した IRQ だけになっています。

直し方: 現状維持でよいです。ただし、将来 EARLY init、SoC early hook、SoftDevice/MPSL を有効にした場合は再レビュー対象であることをコメントに残すのは有用です。

重要度: 任意。

2. crumb の設計

判定: 途中書き込み時に前回の stage を新しい起動の値として誤認できるため、このままでは問題あり。

根拠:

[diag_entry.c](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_entry.c:76) では、前回値の退避後に `magic`、`fmt`、`seq`、`resetreas` などを書き換え、最後に `crumb_set(CS_HOOK)` で `stage` と `stage_inv` を更新しています。

このため、メタデータ更新中にリセットされると、次の組み合わせが残り得ます。

- `seq` などは新しい起動の値
- `stage` と `stage_inv` は前回の有効な対

次回起動では有効な crumb と判定され、今回の起動が実際には `CS_HOOK` に達する前に落ちたのに、前回の `CS_RUNNING` などへ到達したように表示される可能性があります。これは起動進行記録の用途に直接反します。

直し方:

前回値をコピーして検証した直後、現在のレコードを明示的に無効化してください。例えば `stage_inv = stage` としてバリアを入れ、その後に整え処理とメタデータ更新を行い、最後に `crumb_set(CS_HOOK)` で初めて有効化します。検証時には stage が `CS_HOOK` から `CS_RUNNING` の範囲内かも確認すると堅牢です。

この順序なら CRC は必須ではありません。32ビットの整列済み store と、最後に書く `stage`/`~stage` の対をコミット点として利用できます。

重要度: 止めるべき。

そのほかの設計点は問題ありません。

- 固定番地と NOLOAD により、同じレイアウトを使う新しい像へ書き換えた最初の起動でも、前の像が残した値を読めます。
- crumb を持たない本番像から初回起動した場合は magic 不一致になり、前回値なしとして扱われるので正常です。
- 試験像の `diag_area` は先頭 magic が `STAL` またはゼロで、crumb の `CRM1` と異なるため、通常の誤読は起きません。
- 実際のリンク結果でも `diag_crumb` は `0x2002c000` の NOBITS 領域に配置されています。[zmk.map](/home/yagu001/zmk-dya-build/.build/R-entry/zephyr/zmk.map:26207)

ただし、`CORON_DIAG_ENTRY` を overlay なしで有効にしてもビルドを止める仕組みがありません。[Kconfig](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/Kconfig:15)

直し方: devicetree のノード、開始番地、領域サイズを build assertion で確認するか、少なくとも CI で map を検査してください。また、Kconfig の「one-word breadcrumb」と [diagrec.overlay](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/diagrec.overlay:1) の「Test builds only」は実装と本番用途に合わせて修正するべきです。

重要度: 直すべき。

3. `SYS_INIT` からの `k_work_submit`

判定: 呼び出しは問題なし。ただし `CS_RUNNING` の意味は限定的です。

根拠:

- システムワークキューは POST_KERNEL で開始済みです。[system_work_q.c](/home/yagu001/zmk-dya-build/zephyr/kernel/system_work_q.c:22)
- `APPLICATION 99` から静的に定義した work を submit することは API と初期化順の両面で問題ありません。
- システムワークキューの優先度が `-1`、main が `0` なので、submit 直後にプリエンプトされて work が動く可能性があります。

したがって `CS_RUNNING` が証明するのは「APPLICATION 99 に到達し、システムワークキューがこの work を少なくとも一度処理した」ことです。main の実行、settings 完了、BLE 接続、USB enumeration、Studio 利用可能までは証明しません。

直し方: 現在想定している意味をコメントと dump の説明に明記してください。より後段の生存確認が必要なら別 stage が必要ですが、今回の制約内では追加不要です。

重要度: 任意。

4. `diag_min.c` の dump 行

判定: 150文字以内にならないため問題あり。

根拠:

現在の書式は、`seq` が10進数最大値になった場合、正常な stage の範囲に限定しても約156文字になります。[diag_entry.c](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_entry.c:135)

一方、`diag_min.c` の `#TRUNC` は約256バイトの出力バッファを超える場合に付く仕組みです。[diag_min.c](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/src/diag_min.c:107) したがって、151～253文字程度の行は150文字制限に違反しても `#TRUNC` が付きません。

直し方: キー名を短くし、`seq` も16進固定幅にするなどして、最悪値でも150文字以内にしてください。最長値を使った行長テストも追加するべきです。

重要度: 直すべき。

5. 本番の振る舞いへの副作用

判定: 直接的な機能副作用は小さいものの、RAM余裕の監視は必要。

根拠:

- 起動時処理はレジスタとRAMへの少数の store のみで、待ち、クロック操作、タイマー追加はありません。
- work handler も1回の短いRAM書き込みだけです。
- dump 時には既存の1行出力処理に伴う約5 msが増えますが、通常動作中の待ち時間は増えません。
- BLEやStudioへ直接触れる処理はありません。
- USBについては、禁止条件A/Bを除去する方向なので基本的には改善側です。ただし6項の USBD 残留処理が必要です。
- リンク対象RAMは176 KBになり、4 KBの記録領域より上のRAMもアプリから利用できなくなります。現在のリンク結果では RAM 終端まで約3404バイトです。静的スタックなどは既に計上されていますが、今後の機能追加余地は小さめです。

直し方: 現在の像はリンクできているため投入を止める問題ではありません。CIでRAM使用量または map 上の余裕を監視し、一定値以下で失敗させるのが安全です。

重要度: 任意。

6. 消していない残留

判定: `USBD.EVENTCAUSE=0x300` は消すべきです。RTC1とSysTick LOADは放置して問題ありません。

USBDについて:

- DFU直後だけ `SUSPEND`/`RESUME` 相当の `EVENTCAUSE=0x300` が残っています。[T1 README](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/evidence/boottest2-20261007/t1-20261009/README.md:8)
- Zephyr の USBD 初期化は READY を処理しますが、残った SUSPEND/RESUME は後の USBD 割り込みで読み出され、偽の通知として処理され得ます。[nrf_usbd_common.c](/home/yagu001/zmk-dya-build/zephyr/drivers/usb/common/nrf_usbd_common/nrf_usbd_common.c:729)
- 推測: これが現在の起動不能の直接原因とは限りません。ただし、ブートローダー由来の状態を正規化する目的には残す理由がありません。

直し方: USBD が無効で割り込みもマスクされている現在のフック内で、測定済みの SUSPEND/RESUME ビットを `EVENTCAUSE` の W1Cで消し、対応する `EVENTS_USBEVENT` もゼロにしてください。待ちやクロック操作は不要です。処理追加後は4回のDFU起動試験を再実施してください。

重要度: 直すべき。

RTC1について:

- ドライバ初期化時に割り込み・イベントを無効化し、CLEAR/STARTを行った後で CC を設定し直します。
- 実機でも CLEAR が反映されています。
- 残った CC[0] と保留中だった CLEAR をフックから追加操作する必要はありません。

直し方: 変更不要。

重要度: 任意。問題なし。

SysTick LOADについて:

- `CTRL=0` なら LOAD の残留は動作しません。
- この構成では SysTick をシステムタイマーとして使用していません。

直し方: 変更不要。LOAD をゼロにする実益はありません。

重要度: 任意。問題なし。

7. ロールバック

判定: 問題なし。

根拠:

既存の [calib-flash.ps1](/home/yagu001/zmk-dya-build/config/zmk-config-coron/tools/coron-diag/calib/calib-flash.ps1:1) は、本番像2725423のUF2についてハッシュ確認、書き込み、ドライブ消失、アプリ復帰、バージョン出力を確認します。新しい `ZDIAG crumb` 行は既存の検証条件を妨げません。

旧像へ戻した後に RAM 上へ crumb が残っても、旧像はその領域を参照しないため動作上の問題はありません。

直し方: 現行手順をそのまま使えます。ロールバック用UF2とスクリプトを投入前に同じPCで一度確認しておく程度で十分です。

重要度: 任意。問題なし。

全体の判定: 条件つきで採用