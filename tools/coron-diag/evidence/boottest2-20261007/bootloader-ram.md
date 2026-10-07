# ブートローダーの RAM 使用範囲と記録領域（2026-10-08 01:11。`bootloader-ram.txt` を置き換える）

## 何を確かめたか
記録領域（`arm_next`〜`cur`、0x20027400〜0x20027adc）がブートローダーの静的な RAM 使用範囲（data、bss、初期スタック）の外にあること。
「リンカスクリプトの中間にある」ではなく、配布バイナリのリセット処理が実際に書く範囲で確認した。
動的な範囲（スタックの深さ、ヒープ）は静的には分からないので、校正の第 7 段（`S` → `b` → 最適化像）で記録の全項目を照合する。

## 実機のブートローダーの素性
- 実機の `INFO_UF2.TXT`（2026-10-04 18:34 JST に右手側のマスストレージから読んだ。トランスクリプト 12b49db2）:
  `UF2 Bootloader 0.6.1 lib/nrfx (v2.0.0) lib/tinyusb (0.10.1-293-gaf8e5a90) lib/uf2 (remotes/origin/configupdate-9-gadbb8c7)`、`Model: Seeed XIAO nRF52840`、`Board-ID: Seeed_XIAO_nRF52840_Sense`、`SoftDevice: S140 7.3.0`、`Date: Nov 12 2021`。
- Windows の PnP ログのブートローダーの VID/PID は `2886:0045`。
- Adafruit 公式のリリース 0.6.1 には XIAO 向けの配布物が無く、XIAO のボード定義が公式に入るのは 2023 年（0.8.0 以降）。Seeed の配布物は `Seeed-Studio/Adafruit_nRF52_Arduino` の `bootloader/Seeed_XIAO_nRF52840_Sense/`（ファイル名は 0.6.2、中の文字列は 0.6.1）。
- その hex の文字列と VID/PID（デバイス記述子の `86 28 45 00`）は実機の `INFO_UF2.TXT` と PnP の値に一致する。バイト単位で実機と同一かは未確認（実機の ROM は読んでいない）。
- 取得物（scratchpad、sha256）:
  - `Seeed_XIAO_nRF52840_Sense_bootloader-0.6.2_s140_7.3.0.hex` ac654c6cab225a933278c8be09b92b41bc4c044d064bd8c9c3314c1c4a0cc8c8
  - `Seeed_XIAO_nRF52840_bootloader-0.6.2_s140_7.3.0.hex`（非 Sense、PID 0x0044、比較用）c79c8cf75ebb7abfa53b02fd3584aa9a5aeb8dc1b073f674f4fa162225630c6c
  - 出典: https://github.com/Seeed-Studio/Adafruit_nRF52_Arduino/tree/master/bootloader/Seeed_XIAO_nRF52840_Sense

## hex から読んだ値（Sense 版。非 Sense 版も同じ値）
hex の区画: 0x0〜0xb00 と 0x1000〜0x26498（MBR と SoftDevice S140）、0xf4000〜0xfc3d8（ブートローダー）、0xfd800〜0xfd858（設定）、0x10001014〜（UICR）。

ベクタ表（0xf4000）: 初期 SP = 0x20040000、リセット = 0xfae19。

