# T0: T1 の写しの枠と、本番用の「起動の進みの印」の仕様（案、2026-10-08）

## 1. T1 の写しの枠（試験像だけ。`diag_boot.c` に足す）

### 置き場所と容量
- 記録領域 `DIAGREC`（0x2002c000、4 KB）の既存の使用は `arm_next` 8 + `ring` 0x6ec + `last` 0x124 + `cur` 0x124 = 0x93c バイトで、残りは 0x6c4（1732）バイト。
- 写しは `struct boot_rec` に埋め込まず（ring の 6 枠にコピーされて約 2 KB 増えるのを避ける）、`diag_area` の末尾に `snap_last` と `snap_cur` の 2 枠を足す。各枠 = ヘッダ 4 語（magic `'SNP1'`、形式番号、seq、取得済みの点のビット）+ 3 点 × 40 語 + CRC 1 語 = 125 語 = 500 バイト。2 枠で 1000 バイト。残り 732 バイト。
- ビルドで `diag_area` の大きさを検査: `BUILD_ASSERT(sizeof(struct diag_area) <= 0x1000)` と、ビルドスクリプトが最終 ELF の `diag_area` のアドレスと大きさを `nm --size-sort` で出して 0x2002d000 を超えていたら失敗にする（既存の `build-boottest2.sh` に 1 行）。

### 取る点（3 点。既存の段階の刻印と同じ場所）
1. `hook`: `board_early_init_hook` の先頭。順序は DWT の有効化 → `net_arm()`（網を先に張る。レビューの指摘）→ 写し → 既存の記録処理。`net_arm()` が `cur` に依存していないことを実装時に確かめる。
2. `after_clk`: `STG_PK1_AFTER_CLK`（PRE_KERNEL_1 の優先度 31、クロックドライバの後）。
3. `after_usb`: `STG_APP_AFTER_USB`（APPLICATION 97、USB 有効化の後）。
各点の写しは「開始時刻（DWT）→ レジスタを順に読む → 終了時刻」。逐次読み出しなので原子的ではなく、2 つの時刻で幅を残す（レビューの指摘）。

### 各点で写す 40 語（Zephyr と `SystemInit` がフックまでに正規化するものは入れない。机上調査 A の表で確定する）
| 群 | レジスタ | 語数 |
|---|---|---|
| 時刻 | DWT CYCCNT（開始、終了） | 2 |
| CLOCK | LFCLKSTAT、LFCLKRUN、LFCLKSRC、HFCLKSTAT、HFCLKRUN、INTENSET、EVENTS_LFCLKSTARTED、EVENTS_HFCLKSTARTED、EVENTS_DONE、EVENTS_CTTO | 10 |
| POWER | INTENSET、EVENTS_USBDETECTED、EVENTS_USBREMOVED、EVENTS_USBPWRRDY、USBREGSTATUS、RESETREAS | 6 |
| RTC1 | COUNTER（2 回読んで動いているかを見る）、INTENSET、EVTEN、PRESCALER、CC[0]、EVENTS_COMPARE[0]、EVENTS_TICK、EVENTS_OVRFLW | 9 |
| USBD | ENABLE、USBPULLUP、INTEN、EPINEN、EPOUTEN、EVENTCAUSE | 6 |
| SysTick と SCB | SYST_CSR、SYST_RVR、SYST_CVR、SCB ICSR（保留の SysTick と PendSV）、SCB SHCSR | 5 |
| PPI と GPIOTE | PPI CHEN、GPIOTE INTENSET | 2 |
| コア（机上調査 A で「フックまで一度も書かれない」と確定したもの） | PRIMASK、FAULTMASK、CONTROL、AIRCR、NVIC ISER[0]、ISER[1]、ISPR[0]、ISPR[1]、DEMCR | 9 |
合計 49 語（1 点 196 バイト、3 点 + ヘッダと CRC で 608 バイト、2 枠で 1216 バイト。残り 516 バイト）。
机上調査 A（`t0-boot-normalization.md`。ソースと同じ設定の ELF の逆アセンブルで照合）の結論: この設定は `CONFIG_INIT_ARCH_HW_AT_BOOT` が無効なので、NVIC の ISER と ISPR、PRIMASK、FAULTMASK、AIRCR、ICSR の保留、SysTick、DWT と DEMCR、CLOCK と POWER の大半、RTC、TIMER、USBD、PPI、GPIOTE は、フックまで一度も書かれずブートローダーの値のまま（Codex のレビューにあった「Zephyr が NVIC の有効と保留を正規化する」は、この設定では当たらない）。正規化されるのは BASEPRI（0x20）、MSP/PSP、VTOR、NVIC の IPR（全部 0x20）、FPU、MPU、SCR、SHPR、CFSR/HFSR。EARLY 段の SYS_INIT は 0 件。
注意（同報告）: `SystemInit` の errata 136 の処理は RESETPIN が立っているとき他の原因ビットを消すので、ピンリセットの回の RESETREAS は bit0 以外が読めない。SysTick の優先度は二重シフトで 0（最高）になり BASEPRI で隠れないので、ブートローダーが SysTick を TICKINT つきで動かしたまま渡すと最優先で割り込みが入る（ブートローダーは CTRL=0 にしているが、SYST_CSR で確かめる）。ブートローダーが NVIC を有効のまま PRIMASK=0 で渡すと `SystemInit` の実行中（BASEPRI と VTOR の設定前）に IRQ がブートローダーのベクタ表へ入りうる（ブートローダーは ICER/ICPR を全消去しているが、ISER/ISPR で確かめる）。
フックでの順序: コアの 9 語を最初に読む（DWT と DEMCR はフック自身が書き換える前）→ DWT 有効化 → `net_arm()` → 周辺の 40 語（開始と終了の時刻つき）→ 既存の記録処理。

