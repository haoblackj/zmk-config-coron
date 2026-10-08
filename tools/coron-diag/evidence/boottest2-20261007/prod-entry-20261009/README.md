# 本番候補の投入（2026-10-09 01:17〜01:19、右手側 B17318CDBE9A61B1）
リーダーの GO（issue zmk-workspace#1、01:13 の状態コメント）で、`coron_R-prod-entry.uf2`（md5 fedd88a480bdfba476aba4e5cddd2617、`6386a6d` の `diag_entry.c` + `diagrec.overlay`、`../t2-20261009/build-prod-entry.sh`）を、通常の手順（コンソールの `b` でブートローダーへ入れ、UF2 を書き、手動リセットなし）で書き込んだ。立ち会いなし、ボタン操作なし。

- `flash/`: `calib-flash.ps1 -Expect prod` の記録。01:17:56 `b` 送信、01:18:16 UF2 複写、01:18:18 app として復帰、01:18:21 dump 完了、RESULT PASS。
- `pre-dump.txt` / `pre-probe.txt`: 書き込み前（2725423）のコンソール dump と Studio RPC の応答。`post-dump.txt` / `post-probe.txt`: 書き込み後（本番候補）の同じもの。
- `studio-probe.sh`: Studio RPC の確認に使った道具。`zmk.studio.Request{request_id=1, core={get_device_info=true}}`（`08 01 1a 02 08 01`）を SOF 0xAB / EOF 0xAD で包んで MI_03 の UART に送り、応答を 16 進で出す。これ以外は何も書かない。

## 書き込み後の自動確認（01:19、起動から約 50 秒）
| 項目 | 結果 |
|---|---|
| USB の列挙（`Get-PnpDevice`、デバイスツリーのみ） | 書き込み前と同じ 7 項目: USB Composite、MI_00 Ports（コンソール、COM5）、MI_02 HIDClass + Keyboard + HIDClass（コンシューマー）+ Mouse、MI_03 Ports（Studio RPC UART、COM7）。すべて Status OK |
| BLE の PC 接続 | dump の `host_conn=1 host_disc=0`（PC とつながっている）、`split_conn=1 split_disc=0`（左手側とつながっている）。Windows 側の `BTHLE\DEV_F5656046411C`（coron）は OK |
| Studio RPC | `get_device_info` に 27 バイトで応答。`name="coron"`、`serial_number=B1 73 18 CD BE 9A 61 B1`。書き込み前の応答と同一 |
| dump の印 | `ZDIAG crumb pv=0 pseq=0 pst=0 prst=0x0 pint=0x0 piser1=0x0 seq=1 st=10`。前回の印なし（2725423 は印を書かない）、今回は seq 1 で稼働（st=10、CS_RUNNING）に到達 |

## 言えること、言えないこと
- 言えること: 本番候補は通常の手順で書き込め、手動リセットなしで起動し、USB、BLE、Studio、印の 4 項目が通った。
- 言えないこと: 現場の停止がこれで無くなること（1 回の起動で率は示せない）。印は、次に右手側が止まって復帰したとき、その起動がどの段まで進んだか（`pst`）を教える。

## 戻し方
`%TEMP%\coron-flash\coron_R-prod-2725423.uf2`（md5 889f3a4816c82bdd4adc253b16f28689）を `calib-flash.ps1 -Expect prod` で書き戻す（T2 の本番復帰と同じ手順）。