リセット処理（`objdump -D -b binary -m arm -M force-thumb --adjust-vma=0xf4000`）:
```
   fae18:	ldr	r1, [pc, #24]	; 0x000fbdb8  (.data のロード元、flash)
   fae1a:	ldr	r2, [pc, #28]	; 0x20008000  (__data_start__)
   fae1c:	ldr	r3, [pc, #28]	; 0x20008620  (__data_end__)
   fae1e:	subs	r3, r3, r2
   fae20:	ble.n	0xfae2a
   fae22:	subs	r3, #4
   fae24:	ldr	r0, [r1, r3]
   fae26:	str	r0, [r2, r3]      ; .data を flash から RAM へ複写
   fae28:	bgt.n	0xfae22
   fae2a:	bl	0xf4f10            ; SystemInit
   fae2e:	bl	0xf4240            ; _start (newlib crt0)
```
newlib の `_start`（0xf4240）:
```
   f4240:	ldr	r3, [pc, #84]	; 0x20040000  (__StackTop)
   f4248:	mov	sp, r3
   f424a:	sub.w	sl, r3, #65536	; 0x10000 (スタック下限の目安。強制は無い)
   f4254:	ldr	r0, [pc, #76]	; 0x20008620  (__bss_start__)
   f4256:	ldr	r2, [pc, #80]	; 0x2000ce28  (__bss_end__)
   f4258:	subs	r2, r2, r0
   f425a:	bl	0xf431c            ; memset(bss, 0, len)
```

## 配置
| 領域 | 範囲 | 出どころ |
|---|---|---|
| SoftDevice / MBR の RAM | 0x20000000〜0x20008000 未満 | リンカスクリプトの RAM ORIGIN（SD の予約） |
| 二重リセットの印 | 0x20007f7c〜0x20007f80 | リンカスクリプト DBL_RESET |
| ブートローダー NOINIT | 0x20007f80〜0x20008000 | リンカスクリプト NOINIT |
| ブートローダー .data | 0x20008000〜0x20008620 | リセット処理の複写範囲 |
| ブートローダー .bss | 0x20008620〜0x2000ce28 | `_start` の memset 範囲 |
| ブートローダーのヒープ（使えば） | 0x2000ce28 から上 | newlib の `end` の慣例。使用の有無は未確認 |
| **記録領域** | **0x20027400〜0x20027adc** | `arm_next` 8、`ring` 0x494、`last` 0x120、`cur` 0x120（両像で同じ。`disasm-net.txt`、`build-boottest2.sh`） |
| ブートローダーのスタック | 0x20040000 から下へ | ベクタ表の初期 SP |

静的に書かれる範囲（.data と .bss の上端 0x2000ce28）から記録領域の下端までの隙間は 0x1a5d8（約 108 KB）。
スタックの上端から記録領域の上端までの隙間は 0x18524（約 100 KB）。
ブートローダーの実行中にヒープが 108 KB 伸びるか、スタックが 100 KB 深くなるかは静的には否定できない（根拠はこの数字の大きさだけで、推測）。

## 校正で照合すること（第 7 段）
`S` で次の起動の停止を仕込み、`b` でブートローダーへ落とし、最適化像（`bt3A-R-10072355`）を書く。最適化像の `d` で、`inc` の 1 件が次の全項目で一致したとき「ブートローダーと像の切り替えを通して記録が保たれた」とする。
| 項目 | 期待値 |
|---|---|
| magic / CRC | 一致（不一致なら `ring.invalid` に数えられ、`inc` に出ない） |
| tag | `bt3A-R-10072355`（`S` の仕込みは `b` の次のアプリ起動、つまり書き込み後の最適化像の初回起動で消費されるので、止まるのは最適化像） |
| seq | `S` を打つ直前の `d` で見た `cur.seq` + 1（`b` の起動の次） |
| ring の既存の件 | 第 2、5、6 段で基準像が保存した 3 件（tag=`bt3-R-10072355`）がそのまま残っている。これがブートローダーの書き込みを挟んだ保持の直接の確認 |
| reason | 1（BOOT_TIMEOUT） |
| calib | `S` |
| boot_done | 0 |
| stage | 6（APP_EARLY） |
| entry の RESETREAS | 書き込み後のジャンプ経路の値（ソフトリセット、`b` の経路と同じ） |
| fire の pc | 最適化像の `diag_spin_forever`（0x389b4〜） |
`ring.count` が 1 増え、`dropped`/`invalid` が増えないことも見る。magic と CRC だけでは「領域が読めた」までしか言えないので、tag と seq と reason まで一致させる。
