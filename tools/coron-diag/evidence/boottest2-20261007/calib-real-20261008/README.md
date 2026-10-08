# 実機校正の記録（2026-10-08、右手側 B17318CDBE9A61B1、スクリプト ac713a1 とその後の修正）
レビュー #12（ac713a1 を「手動操作を含まない実機校正に進めてよい」と判断）とリーダーの合図を受けて開始。どの実行も手動操作なし。
| 実行 | ログ | 結果 | 止まった理由 | 実機への書き込み |
|---|---|---|---|---|
| 1 回目 `calib-all.ps1`（10:41:58、ac713a1 そのまま） | `calib-1008-104158/` | pre PASS、flash-base FAIL、以後 not-run、restore FAIL（終了コード 3） | `b` は受理されブートローダーに入ったが、`exactly one UF2 drive tied to this serial` が `drives of serial=[] all uf2 drives=[E]` で FAIL。実機の USBSTOR のインスタンス ID は `USBSTOR\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\A&258725EA&0&B17318CDBE9A61B1&0` で、シリアルの前に Windows が付ける `A&258725EA&0&` が入る。スクリプトの照合 `\<シリアル>&N` はこの形を認めず、模擬はこの前提を写していた（ドライブ文字とシリアルの組だけを差し替えていたので捕まえられない）。復帰も同じ照合で止まった | なし（右手側はブートローダーのまま） |
| 復帰単体 `calib-flash.ps1 -Expect prod`（10:48:00、照合を `(\|&)<シリアル>&N` に修正。実機で読むだけの確認: `drives of serial=[E]`、ブートローダー 1 台） | `calib-1008-104800-restore/` | PASS（本番像 2725423、`version=prof1`、`ZBOOT` 0 本、app 復帰） | — | 本番像 1 回 |
| 2 回目 `calib-all.ps1`（10:48:28、同じ修正） | `calib-1008-104828/` | pre PASS、flash-base FAIL（複写と app 復帰まで PASS、その後の dump が取れない）、以後 not-run、restore FAIL（dump が取れず `b` を送らない。終了コード 3） | 基準像 bt4 は `CONFIG_UART_LINE_CTRL` 無効（Studio の UART スニペット無しのビルド。CDC 1 本）で、`diag_min.c` の `uart_line_ctrl_get` が失敗し DTR では dump せず `d` のときだけ dump する。本番像は line control ありで開くだけで dump する。子 `calib-io.ps1` は `d` を送っていなかった。読み取り専用の探り（COM5 を開いて 5.5 秒待っても 0 文字、`d` で完全な dump: `cur seq=1 tag=bt4-R-10080217 done=1`、`addr cur=0x2002c818`、`ring count=0 reinit=1`）で確定 | 基準像 1 回（右手側は bt4 が app で動作。本番には未復帰） |
| 3 回目 `calib-all.ps1`（10:58:50、子が開いて 1.5 秒で dump が無ければ `d` を 1 回送る修正を追加。模擬 40 場面は `calib-sim12-20261008/` で全部期待どおり） | `calib-1008-105850/` | **校正 PASS（第 3 段 SKIP）、本番復帰 PASS**。終了コード 0、所要 5 分 20 秒 | — | 基準像、最適化像、本番像の 3 回 |

## 3 回目の実測（期待値は README「校正」の表。すべて一致）
| 段 | 実測 |
|---|---|
| pre | bt4 が app（前回の残り）。`cur seq=1 done=1`、`addr cur=0x2002c818`、`ring count=0 reinit=1`、事故記録なし |
| flash-base | `b` 受理 → E:（シリアル一致、1 台）→ 複写 → 消失 → app。`cur seq=2 tag=bt4-R-10080217 done=1`、`addr cur=0x2002c818`、`ring count=0 reinit=0` |
| 0 | `c` 受理、`ring count=0 slots=6`、seq 2→2 |
| 1 | done=1、running=1193209 us、probes 12/12→16/16、feeds 11→15、seq 2→2、ring 不変 |
| 2 (`h`) | `rc=0`、`returned` なし。ポート消失と USB 離脱を直接観測、seq 2→3、ring 0→1。`inc0`: seq=2 reason=2 calib=h done=1 stage=12、`fire1 exc=0xffffffed pc=0x662ea lr=0x662f5`（`diag_spin_forever`）、`fire2 handler=0 thread=0x20009910`（= addr sysq）`at_us=16231285`、`fire3 usbd en=1 ec=0x0 pullup=1 usbreg=0x3`、`fire4 lfstat=0x10001 lfrun=1 hfstat=0x10001 hfrun=1 cc0=468750`。`last` = seq 2 reason=2 |
| 3 | SKIP |
| 4 (`H`) | `rc=0` → `returned`、ポート消失なし、seq 3→3、ring 不変、calib_live=0、feeds +24、`cur calib=H` |
| 5 (`G`) | `rc=0`、`returned` なし。直接観測、seq 3→4、ring 1→2。`inc1`: seq=3 reason=2 calib=G、`fire1 exc=0xfffffffd pc=0x662ea lr=0x662fd`、`fire2 handler=0 thread=0x20005d00`（= addr calib）`at_us=47005207`、`fire3`/`fire4` は inc0 と同じ値 |
| 6 (`S`→`r`) | `S rc=0`/`returned`、`r` 受理。USB 離脱を観測（ポート消失の刻印は無し）、seq 4→6、ring 2→3。`inc2`: seq=5 reason=1 calib=S done=0 stage=6、`fire1 exc=0xffffffed pc=0x662ea lr=0x32f39`、`fire2 handler=0 thread=0x20009848`（= addr main）`at_us=19732894`、`fire3 usbd en=0 ec=0x0 pullup=0 usbreg=0x1`、`fire4 lfstat=0x10001 lfrun=1 hfstat=0x10000 hfrun=0 cc0=625000`、`us2 usb=0 … running=0` |
| 7 (`S`→`b`→最適化像) | `S rc=0`/`returned`、`b` 受理、E: 1 台、複写、消失、app。`cur tag=bt4A-R-10080217`、`addr cur=0x2002c818`（sysq/main/calib は 0x2000b688/0x2000b5c0/0x20005d18）、seq 6→8、ring 3→4、**inc0〜inc2 の全 10 行ずつが 1 文字も変わらず残った**、`inc3`: seq=7 tag=bt4A-R reason=1 calib=S stage=6、`fire1 pc=0x38a08 lr=0x38a1b`（最適化像の `diag_spin_forever`）、`fire2 thread=0x2000b5c0`（= addr main）`at_us=19705715`、`fire3 usbd en=0 ec=0x300`、`fire4 hfrun=0 cc0=625000`、reinit=0、dropped/invalid 0→0 |
| 8 | 4 件を保存して `c`、`ring count=0` |
| 復帰 | `b` 受理、E: 1 台、本番像を複写、消失、app。`ZDIAG begin version=prof1 up_ms=10300 boot=1 reset=0x2`、`ZBOOT` 0 本 |
気づき（判定には影響なし）: 第 4 段の `PASS device still app (state=)` は実測文字列が空（`Get-State` を直接呼んだので `$script:lastState` が未設定）。判定は `Get-State` の戻り値で正しく行われている。表示の修正は次の版で。