### dump の行と、ホスト側
- `ZBOOT snap <cur|last> <hook|clk|usb> c1 t=%u..%u lfstat=.. lfrun=.. lfsrc=.. hfstat=.. hfrun=.. inten=.. lfev=.. hfev=.. done=.. ctto=..`（CLOCK）
- `ZBOOT snap <..> <..> p1 inten=.. det=.. rem=.. rdy=.. reg=.. reset=..`（POWER）
- `ZBOOT snap <..> <..> r1 cnt=../.. inten=.. evten=.. pres=.. cc0=.. cmp0=.. tick=.. ovr=..`（RTC1）
- `ZBOOT snap <..> <..> u1 en=.. pullup=.. inten=.. epin=.. epout=.. ec=..`（USBD）
- `ZBOOT snap <..> <..> s1 csr=.. rvr=.. cvr=.. icsr=.. shcsr=.. chen=.. gpiote=..`（SysTick、SCB、PPI、GPIOTE）
1 点 5 行、3 点で 15 行、cur と last で 30 行。各行は 150 文字以内（既存の制約）。
- ホスト（`calib-lib.ps1` の `Validate-Dump`）は `snap` 行を「あれば検証、無くても FAIL にしない」で読み、試行の結果ファイルに生の値を入れる。模擬の缶詰（`gen-scenarios.py` の `dump()`）にも行を足し、83 場面で回帰を確かめる。
- 集計は別の小さなスクリプト（経路 × 点 × レジスタの表、経路内の分散、禁止条件への照合）。

### 判定
- 机上調査 B の「禁止条件」の表（ドライバが前提にする状態と、違ったときに止まる機構の根拠行）に当たる値だけを問題にする。非ゼロを汚れとは見なさない。
- DFU 直後と `r` を各 3 回取り、経路内で値が一致すれば各 10 回で止め、ばらつきがあれば各 20 回まで。

## 2. 本番用の「起動の進みの印」（候補 C。リーダー承認済み）

### 目的
本番像で次に停止したとき、リセット後に USB のコンソールから「前の起動がどの段まで進んだか」を読めるようにする。タイマーも割り込みも使わず、RAM への書き込みだけ。

### 置き場所
- 試験像と同じ固定アドレス 0x2002c000 の領域を本番にも持たせる（`diagrec.overlay` を右手側の本番ビルドに入れる。RAM は 176 KB に縮む。本番像の `.bss` は 114 KB で収まる）。固定にする理由: 像を書き換えた直後の最初の起動がいちばん知りたい起動で、新しい像が前の像の印を同じ場所で読める必要がある。
- 領域の先頭 32 バイトを印に使う（試験像の `diag_area` とは別の構造。試験像を書いたあと本番像を書いた場合も、magic が違うので「前の印なし」と読めるだけ）。

### 構造（8 語）
| 語 | 内容 |
|---|---|
| 0 | magic `'CRM1'` |
| 1 | 形式番号 1 |
| 2 | seq（起動ごとに +1） |
| 3 | stage（下の段） |
| 4 | ~stage（反転。書き途中や壊れを検出） |
| 5 | RESETREAS（この起動の入口で読んだ値） |
| 6 | ビルド ID の先頭 4 バイト（像の判別） |
| 7 | 予備 0 |
CRC は使わない（印の更新は 2 語の書き込みだけで済ませ、途中で止まっても反転語で判る）。

### 段（既存の計測器の段と同じ場所に `SYS_INIT` と刻印を置く）
hook（`board_early_init_hook`、`CONFIG_BOARD_EARLY_INIT_HOOK` を印の Kconfig が select）、pk1_early（PRE_KERNEL_1, 1）、pk1_after_clk（PRE_KERNEL_1, 31）、pk1_last（99）、pk2_after_sysclk（PRE_KERNEL_2, 2）、post（POST_KERNEL, 0）、app_early（APPLICATION, 1）、app_after_usb（97）、app_last（99）、settings_commit（静的な settings handler の commit）、running（app_last で `k_work_submit` した 1 回だけのワークがシステムワークキューで走った時点。周期の給餌は無し）。

### 読み出し
- `diag_min.c` の dump に 1 行足す: `ZDIAG crumb prev_valid=%u prev_seq=%u prev_stage=%u prev_reset=0x%x cur_seq=%u cur_stage=%u`。起動時にフックで前の印を静的変数へ写してから、自分の印を書き始める。
- 既存のホスト側（校正と復帰のスクリプト）は `ZDIAG crumb` 行を無視するので、変更は不要。読むときは `calib-io.ps1 -Com COM5 -ReadSeconds 0` でよい。

### 本番に入れることの影響
- 追加されるのは、起動時の数十命令、11 か所の 1 語書き込み、1 回だけのワーク、dump の 1 行。タイマーも割り込みも設定保存も使わない。
- 失敗の形: 印が無い（magic 不一致）→ 「前の印なし」と出るだけで起動には影響しない。

### 未決
- 右手側だけに入れるか、左手側にも入れるか（左手側でも 1 回押しが要った証言がある。左手側の読み出しは USB につないだときだけ）。
- 印の Kconfig 名（`CONFIG_CORON_DIAG_CRUMB`）と、試験像で印と計測器を両方入れるか（領域の先頭 32 バイトを `diag_area` から外す必要がある）。
